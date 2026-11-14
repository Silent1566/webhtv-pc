# 直播交互优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. 文件边界独立的 A/B 并行执行；协调者独立审查，不代写实现。

**Goal:** 保留现有直播页骨架，打通列表与播放器的选源、切台、换线路、节目单回看及状态同步。
**Architecture:** 一份页面生命周期内 LivePlaybackSession 连接直播列表与播放器；列表的加载仍可沿用现有 LiveService/EPG 缓存。播放器拥有专用右侧覆盖抽屉而不是复用点播选集。会话选择与实际播放请求一起更新；异步加载必须防止过期结果覆盖新选择。
**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4 / Material 3 / media-kit / Windows。
**Spec:** 本文件的需求收敛记录（用户逐项确认）。

## Global Constraints
- Android C:\Users\Maple\orca\workspaces\webhtv\dev5 只读参考。
- 保留现有深靛/琥珀视觉体系，颜色/间距/字重取 tokens.dart；只用真实 400/700 字重；无阴影。播放器恒定暗色，应用列表支持亮色。
- 不变更配置协议、Header/代理鉴权边界、缓存服务、点播选集/历史恢复能力；不得内置第三方资源。
- 不改全局主题，不添加依赖，不提交、不推送、不重置工作区。
- 原始工作区 git status --short 为空；基点 HEAD 6abf6f9。
- Flutter 使用 & 'C:\dev\flutter\bin\flutter.bat'；命令工作目录 apps/desktop-flutter。输出存到 .local/live-interaction/，只报告结论与错误窄段。
- 自检优先写回归测试再实现，旧测试若锁定已确认改变的点击语义可调整，其余断言保留。
- 完整实现后视觉检查统一批次；全任务最多2轮视觉验收（首轮+修复后确认），不能无限美化。

## 需求收敛记录
- 保留直播页三列。单击频道直接打开播放，同时右侧详情跟随；提供独立详情/节目单入口，避免仅能开播而无法浏览。行尾播放按钮保留可达性。
- 播放器右侧覆盖抽屉支持源、分组、频道、线路、当前频道节目单。浏览其它源/分组不能打断当前播放；点频道/线路才换播。加载/失败/空态均有反馈及重试。
- 抽屉行尾线路入口可用；双击当前频道可展开线路。底部既有 episodes 配置槽在真实直播模式下变成「线路（N）」而不是「选集」。点播选集原样保留。
- PgUp/PgDn 真实直播模式跨分组切台；保留上下键音量。快捷键说明跟随模式；回看不当成直播线路/剧集自动连播。
- 节目单：已结束且声明 catchup 的节目可回看；当前节目不可回看；有明确回看态与回到直播入口。EPG 缺失/失败不阻塞播放。
- 返回直播页同步最后实际播放的源/频道并滚到可见；不是同步尚未播放的浏览候选。
- 列表改善分组定位、频道密度、选中反馈与线路标签；长标题和长URL不挤爆布局。URL通过 tooltip/详情仍可查看，不能用未经测量的「可用」状态误导。

## 共享接口契约（A/B）
B 在 lib/ui/live_playback_session.dart 实现如下接口。A 只消费，不编辑 B 文件。其余内部接口由 B 自主设计。
```dart
class LivePlaybackSession extends ChangeNotifier {
  LivePlaybackSession({required AppState state, required LiveSource source,
    required LivePlaylist playlist, required LiveChannel channel,
    int lineIndex = 0, EpgGuide? guide, EpgProgram? initialProgram});
  LiveSource get source;
  LivePlaylist get playlist;
  LiveChannel get channel;
  int get lineIndex;
}
```
PlayerPage 新增 `final LivePlaybackSession? liveSession;` 可选构造参数，不改变其余调用方。session由创建它的LivePage持有，await Navigator.push后读取状态并dispose。B 可以增加成员/方法，不能改变上面A使用的签名。播放请求继续由 LivePage.requestForChannel 与既有回看入口构造；B 保证 PlayerPage(session,request) 的初值兼容。B 若提取 PlaybackRequest，player_page.dart 必须 export 保持旧 import 兼容。

## Task A: 直播列表/UI与会话入口
**Goal:** 改善三列体验，单击开播、提供独立详情入口、返回同步播放器最终选择。
**Boundary:** 可编辑 lib/ui/live_page.dart；test/phase3_live_page_test.dart；可新增 lib/ui/live_page_widgets.dart、test/live_page_interaction_test.dart；证据 .local/live-interaction/task-A-report.md。禁止修改 player_page.dart、live_playback_session.dart、B测试或全局状态/主题。
**Constraints:** Global Constraints与需求收敛记录全部适用。加载/EPG仍走AppState服务。不要在build里触发播放或请求；避免对所有频道一次性构建巨大树。不要把「选中」伪装成已经成功播放。
**Limits:** 实现派发运行：单位run，累计上限3（首轮1+返工2）；内部编辑/测试尝试：单位次，累计无上限。
**Limits:** 产品/测试文件修改：单位文件，累计上限4（上列4个）；报告/截图证据文件：单位文件，累计上限10，不占产品文件额度。
**Limits:** 工具命令执行：单位命令，累计无上限；测试运行：单位次，累计无上限；禁止睡眠/轮询等待。
**Limits:** 独立任务并行：单位子代理，累计上限0；UI视觉自查轮次：单位轮，累计上限1，之后由协调者统一验收，额度不重置不结转。
**Acceptance Criteria:**
1. 加载首源；另一源加载失败不影响首源；EPG失败仍显示频道与播放入口。
2. 单击频道能产生正确PlayerPage(request, liveSession)并更新预览；独立详情入口不打开播放器；选择线路N请求index=N。
3. 返回读取session最后源/频道/lineIndex，补齐列表缓存/EPG，定位真实频道；UI无误用旧源/旧频道。
4. 固定布局窄到800x600 widget viewport、1024x640实际窗口及1440x900宽屏均不溢出；长频道名/源名/URL保持可达。
5. 列表明显改善选中反馈与线路标签，使用分组/频道惰性构建或避免全树 eager 构建；不堆造大信息卡片。
**Required Evidence:** 报告路径、文件清单、每项验收映射、测试命令及pass/fail数、是否调整旧断言及原因、残余问题。
- [ ] 写测试：详情入口仍可浏览；单击开播；带Header的线路初值；返回状态同步；窄窗长文本；EPG失败。
- [ ] 运行测试观察预期新功能缺失；实现界面与session构造/返回同步。
- [ ] 运行 `flutter test test/phase3_live_page_test.dart test/live_page_interaction_test.dart --reporter expanded`（若没新增第二测试则去掉不存在项）；分析自己修改文件。
- [ ] 写证据，向协调者报告；不要提交。

## Task B: 会话、抽屉与播放器闭环
**Goal:** 完成共享会话与播放器直播控制，正确区分直播/回看/点播并保证切换一致。
**Boundary:** 可编辑 lib/ui/player_page.dart、lib/ui/player_controller.dart（仅为直播 latest-wins 的取消/重试有界闸门，不改变点播默认行为）；可新增 lib/ui/live_playback_session.dart、lib/ui/player_live_panel.dart、lib/ui/player_live_line_panel.dart；必要时提取 lib/core/playback_request.dart并在player_page export；test/live_playback_session_test.dart、test/player_live_panel_test.dart、test/player_live_controls_test.dart；必要时修改一个现有player回归测试。证据 .local/live-interaction/task-B-report.md。禁止编辑LivePage/A文件、全局AppState、theme/tokens、配置/网络服务。
**Constraints:** 会话生命周期契约如上；所有source/channel/line切换要重建正确title/Header/playLines/episodeIndex，而不是沿用旧频道请求。没有session的directUrl请求不自动假设是真实直播；回看请求仍可seek，不能自动轮播「线路」。播放器不能因打开/关闭抽屉改变画面尺寸。Esc优先关闭抽屉/线路面板，再退出全屏。抽屉关闭恢复焦点。手动切换和失败回退不允许旧异步请求落回旧频道。
**Limits:** 实现派发运行：单位run，累计上限3（首轮1+返工2）；内部编辑/测试尝试：单位次，累计无上限。
**Limits:** 产品/测试文件修改：单位文件，累计上限10（Boundary）；报告/截图证据文件：单位文件，累计上限10，不占产品文件额度。
**Limits:** 工具命令执行：单位命令，累计无上限；测试运行：单位次，累计无上限；禁止睡眠/轮询等待。
**Limits:** 独立任务并行：单位子代理，累计上限0；UI视觉自查轮次：单位轮，累计上限1，之后由协调者统一验收，额度不重置不结转。
**Acceptance Criteria:**
1. 会话初值/Header保留；选择源仅浏览；实际频道/线路选择原子更新；跨分组PgUp/PgDn正确；空频道/空线路不可播放；源加载失败能重试。
2. 覆盖抽屉有常驻可达按钮（例如直播源/频道），实际播放频道/源明确，不以browse source覆盖playing source。多线路入口、当前选中线路、节目单含当前/已结束状态。
3. 底部episodes槽直播改线路，点播仍选集；直播prev/next不把线路当剧集；回看有回直播且seek保持。
4. 回退支持单线路频道跨源（现实现lines.length<=1提前return是具体需修正的缺陷），不能无限跨源循环或台名匹配到CCTV5+；回退与抽屉/标题/源高亮同步。保持liveSettings.changeLine/sourceFallback开关。
5. 请求切换后的异步加载/失败不会把新选择回滚；关闭抽屉再重开能看到最新播放态。PgUp/PgDn不在输入文本/其它弹窗中误触。
6. 800x600、1024x640、1440x900及长名称/长URL无布局异常；打开抽屉不缩放视频；EPG失败不阻塞。
**Required Evidence:** 报告路径、接口最终形式、文件清单、各验收项映射、测试命令与pass/fail数、所发现边界问题与修复、不支持项。
- [ ] 阅读player_page关键区（_load、_fallbackLiveLine、_playEpisode、build、_buildActionButtons、_showEpisodes、快捷键说明）；Android LiveDialog/LiveLineDialog/LiveActivity只读参考。
- [ ] 先写会话/控件回归：快速source加载竞态、频道Header变更、单线路跨源、回看回直播、点播按钮不变。
- [ ] 实现契约，第一时间通知协调者session文件已建立；不等待A即可实现独立抽屉与PlayerPage。
- [ ] targeted flutter test与flutter analyze；player历史/overlay/上下集回归。仅报告通过的真实命令，不称没跑的测试通过。
- [ ] 写证据，向协调者报告；不要提交。

## Task C: 协调者验收
- [ ] 检查所有修改diff及接口契约、需求覆盖，必要时返工给原作者（最多2次）。
- [ ] 独立运行新测试、phase3_live_page、phase3_live_service、phase3_live、phase9_live_catchup、player overlay/上下集/按钮回归及analyze。
- [ ] 构建Windows并用现有fixture和integration截图路径真实渲染直播页/抽屉/线路/回看（不同窗口尺寸一起检查）；最多2轮视觉验收。
- [ ] 记录真实缺陷与处置；最终报告改动/验证/未做。不得仅凭子代理自述宣布完成。

## Preflight Review
| 对象 | 检查 | 结论 |
|---|---|---|
| A/B文件 | 文件边界 | 无共同修改文件；报告不同；共享Flutter测试运行须避免并发锁异常 |
| A/B接口 | session ctor+getters+PlayerPage.liveSession | B生产A消费；签名上文锁定；初始回看通过initialProgram |
| A内部 | 单击开播与详情入口 | 独立按钮让节目单仍能被浏览；旧预览tap断言需更新 |
| B内部 | live/directUrl/回看 | 以session模式区别，不以directUrl一刀切 |
| C | 图与测试证据 | 无假定真实站点可播；用fixture验证 |

## 最终状态
A run1、B run3、C run2完成；D run3 Spec/Quality PASS。协调者246项相关回归与静态分析通过；最后OSD单点补修17项通过。Windows1440/1600正式完整流程通过，1024单例正式无采图补验通过。保留15张截图，1024回看/返回两张缺图，旧OSD图先于末次文案修正；不称某次4/4全过。未commit/push，保留dev1工作区。详细记录 `.local/live-interaction/delivery-summary.md` 与各报告。任务fixture18181已停止。
