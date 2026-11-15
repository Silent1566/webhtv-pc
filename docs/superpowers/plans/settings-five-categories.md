# 设置 IA：五类分类（去「高级设置」中枢）

## 范围与决策
- 用户要求：继续拆分重构设置 UI，**不改功能、只调界面**；点名两处不一致——「播放设置下的高级设置塞太多东西」「屏显和其他设置不一样，直接展开的」。
- 本轮只动 UI 与测试；不改任何配置字段、默认值、保存时机、校验与危险操作语义。
- 访谈（3 问 + 1 轮确认，均采纳推荐项）定下的目标形态：
  - 顶层分类 4 → **5**：偏好 / 播放 / 站点与内容 / 连接与服务 / 维护；**「高级设置」中枢整页删除**，它的 19 个控件按用途散入五类，任意设置**最多两级可达**。
  - **屏显（OSD）** 从「播放」类里就地展开的 7 个开关改成一行入口 + 独立明细页（行内只留「已开 N/7」摘要）。
  - 维护类末尾三块长文本（本地数据 / 运行信息 / 隐私与合规）进「关于与数据」页。
  - 播放器右键两处落点：弹幕库设置 → 弹幕源页（原先是错跳到中枢）；「完整设置页…」→ 新增的可 push「全部设置」页（菜单项 id 改为 settings_overview_page）。
- 不改的东西（逐字保留）：所有旧控件 `settings-*` key、`state.set*` 调用点、每行的 value 来源与 subtitle/subtitleKey、即时保存时机；纯数据摘要文本只增读取，不引入新默认行为。

## 执行拓扑：Hybrid
共享 seam 由协调者先冻结（分类模型 + `SettingsCategoriesBody` 中枢本体 + 三个新页），随后测试适配、截图采集、只读审查并行/串行派发。

|任务|写入边界|运行次数/上限|状态|
|---|---|---|---|
|CORE 中枢与五类|lib/ui/diagnostics_pages.dart、settings_detail_pages.dart（重命名）、osd_settings_page.dart、settings_overview_page.dart、player_page.dart|协调者实现；analyze 0 issue|完成|
|D 测试适配|test/**、integration_test/**|2/3|完成，独立复跑一致|
|R 只读审查|仅 .local/settings-refactor-2/static-review.md|1/3|完成，4 条已改、2 条已裁|
|C 截图采集|tool/settings_capture_test.dart、.local/settings-refactor-visual/after/**|1/3|执行中|
|验收|协调者实跑 + 读图对照|—|待 C 返回|

路径除另有说明外相对 apps/desktop-flutter。

## 验收标准
- 旧 key 逐字保留：机械核验 `state.set*` 调用多重集 HEAD == 现在（IDENTICAL）；key 差异仅 4 删（settings-advanced-open/-summary、settings-ai-assist-open/-summary，后两者与 settings-ai-business-open 同指 AiBusinessPage 的重复入口）+ 3 增（settings-osd-open、settings-live-open、settings-about-data-open）。
- 五个分类都有真实导航锁：切换不落盘、滚动位置独立保留、键盘可达、480/720/1024/1440 × 暗亮不溢出、同一时刻只渲染当前类。
- 结构锁：12 个明细 key 在**每个**分类页里 `skipOffstage:false` 均不得存在；分类页里的 SwitchListTile 只允许那 5 个就地生效的。
- 矮窗：480×320 与 1024×300 不溢出，且左栏 `maxScrollExtent > 0`（证明「滚得到」而不是「画不下就不画」），五类逐个 hitTestable + 点得动 + 语义选中。
- 独立路由（OsdSettingsPage / LiveSettingsPage / AboutDataPage / SettingsOverviewPage）都自己监听 `AppState`，拨开关不回弹。
- Before/After 同场景、同视口、同主题、同字体逐张对照。

## 运行与审查记录
- CORE 自查：`flutter analyze`（diagnostics_pages / settings_detail_pages / osd_settings_page / settings_overview_page）全部 No issues found。搬迁后 `state.set*` 多重集与 HEAD 一致。
- R（只读静态审查，run 1/3）：lib 侧未发现功能漂移；布局骨架与改动前逐字相同；4 条按报告修掉（分类 key 唯一性改成「同一页面内」、删多余空行、「18 行」→「19 个控件」、`_switch` 去掉转发壳改 `ValueChanged<bool>`），2 条裁决不采纳/收下（`osdSummary` 依赖 AppState 故不进 Flutter-free 的 core；settings-ai-assist-* 退役在本文档显式豁免）。
- D（run 1/3）：19 个清单内套件 215 passed / 1 skip / 0 failed；删 33 条 expect、加 67 条，无新增 skip，无放宽匹配。
- 协调者独立复跑：settings_categories_navigation +12、advanced_settings_navigation +16、phase8_settings_entries +9、settings_overview_page +2，全部 All tests passed。
- 源码缺陷（D run 1 报告第 7 条）：分类从 4 增到 5 后左栏在矮窗 RenderFlex overflow（480×340 可复现，1024×300 需多 76px）。修法：`_categoryRail` 包 `SingleChildScrollView`，栏自己可滚。
- D（run 2/3）：新增矮窗用例（takeException 为 null + 五类逐个 hitTestable/tap/语义）；「滚动位置独立保留」视口从 460 还原为 340（依据：340 下左栏 maxScrollExtent = 36 > 0，仍在溢出边界附近）；24 个套件复跑 274 passed / 1 skip / 0 failed；analyze 与 format 干净。
- 环境事实：player 挂载类套件需 `LD_LIBRARY_PATH`/`LIBMPV_LIBRARY_PATH` 指向 `.local/mpv` 那份 libmpv.so.2，否则报「Cannot find libmpv」（与本次改版无关，用未改动的套件可对照复现）。`/tmp` 是 2.2G 的 tmpfs 且已满，测试与截图都要 `TMPDIR=/home/maple/.cache/flutter-tmp`。

## 最终验收（协调者）
- 测试（协调者在**最终树**上实跑，不采信子代理自报）：settings_categories_navigation +12、advanced_settings_navigation +16、phase8_settings_entries +9、settings_overview_page +2、phase8_context_menu_content +21 —— 60 passed / 0 failed。子代理全量轮：24 套件 274 passed / 1 skip / 0 failed（skip 是 browser_component 的截图门禁用例）。
- 静态：`flutter analyze lib` 无 `lib/ui/` 命中（79 条全是 karaoke/services 既有 lint）；本轮新增/改动的 4 个 lib 文件 `dart format` 0 changed。player_page.dart 的 68 行 format 漂移是 HEAD 就有的（已核对：HEAD 与现在同为 68，且不含本轮编辑的标识符），未顺手重排。
- 视觉：Before 8 张（`.local/settings-refactor-visual/before/`）+ 4 张分类页（`before-cats/`），After 22 张（`after/`），同场景同视口同主题同字体。逐张结论：
  - `cat-playback`：改前 2 行入口 + 就地摊开的 7 个屏显开关（「网速」副标题被挤成两行、行内缩进与其他行不一致），改后 7 行统一入口、一屏放下、屏显行只留「已开 4/7」。
  - `hub-*` → `cat-sites-* / cat-connections-* / cat-maintenance-*`：改前 5 个分区 19 个控件要滚两屏；改后三类各自一屏 6-8 行。
  - `cat-maintenance`：三块长文本（本地数据/运行信息/隐私与合规）消失，剩 6 行 + 「关于与数据」入口，分类名「维护与说明」→「维护」。
  - 新页 `osd` / `live` / `about-data` / `overview`：渲染正确，7 个屏显开关一屏放下且「网速」说明独占一行；「全部设置」页有 AppBar 标题且正文不重复画标题。
  - 矮窗 `home-dark-480x320`：5 个分类 pill 换行（第一行 4 个、第二行「维护」），无溢出条；`home-dark-1024x300`：左栏可滚（maxScrollExtent 76），第 5 类需滚一下。
- 已知取舍（协调者裁决，非隐藏项）：
  - 480 宽下就地开关的副标题会换行成 2-3 行，而入口行副标题固定 1 行截断 → 同一列表两种行高。**不改**：开关行没有下一级页面，副标题就是唯一信息载体（「日志量很大，排查完请关掉」被截掉是实打实的损失），这是改造前就有的行为，不是本次引入。
  - 300px 高的窗里左栏只露 4 类、须滚动见第 5 类：接受（栏可滚本就是为矮窗做的取舍），480 宽走 pill 条则 5 类全可见。
  - `about-data` 两张图会打印本次运行的随机临时目录名，跨次运行不字节稳定（页面职责就是展示 paths），不作为 diff 基线。
  - `settings-ai-assist-open/-summary` 随中枢退役：它与 `settings-ai-business-open` 原本打开同一个 AiBusinessPage，属重复入口合并，**显式豁免**。
- 未做：两个 `integration_test` 视觉矩阵（settings_refresh_visual / settings_categories_visual）已按新结构改好且 analyze 干净，但本机无 Windows 原生/设备环境，**未实跑**；原生 Linux/Windows 集成构建仍缺 clang++/GTK 头，截图是 widget-test 渲染而非真机。未提交、未推送、未打包。
