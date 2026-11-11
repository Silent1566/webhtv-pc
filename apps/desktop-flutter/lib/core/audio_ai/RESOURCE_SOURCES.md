# 音频AI官方资源与许可证

## 引擎（与权重许可分开）

- sherpa-onnx：k2-fsa 官方 `sherpa_onnx` / `sherpa_onnx_windows` 2.0.1，Apache-2.0，https://github.com/k2-fsa/sherpa-onnx 。Dart archive SHA256 `fce38e628bacdd0ff9dd3e11011657b96611158685ef08985a3203cef6e0d171`；实际Windows x64 `sherpa-onnx-c-api.dll` 与 `onnxruntime.dll` 来自官方pub包，不复制Android ARM JNI。
- Google LiteRT：`ai-edge-litert` 2.3.0 官方 Windows x64 wheel，Apache-2.0，https://pypi.org/project/ai-edge-litert/2.3.0/#files ，wheel SHA256 `b33b039667da6c57815f88d4709c1b31890375fa2cd35f165a3bf9dfd36f23a3`；其中 `ai_edge_litert/libLiteRt.dll` 为 6259200 字节，SHA256 `fd1ee59560a7aa13d44614bd4344c9a75070c18c9faf29792b1841f22dae6add`，真实导出经典 `TfLite*` C API。CMake仅下载/校验/解包；不运行wheel/Python/未知脚本。
- Windows Media Foundation / WASAPI：Windows系统API，无外部DLL下载。微软官方进程loopback样例要求build20348+：https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/ApplicationLoopback 。当前同进程播放器不能隔离本机TTS，故默认使用授权媒体独立SourceReader解码，不声称是mpv PCM tap；外部专属播放器PID可用INCLUDE_TARGET_PROCESS_TREE，不默转系统混音。

## 模型（不是引擎许可证）

8个ASR权重逐条复制源 `RealtimeSubtitleModelCatalog.java` 的固定revision、size、SHA256。正式激活前逐文件SHA256校验；下载/本地导入路径相同。许可证核验曾对下列每个固定revision的官方HF API发起请求，本次均18秒超时，**权重许可未核验**；不能以sherpa的Apache-2.0代替。下载动作由用户明确触发，UI显示此状态，不打包ASR权重。

| ID | 官方仓库与固定revision | 权重许可状态 |
|---|---|---|
| zh | https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/tree/204ad334e2e683fd295359930cc16fc0432a23ac | 未核验 |
| en | https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/tree/d42f2d9f7ca24806fb667456a18a9f1b60f70d16 | 未核验 |
| yue | https://huggingface.co/csukuangfj/sherpa-onnx-wenetspeech-yue-u2pp-conformer-ctc-zh-en-cantonese-int8-2025-09-10/tree/c911764e8227cf372ee60adc75f7f407e5b8c905 | 未核验 |
| de | https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-de-kroko-2025-08-06/tree/887db3d083240198c2d2b99fb66cfcfe6948ced8 | 未核验 |
| fr | https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06/tree/08b84b7b7cf519be9817e9c16919d96a7a8bad91 | 未核验 |
| es | https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06/tree/20cf7a4921613397841d31168796cade5b866585 | 未核验 |
| ja | https://huggingface.co/csukuangfj2/sherpa-onnx-moonshine-tiny-ja-quantized-2026-02-27/tree/550e2eb0a8b33092f3b394f64649ee1b3d9eb506 | 未核验 |
| zh-en | https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/tree/98590b7ed6443e77b714204da2757d75e1a642f4 | 未核验 |

Silero VAD：官方 https://github.com/snakers4/silero-vad ，本次直接读取LICENSE确认为MIT；sherpa模型资产643854字节、固定SHA256在catalog，下载后验签。

BasicPitch：本仓资产 `assets/models/basic_pitch_nmp.tflite` 精确复制只读Android源 `webhtv/dev5/app/src/main/assets/models/basic_pitch_nmp.tflite`，204448字节、SHA256 `3db297d54af8e01c6e5618245c956b1d71b6a2b978cb2dedb527173186552676`。Spotify官方项目 https://github.com/spotify/basic-pitch ，LICENSE实际读取为Apache-2.0；本源资产变换/量化的完整上游训练来源不可仅凭模型文件确认，保留此不确定性。不会把正弦逻辑测试说成真实人声或完整歌曲验证。

## 用户可见失败与取消

未配置/关闭：不采集、不额外拉流、不影响播放。授权媒体解码沿用Cookie/Referer和本地代理URI，额外带宽/CPU由UI说明。DRM/不支持编解码/无音频/URL失效只停字幕、报HRESULT；不退回当前PID混音。模型下载取消保留.part且不激活；SRT任何块最终失败不写正式缓存；BasicPitch取消/质量不够不写评分轨。
