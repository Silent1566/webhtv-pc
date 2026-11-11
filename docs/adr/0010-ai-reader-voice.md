# ADR 0010 AI阅读器Neural TTS与语音搜索的Windows真实host适配

状态：接受。日期：2026-11-10。

## 背景

源Android阅读器朗读（`TtsEngines`/`ReaderTtsController`/`EdgeTtsEngine`/`WebReaderActivity`桥）有system/edge/baidu/custom四音源；语音搜索依赖Android系统SpeechRecognizer（可能联网）。PC端没有Android TTS服务与SpeechRecognizer。

## 决策

1. **system音源**：Windows真实host = PowerShell + .NET Framework `System.Speech`（系统内置，无新增依赖）。合成走临时WAV再由播放层消费；识别走默认麦克风+DictationGrammar。系统缺voice/recognizer、进程失败、超时、取消都公开真实错误并清理临时WAV，**不伪造文本、不承诺离线**。
2. **edge音源**：忠实移植Edge大声朗读WebSocket协议（wss端点、TrustedClientToken、Sec-MS-GEC 300秒窗口SHA-256、speech.config+ssml帧、按X-RequestId匹配音频帧、turn.end收尾）。生产是真实网络合成；测试用本地WS fixture。
3. **baidu音源**：保留原`fanyi.baidu.com/gettts`规则，真实HTTP。
4. **custom音源**：仅接受legado安全子集（GET/POST、`{{speakText}}`/`{{speakSpeed}}`/`java.encodeURI`/算术），构造期拒绝`@js:`、登录/JS规则、非HTTP(S)地址；不执行脚本、不起进程。
5. **隔离**：reader全部新文件（`lib/core/reader/`、`lib/services/reader/`、`lib/ui/reader/`、`speech_search_service.dart`、`speech_search_button.dart`），不改shell/search/player/pubspec/windows。TTS不依赖AiConfig。
6. **偏好持久化**：任务专属`reader_tts.json`（configDir下，pid独占tmp原子写），与共享settings.json写合同解耦；重启恢复source/voice/rate/pitch/timer，超范围值夹取回0.5–2.0/0.5–1.5/0–600分钟。
7. **播放**：引擎产出真实音频字节；media_kit播放由统一集成任务接线，controller接受`ReaderAudioOutput`注入，测试注入fixture。合成过期代际（取消/seek/停止后返回）不应用。

## 后果

- 真实识别/合成结果依赖机器已装voice/recognizer与网络；不可用是显式UI错误而非静默。
- Edge协议非官方稳定接口，Chromium版本常量需随上游更新。
- 未验证项：真实Windows麦克风识别、真实Edge/百度端到端音频播放（不运行付费AI/不真实录音，fixture覆盖协议逻辑）。
