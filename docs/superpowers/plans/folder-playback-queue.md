# 目录直播放与同目录选集计划

## 已确认设计
用户确认开始：视频点击直接播放，同目录视频作为可分页选集与连播队列；目录显式切换文件列表/剧集模式，目录名为显示剧名、文件名为集名；不自动把无子目录判为电视剧，不改变bridge聚合。每个文件自身detail/player按需解析，不把文件ID当URL，不预先拉所有视频详情。普通详情、直播、画质、字幕/弹幕及历史来源必须保持。

## 拓扑：Hybrid
协调者已冻结并验证core/playback_queue.dart（snapshot防外部变更1测试通过、分析清洁）。目录适配和播放器适配并行，文件范围不重叠。最后独立review与串行回归/截图验收。

## 冻结interface
- PlaybackQueue implements Listenable：snapshot，loadMore()，resolve(String itemKey,{bool Function()? isCurrent}) -> Future<PlaybackRequest>。
- PlaybackQueueSnapshot：不可变items[key,title]、hasMore、loading、AppError? error；key是不透明文件身份。
- PlayerPage增加可选PlaybackQueue? queue、String? queueItemKey；null保持旧行为。完整请求取当前文件身份，目录下标不等于request.episodeIndex。队列生命周期由创建它的目录路由拥有。

## Task A：目录adapter（run 1）
范围：folder_browser_state.dart、folder_browser_page.dart、新folder_playback_queue.dart、必要新folder_episode_view.dart、目录相关test；不能修改player/request/core接口/app_state。
- [x] TDD实现队列自然排序、原样ID/筛选、去重分页、只有目录页仍可继续到视频/错误/EOF。明显非视频附件与action不得进入队列；无后缀正常影片可经detail确认可播。跨分页自然排序不得丢当前key或遗漏下一视频。
- [x] lazy detail/player构建完整文件request，source context/headers/quality/subtitles/danmaku保留；失败可重试、过期不推路由/覆盖proxy。
- [x] 视频点击直接PlayerPage(queue,queueItemKey)，已有bridge仍DetailPage。显式文件/剧集视图，剧集视图按目录名及文件名渲染，不伪造TMDB。
- [x] 同当前目录场景Before/After，1280×900暗色完整CJK；保留父层分页/滚动/模式。

## Task B：播放器adapter（run 1）
范围：player_page.dart、player_episode_panel.dart、可新player_queue_panel.dart、播放器队列test；不能修改目录/request/core接口/app_state/controller。
- [x] TDD可选queue整请求换文件，generation守护，切换前保存旧进度；失败pending key可重试，不误重开上一文件。
- [x] 目录队列选集/上一下一/自动连播基于key；末页前补页，错误不当EOF；repeat all仅真EOF循环，one与autoNext关闭不额外拉页。
- [x] 动态队列面板加载更多/失败重试且当前项稳定；文件内部切线路保持原功能。
- [x] 画质仍本文件player解析；queue模式失败重试及从进度续播重新解析本文件入口，不用过期URL，不串字幕弹幕。
- [x] 同播放器选集场景Before/After截图及定向历史/自动连播回归。

## Acceptance（提交阶段独立复核）
- [x] 读关键diff并独立复测queue、目录UI、player、原来源/历史/重复/竞态。
- [x] 两组同场景Before/After；分析仅修改文件，git diff --check。
- [x] 每个缺陷回原子代理，implementation最多各3轮；未关闭缺陷不交付。

## 保护/环境
前次8文件已复制至.superpowers/folder-playback/baseline；其改动是既定基础，不回退/覆盖。只有已分配目录文件允许增量修改；不提交、不打包、不动安卓或依赖锁。SDK /tmp/webhtv-linux-sdk/flutter-3.47.5；TMPDIR工作树；libmpv用.local/mpv已有库；编译测试--concurrency=1，两个子代理不得并行运行Flutter，先A后B。

## 提交阶段补充

- 退出播放器后重新从目录打开文件时重置一次性续播标记；保持播放器内重复解析/切集不再续播，补同文件与不同文件返回重开回归。
- 本地字幕输入框交由 TextField 管理 controller 生命周期；字幕候选最终 native 应用完成后校验播放 generation，旧文件迟到结果不写新文件记忆、不报成功。
- 两处新增测试改为 config/data/cache/state 四个独立目录的显式覆盖，修复路径隔离契约违规。
- 合入最新 beta 后机械同步 preferredParseName：本次 QueueState 与 beta 自带 8 个测试替身，9 文件仅 13 行新增参数/转发，生产逻辑与原测试断言不改。
- 用户确认限定修复、基线核对并创建中文草稿 PR。提交前全量的 68 项失败在原 HEAD 基线全部复现，0 不匹配、0 额外失败；原 HEAD 与修正后均有相同 6 处既有路径隔离违规。不得宣称全量通过或合并 PR。
- 功能相关 11 套件 98 项及九个兼容测试文件静态分析通过；合并后完整回归由提交阶段独立验收记录与 PR 描述记录最终结果。
