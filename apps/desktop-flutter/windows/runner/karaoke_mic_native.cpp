#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <wrl/client.h>

#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

using Microsoft::WRL::ComPtr;

namespace {
std::mutex g_lock;
std::mutex g_lifecycle;
std::condition_variable g_ready_condition;
std::thread g_worker;
std::atomic<bool> g_stop{false};
std::deque<float> g_pcm;
std::string g_error;
int g_rate = 0;
bool g_ready = false;
bool g_running = false;

struct ComScope {
  HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  ~ComScope() { if (SUCCEEDED(result)) CoUninitialize(); }
};

void set_error(HRESULT hr, const char* stage) {
  char message[160];
  std::snprintf(message, sizeof(message), "%s failed 0x%08lX", stage, static_cast<unsigned long>(hr));
  std::lock_guard<std::mutex> guard(g_lock);
  g_error = message;
}

void capture_loop() {
  // 所有 COM 对象与初始化/释放同属采集线程，不跨 FFI 调用持有已注销 apartment。
  ComScope com;
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  WAVEFORMATEX* format = nullptr;
  HRESULT hr = com.result;
  if (SUCCEEDED(hr)) hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (SUCCEEDED(hr)) hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
  if (SUCCEEDED(hr)) hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf()));
  if (SUCCEEDED(hr)) hr = client->GetMixFormat(&format);
  bool floating = false;
  if (SUCCEEDED(hr)) {
    WORD tag = format->wFormatTag;
    if (tag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22) {
      const auto* extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
      tag = static_cast<WORD>(extended->SubFormat.Data1);
    }
    floating = tag == WAVE_FORMAT_IEEE_FLOAT && format->wBitsPerSample == 32;
    const bool pcm16 = tag == WAVE_FORMAT_PCM && format->wBitsPerSample == 16;
    if ((!floating && !pcm16) || format->nChannels == 0 || format->nSamplesPerSec == 0) hr = AUDCLNT_E_UNSUPPORTED_FORMAT;
  }
  if (SUCCEEDED(hr)) hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 2000000, 0, format, nullptr);
  if (SUCCEEDED(hr)) hr = client->GetService(IID_PPV_ARGS(&capture));
  if (SUCCEEDED(hr)) hr = client->Start();
  {
    std::lock_guard<std::mutex> guard(g_lock);
    g_running = SUCCEEDED(hr);
    g_ready = true;
    g_rate = g_running ? static_cast<int>(format->nSamplesPerSec) : 0;
  }
  if (FAILED(hr)) set_error(hr, "microphone init");
  g_ready_condition.notify_all();
  while (SUCCEEDED(hr) && !g_stop.load()) {
    UINT32 packet = 0;
    hr = capture->GetNextPacketSize(&packet);
    if (FAILED(hr)) break;
    if (packet == 0) {
      Sleep(5);
      continue;
    }
    BYTE* data = nullptr;
    UINT32 frames = 0;
    DWORD flags = 0;
    hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
    if (FAILED(hr)) break;
    const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
    {
      std::lock_guard<std::mutex> guard(g_lock);
      for (UINT32 frame = 0; frame < frames; ++frame) {
        float sum = 0;
        for (WORD channel = 0; !silent && channel < format->nChannels; ++channel) {
          const size_t index = static_cast<size_t>(frame) * format->nChannels + channel;
          sum += floating ? reinterpret_cast<const float*>(data)[index] : reinterpret_cast<const short*>(data)[index] / 32768.0f;
        }
        float value = sum / format->nChannels;
        if (!std::isfinite(value)) value = 0;
        if (value > 1) value = 1;
        if (value < -1) value = -1;
        g_pcm.push_back(value);
      }
      while (g_pcm.size() > static_cast<size_t>(g_rate) * 2) g_pcm.pop_front();
    }
    hr = capture->ReleaseBuffer(frames);
  }
  if (FAILED(hr)) set_error(hr, "microphone capture");
  if (client) client->Stop();
  if (format) CoTaskMemFree(format);
  {
    std::lock_guard<std::mutex> guard(g_lock);
    g_running = false;
  }
  // ComPtr 析构在 ComScope 之前，先释放接口再 CoUninitialize。
}
}  // namespace

extern "C" {
__declspec(dllexport) int kmic_available() {
  ComScope com;
  if (FAILED(com.result)) {
    set_error(com.result, "microphone COM query");
    return 0;
  }
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (SUCCEEDED(hr)) hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
  if (FAILED(hr)) set_error(hr, "microphone endpoint query");
  return SUCCEEDED(hr) && device ? 1 : 0;
}

__declspec(dllexport) const char* kmic_last_error() {
  thread_local std::string snapshot;
  std::lock_guard<std::mutex> guard(g_lock);
  snapshot = g_error;
  return snapshot.c_str();
}

__declspec(dllexport) int kmic_start(int sample_rate) {
  std::lock_guard<std::mutex> lifecycle(g_lifecycle);
  if (sample_rate < 8000) {
    set_error(E_INVALIDARG, "sample rate");
    return 0;
  }
  {
    std::lock_guard<std::mutex> guard(g_lock);
    if (g_running) return 1;
  }
  if (g_worker.joinable()) g_worker.join();
  {
    std::lock_guard<std::mutex> guard(g_lock);
    g_ready = false;
    g_error.clear();
    g_pcm.clear();
  }
  g_stop.store(false);
  g_worker = std::thread(capture_loop);
  std::unique_lock<std::mutex> guard(g_lock);
  g_ready_condition.wait(guard, [] { return g_ready; });
  return g_running ? 1 : 0;
}

__declspec(dllexport) int kmic_read(float* out, int max_frames) {
  if (!out || max_frames <= 0) return 0;
  std::lock_guard<std::mutex> guard(g_lock);
  if (!g_running && g_pcm.empty()) return -1;
  int count = 0;
  while (count < max_frames && !g_pcm.empty()) {
    out[count++] = g_pcm.front();
    g_pcm.pop_front();
  }
  return count;
}

__declspec(dllexport) int kmic_mix_sample_rate() {
  std::lock_guard<std::mutex> guard(g_lock);
  return g_rate;
}

__declspec(dllexport) void kmic_stop() {
  std::lock_guard<std::mutex> lifecycle(g_lifecycle);
  g_stop.store(true);
  if (g_worker.joinable()) g_worker.join();
  std::lock_guard<std::mutex> guard(g_lock);
  g_pcm.clear();
  g_rate = 0;
  g_running = false;
}
}
