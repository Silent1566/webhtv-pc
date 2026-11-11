#include <windows.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wrl.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::FtmBase;
#define API extern "C" __declspec(dllexport)

namespace {
thread_local std::wstring last_error;
void Error(HRESULT hr, const wchar_t* stage) {
  wchar_t text[240];
  swprintf_s(text, L"%s (HRESULT 0x%08X)", stage, static_cast<unsigned>(hr));
  last_error = text;
}
void Init() {
  thread_local const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  (void)initialized;
  static const HRESULT started = MFStartup(MF_VERSION);
  (void)started;
}
struct Audio {
  ComPtr<IMFSourceReader> reader;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  std::vector<float> pending;
  size_t cursor = 0;
  LONGLONG timestamp = 0;
  bool loopback = false;
};
class Activation : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                                      IActivateAudioInterfaceCompletionHandler,
                                      FtmBase> {
 public:
  Activation() : ready(CreateEvent(nullptr, TRUE, FALSE, nullptr)) {}
  ~Activation() { CloseHandle(ready); }
  STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation* operation) override {
    ComPtr<IUnknown> activated;
    HRESULT activation_result = E_FAIL;
    result = operation->GetActivateResult(&activation_result, &activated);
    if (SUCCEEDED(result)) result = activation_result;
    if (SUCCEEDED(result)) result = activated.As(&client);
    SetEvent(ready);
    return S_OK;
  }
  HANDLE ready;
  HRESULT result = E_FAIL;
  ComPtr<IAudioClient> client;
};
}

API const wchar_t* aa_error() { return last_error.c_str(); }
API void* aa_open_media(const wchar_t* url) {
  Init();
  auto audio = new Audio();
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 2);
  if (SUCCEEDED(hr)) hr = attributes->SetUINT32(MF_READWRITE_DISABLE_CONVERTERS, FALSE);
  if (SUCCEEDED(hr)) hr = MFCreateSourceReaderFromURL(url, attributes.Get(), &audio->reader);
  if (SUCCEEDED(hr)) hr = audio->reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
  if (SUCCEEDED(hr)) hr = audio->reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
  ComPtr<IMFMediaType> format;
  if (SUCCEEDED(hr)) hr = MFCreateMediaType(&format);
  if (SUCCEEDED(hr)) hr = format->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (SUCCEEDED(hr)) hr = format->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
  if (SUCCEEDED(hr)) hr = format->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1);
  if (SUCCEEDED(hr)) hr = format->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 16000);
  if (SUCCEEDED(hr)) hr = format->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
  if (SUCCEEDED(hr)) hr = format->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
  if (SUCCEEDED(hr)) hr = format->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 64000);
  if (SUCCEEDED(hr)) hr = audio->reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, format.Get());
  if (FAILED(hr)) { Error(hr, L"Media Foundation decode: unsupported source/codec/access"); delete audio; return nullptr; }
  return audio;
}

API void* aa_open_loopback(DWORD target_pid) {
  Init();
  if (!target_pid || target_pid == GetCurrentProcessId()) {
    Error(E_INVALIDARG, L"Loopback requires a dedicated player PID; current process could mix TTS");
    return nullptr;
  }
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, target_pid);
  if (!process) { Error(HRESULT_FROM_WIN32(GetLastError()), L"Target process unavailable/denied"); return nullptr; }
  CloseHandle(process);
  AUDIOCLIENT_ACTIVATION_PARAMS params{};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.TargetProcessId = target_pid;
  params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT prop{};
  prop.vt = VT_BLOB;
  prop.blob.cbSize = sizeof(params);
  prop.blob.pBlobData = reinterpret_cast<BYTE*>(&params);
  auto handler = Microsoft::WRL::Make<Activation>();
  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
      __uuidof(IAudioClient), &prop, handler.Get(), &operation);
  if (SUCCEEDED(hr)) {
    DWORD wait = WaitForSingleObject(handler->ready, 5000);
    hr = wait == WAIT_OBJECT_0 ? handler->result : HRESULT_FROM_WIN32(ERROR_TIMEOUT);
  }
  auto audio = new Audio();
  if (SUCCEEDED(hr)) audio->client = handler->client;
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
  format.nChannels = 1;
  format.nSamplesPerSec = 16000;
  format.wBitsPerSample = 32;
  format.nBlockAlign = 4;
  format.nAvgBytesPerSec = 64000;
  if (SUCCEEDED(hr)) hr = audio->client->Initialize(AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
      2000000, 0, &format, nullptr);
  if (SUCCEEDED(hr)) hr = audio->client->GetService(IID_PPV_ARGS(&audio->capture));
  if (SUCCEEDED(hr)) hr = audio->client->Start();
  if (FAILED(hr)) {
    Error(hr, L"Process WASAPI unavailable (requires Windows build 20348+, device and access)");
    delete audio;
    return nullptr;
  }
  audio->loopback = true;
  return audio;
}

API int aa_seek(void* handle, int64_t microseconds) {
  Init();
  auto audio = static_cast<Audio*>(handle);
  if (!audio || audio->loopback) return -1;
  PROPVARIANT position;
  InitPropVariantFromInt64(microseconds * 10, &position);
  HRESULT hr = audio->reader->SetCurrentPosition(GUID_NULL, position);
  PropVariantClear(&position);
  audio->pending.clear();
  audio->cursor = 0;
  if (FAILED(hr)) { Error(hr, L"Media source cannot seek"); return -1; }
  return 0;
}

API int aa_read(void* handle, float* output, int capacity, int64_t* pts_us) {
  Init();
  auto audio = static_cast<Audio*>(handle);
  if (!audio || capacity <= 0) return -1;
  // Fill the whole requested capacity across decoded samples: SourceReader/WASAPI
  // hand back short buffers, so returning one buffer per call makes the capture
  // worker fall behind the media clock at 1x and 2x. Progress is still reported by
  // the真实 source PTS of the first sample consumed.
  int filled = 0;
  int64_t start_us = -1;
  const auto finish_partial = [&](int status) {
    if (filled <= 0) return status;
    *pts_us = start_us < 0 ? 0 : start_us;
    return filled;
  };
  while (filled < capacity) {
    if (audio->cursor >= audio->pending.size()) {
      audio->pending.clear(); audio->cursor = 0;
      if (audio->loopback) {
        UINT32 packet = 0;
        HRESULT hr = audio->capture->GetNextPacketSize(&packet);
        if (FAILED(hr)) { Error(hr, L"WASAPI packet"); return finish_partial(-1); }
        if (!packet) break;
        BYTE* bytes = nullptr; UINT32 frames = 0; DWORD flags = 0;
        UINT64 device_position = 0, qpc_position = 0;
        hr = audio->capture->GetBuffer(&bytes, &frames, &flags, &device_position, &qpc_position);
        if (FAILED(hr)) { Error(hr, L"WASAPI buffer"); return finish_partial(-1); }
        audio->pending.resize(frames, 0);
        if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) std::memcpy(audio->pending.data(), bytes, frames * sizeof(float));
        audio->timestamp = static_cast<LONGLONG>(qpc_position);
        audio->capture->ReleaseBuffer(frames);
      } else {
        DWORD flags = 0; ComPtr<IMFSample> sample;
        HRESULT hr = audio->reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0,
            nullptr, &flags, &audio->timestamp, &sample);
        if (FAILED(hr)) { Error(hr, L"Decode media sample"); return finish_partial(-1); }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) return finish_partial(-2);
        if (!sample) break;
        ComPtr<IMFMediaBuffer> buffer;
        hr = sample->ConvertToContiguousBuffer(&buffer);
        BYTE* bytes = nullptr; DWORD length = 0;
        if (SUCCEEDED(hr)) hr = buffer->Lock(&bytes, nullptr, &length);
        if (FAILED(hr)) { Error(hr, L"Decode media buffer"); return finish_partial(-1); }
        audio->pending.resize(length / sizeof(float));
        std::memcpy(audio->pending.data(), bytes, length);
        buffer->Unlock();
      }
    }
    int64_t chunk_start_us = static_cast<int64_t>(audio->timestamp / 10 + static_cast<int64_t>(audio->cursor) * 1000000 / 16000);
    if (start_us < 0) start_us = chunk_start_us;
    int count = static_cast<int>((std::min)(static_cast<size_t>(capacity - filled), audio->pending.size() - audio->cursor));
    if (count <= 0) break;
    std::memcpy(output + filled, audio->pending.data() + audio->cursor, count * sizeof(float));
    audio->cursor += count;
    filled += count;
  }
  *pts_us = start_us < 0 ? 0 : start_us;
  return filled;
}

API void aa_cancel(void* handle) {
  Init();
  auto audio = static_cast<Audio*>(handle);
  if (!audio) return;
  if (audio->client) audio->client->Stop();
  if (audio->reader) {
    ComPtr<IMFMediaSource> source;
    if (SUCCEEDED(audio->reader->GetServiceForStream(MF_SOURCE_READER_MEDIASOURCE,
        GUID_NULL, IID_PPV_ARGS(&source)))) source->Shutdown();
  }
}

API void aa_close(void* handle) {
  Init();
  auto audio = static_cast<Audio*>(handle);
  if (!audio) return;
  if (audio->client) audio->client->Stop();
  delete audio;
}
