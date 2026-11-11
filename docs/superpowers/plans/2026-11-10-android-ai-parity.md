# 安卓 AI 全量迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement the assigned task only. Steps use checkbox tracking.

**Goal:** 将 webhtv/dev5 当前全部AI相关能力完整迁移到 webhtv-pc/dev2，真实业务接入而非预览占位。
**Architecture:** 复用 Flutter AI/播放器/数据底座；公共配置、内容智能、季集、原生音频、附属语音、统一集成分六个独占修改域。公共文件单owner，服务交付接口后由最后集成任务统一接线。
**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4 / media_kit / Windows native sherpa-onnx、TFLite适配。
**Spec:** `docs/superpowers/specs/2026-11-10-android-ai-parity-design.md`

## Global Constraints
- 源仓库 `C:\Users\Maple\orca\workspaces\webhtv\dev5` 只读；目标基线 `1d46802f468ebbf32ea7df71360a9177ac03d928`，既有隔离工作树 dev2，初始干净。
- 用户明确确认全部LLM、ASR字幕/翻译、BasicPitch卡拉OK、语音搜索和阅读器Neural TTS；排除已删除的语音去广/音频指纹和不存在的通用聊天。
- 完整保留真实入口→类型化验证→人工确认/原行为→业务应用→必要持久化与取消/失败。
- 官方Windows引擎、模型按需下载/固定版本/SHA256；允许本地导入；禁止伪造识别/评分或生产占位adapter。
- 不运行真实付费AI；网络仅官方依赖/模型/许可资料，下载不自动执行未知脚本；不请求sandbox升级、不改系统配置、不push/publish。
- 保持默认关闭和未配置时已有播放；NavigationRail/AppBar/Material度量/AppSemanticColors；不移动字幕轨与弹幕既有固定入口。
- 同一共享文件只有一个owner；并行期间不提交/暂存/重置其他人的文件。模块测试只跑自己的文件，最终全量检查由调度负责。
- 每简报运行次数：次，上限3，累计；每简报工具/测试次数不限，成功检查无相关修改不重复；命令单次前台等待秒，上限60，每命令重置，长构建可后台收集。
- 生产文件编辑上限按每任务简报所列独占域执行；不允许因上限缩减必需功能，真超范围向调度报告。

## Task 1: 公共AI配置与传输（A）
**Files:** core/ai_config.dart、新增core/ai_prompts.dart、services/ai_completion_client.dart、services/ai_config_store.dart、services/settings_file.dart、ui/ai_settings_page.dart，以及专属 ai_parity_config_test.dart / ai_parity_client_test.dart / ai_parity_store_test.dart。不改AppState/播放器/其他消费者。
**Interfaces:** 保持现有 AiConfig 构造/copyWith/toJson/fromJson/ready 与 AiCompletionClient.complete 兼容；新增安卓同名五套Prompt和Version/Custom字段，供B读取。新增超时/取消参数须兼容旧调用，并提前报告签名；AI设置保存继续返回现有配置类型。
- [x] 精读安卓AiConfig.java各DEFAULT/LEGACY/SANITIZE与AiCompletionClient协议、目标现有实现；给五套prompt旧版升级、自定义保护、别名/未知字段往返写失败测试。
- [x] `C:\dev\flutter\bin\flutter.bat test test/ai_parity_config_test.dart test/ai_parity_client_test.dart test/ai_parity_store_test.dart` 确认测试失败。
- [x] 移植五套原文与版本3/2/2/2/2，逐项重置UI；整包SSE按协议抽文本、完善取消/超时；统一settings分段写，不互相覆盖。
- [x] 同命令通过，增加旧ai_config/model/endpoint行为回归；执行限定文件dart analyze。
- [x] 报告真实接口、测试命令输出、文件清单与隐私/未知字段策略；不自行提交。

## Task 2: 原生音频、实时字幕与卡拉OK（D，可与A/E并行）
**Files:** 新 lib/core/audio_ai/、lib/services/audio_ai/、lib/ui/audio_ai/；pubspec.yaml/lock、Windows runner/CMake、scripts/package_windows.ps1；模型目录与专属 audio_ai_*测试。本任务唯一拥有依赖/原生构建文件，不修改player_page/controller/AppState。
**Interfaces:** 提供公开PCM帧/会话时钟/代际接口、RealtimeSubtitleController的状态/字幕流/启动停止seek处理、模型管理服务、卡拉OK生成评分轨服务与可嵌入UI。提前报告接口让F接线，不让F实现原生引擎。字幕翻译公开translateSrt请求/进度/结果，保持原SRT和时间轴，提供独立当前字幕/搜索候选使用方式。
- [x] 读取安卓RealtimeSubtitleModelCatalog/Recognizer/Controller/Translator、SubtitleTranslationService、BasicPitchTfliteGenerator/KaraokeTrackRepository；定向核验官方Windows资源与模型许可并记录来源。
- [x] 写合成PCM、校验坏哈希/中止下载、过期代际不显示、字幕cue ID验证/错误重试/原文保护、音高时间轨生成失败测试，确认红灯。
- [x] 实现官方sherpa Windows接入、固定catalog/断点下载/资源检查/本地导入、真实PCM采集与媒体时钟；zh原文/外语8秒翻译队列；SRT切片并发与缓存；BasicPitch真实TFLite推理与带时间戳歌词评分轨。
- [x] 覆盖模型加载和生产音频采集路径，测试由adapter模拟可重复但必须另报告真实native加载结果；运行专属测试及限定analyze。
- [x] 报告可直接接线的接口/子组件、依赖变化、许可来源、真实与模拟验证的区别；不把未运行模型推理说成实测，不自行提交。

## Task 3: 语音搜索与阅读器Neural TTS（E，可与A/D并行）
**Files:** 新 lib/core/reader/、lib/services/reader/、lib/ui/reader/、新lib/services/speech_search_service.dart与专用语音搜索组件，专属 reader_ai_* / speech_search_*测试；新增docs/adr/0010-ai-reader-voice.md。不改shared shell/search_page/player/deps，依赖需求给D。
**Interfaces:** 可嵌入语音搜索按钮回调首条识别文本；ReaderPage入口、ReaderTtsController段落/声音/速率/音高/计时/暂停停止；system/Edge Neural/baidu/custom模式忠实适配原宿主，沿用PC可用替代接口。生产Edge为真实网络合成，不以mock充当引擎。
- [x] 精读源CustomMic、WebReaderActivity tts桥、ReaderTtsController/TtsEngines与Edge实现；复用目标spider隔离与媒体网络约束，记录必要阅读器ADR。
- [x] 写段落推进/暂停停止/首条语音搜索/引擎不可用/设置重启恢复/合成协议本地fixture失败测试，运行确认红灯。
- [x] 实现必要阅读文本入口与段落朗读、Edge合成传输与音频播放、声音与参数设置持久化、timer；语音搜索提供Windows真实host adapter（离线/系统不可用如实提示，不虚构离线承诺）。
- [x] 专属测试与限定analyze通过；报告实际生产路径和UI嵌入接口、网络隐私提示、依赖需求。

## Task 4: 内容智能业务模块（B，A接口稳定后）
**Files:** 新lib/core/ai_content/、lib/services/ai_content/、lib/ui/ai_content/；现有services/viewing_report_ai.dart、core/viewing_report.dart、ui/viewing_report_page.dart、core/ai_assist.dart与services/ai_assist_service.dart；专属 ai_content_* tests。不改共享state/shell/browse/player/存储schema/底座。
**Interfaces:** 消费AiConfig五套原文；提供typed推荐卡/上下文/反馈store、结构画像、片名resolution/cache/learning、validated分组规则、validated用户广告规则、采集脱敏日志诊断。每个服务报告F需要的调用与应用类型；跨业务应用由F做，不能只交付预览页。
- [x] 读源Recommendation/FeedbackStore/Title/Group/Ad/Log/ViewReport所有真实合同，写12..24推荐/负反馈200条90天/片名置信度/分组Java兼容子集/广告黑白方向/日志脱敏/报告范围隔离失败测试。
- [x] 实现当前/历史/搜索输入，推荐TMDB富集/降级卡与缓存、负反馈过滤；片名规则先行及AI回退、30天缓存/500例学习；分组重复覆盖与安全规则、HLS最小证据/人工预览广告规则、日志自动采集/28Ki字符脱敏；结构报告及24小时指纹缓存。
- [x] 独占新目录内文件持久化必须可备份枚举，反馈/规则/学习是用户数据而非可丢缓存；输出完整接口清单与导入导出JSON。
- [x] 专属测试、既有辅助/报告测试与限定analyze；错误/取消/缓存失效全有证据。

## Task 5: 季集完整映射与元数据回退（C，A接口稳定后，与B并行）
**Files:** services/ai_episode_season_service.dart、services/tmdb_season_service.dart、services/tmdb_stores.dart、services/storage.dart、services/tmdb_identity_service.dart与新增专属季集/片名桥接文件及tests。不改AppState/browse/播放器；与B片名服务通过接口衔接，B拥有新片名AI模块。
**Interfaces:** 现有四mode结果向下兼容；提供显式逐集绑定落库/查询与snapshot校验的业务方法给F；FLAT按parsedNumber而非index，重复/缺号/越界一致；TMDB身份回退消费B的typed resolution。
- [x] 读安卓季集输入/四模式校验和目标绑定表，写缺号不偏移/重复号同集/越界跳过/显式完整唯一映射/截断拒绝显式/重启持久化失败测试。
- [x] 实现真实HTTP取消与完整四模式应用数据API，必要schema向前升级不破坏旧绑定；AI低置信度回退规则、片名自动消费者可注入服务。
- [x] 专属测试及现有season/identity/store回归、限定analyze；报告F应用方法和跨模块类型。

## Task 6: 统一业务接线与验收（F，各模块接口完成后）
**Files:** state/app_state.dart、ui/app.dart、ui/browse_pages.dart、ui/search_page.dart、ui/tmdb_widgets.dart、ui/tmdb_detail_page.dart、ui/diagnostics_pages.dart、ui/advanced_settings_page.dart、ui/library_pages.dart、ui/player_*、services/ui_preferences_store.dart、services/subtitle_service.dart、services/proxy_server.dart、core/ad_rules.dart、core/android_sync.dart、core/backup.dart及实际backup service；专属ai_parity_* widget/integration tests。不修改其他owner未移交文件；若接线需要模块变化，交还原owner。
**Interfaces:** 根据A-E报告的实际签名接线，不重新实现这些服务。settings读取开关默认false；AI配置prompt/key保真映射；备份至少配置、用户规则/反馈/学习/季集元数据，缓存与模型可重建。
- [x] 写从真实导航/设置/搜索/详情/播放器/历史/日志入口触发→结果确认→业务应用→重启或备份恢复widget/integration测试，确认预览壳旧合同不足而失败。
- [x] 接推荐条当前源搜片/全局fallback与负反馈；标题供TMDB/弹幕/字幕失败重试；分组保留手工只替换接口AI规则；广告反馈规则确认后供proxy执行；日志读取脱敏；四mode季集预览明细与应用。
- [x] 接当前SRT与搜索候选翻译、实时字幕模型/语言/原字幕恢复/seek代际、BasicPitch歌词评分与生成轨、语音搜索到现有搜索、阅读器入口/TTS完整控制；不在UI做spider直接联网。
- [x] 扩展备份/安卓桥接同名字段与未知字段保真，模型/缓存区分，跨范围报告状态清理。
- [x] 运行针对性widget/integration与限定analyze，报告每功能真实入口/消费/持久化/错误取消/验证路径对照表；不得仅说已完成。

## 最终独立验收
- [x] 逐任务关键diff与功能矩阵：spec合规、代码质量各给独立结论，发现缺陷必须回派或用户范围决策，不直接带缺陷交付。
- [x] 本地 `C:\dev\flutter\bin\dart.bat analyze` 与 `C:\dev\flutter\bin\flutter.bat test`，保存完整日志仅读摘要。
- [x] `C:\dev\flutter\bin\flutter.bat build windows --release`，验证资源/原生依赖实际打包；成功检查不重复。
- [x] 如实列出未进行真实AI质量/麦克风/下载模型长时推理的场景；未达完成标准不宣称全量迁移完成。



## Task 7: 卡拉OK真实唱声评分与轨仓库（补齐盘点漏项）
**Brief:** `.superpowers/sdd/2026-11-10-android-ai-parity/task-7-brief.md`
**Boundary:** 新core/services/ui/karaoke、karaoke_*测试、必要新Windows麦克风native及CMake/包装；不碰Task2现有audio_ai生产文件/Task6接线。
- [x] 迁移真实麦克风PCM/YIN/参考轨与自由唱评分，配置/校准/seek/暂停/错误生命周期。
- [x] 迁移轨仓库、解析、提供者和用户导入/生成轨导入及持久化；接口先给F接线。
- [x] 独立算法/协议/原生/控件测试与复审，纳入最终打包自足性验收；不把生成轨统计说成真实得分。

