# 外部播放器多版本与可编辑列表 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement the assigned task. Steps use checkbox syntax for tracking. 本轮的派发、等待、重派预算以 Dispatch Agent 开发者规则为准。

**Goal:** 在每次外调选择框中展示全部不同路径的播放器版本，并持久化可编辑的名称和路径及用户新增条目。

**Architecture:** 扫描与播放器配置数据独立实现；UI 使用现有 ExternalPlayer 类型及载入/保存回调，不参与扫描或持久化身份管理。保留每次先选择的入口，用户覆盖通过原扫描路径锚定；序号只作显示，不污染名称数据。

**Tech Stack:** Flutter/Dart、现有 Windows 登记探测、UiPreferencesStore、AppState、flutter_test；不新增依赖。

**Spec:** `docs/superpowers/specs/2026-11-09-external-player-catalog.md`

## Global Constraints

- 每次外调必须先选择播放器；上次路径只作预选。
- 选择框内新增和编辑；扫描和自定义条目均可编辑名称及程序文件路径。
- 同名使用序号；相同 exe 路径去重，不同路径全部保留。
- 新增/编辑持久化；保留 `ui.externalPlayerPath` 兼容与已有启动行为。
- 不改注册表、系统设置、其他播放器偏好、beta 程序、代理策略、启动参数规则或依赖。
- 不加入删除、隐藏、批量管理、独立管理页面或猜测版本号。
- 不能覆盖当前工作区其他未提交改动；不 git commit、push、merge、reset、clean 或 stash。
- 实现目录为 `apps/desktop-flutter`。SDK 为 `C:\dev\flutter\bin\flutter.bat`，Dart 为其 `bin\cache\dart-sdk\bin\dart.exe`。
- 测试使用临时文件、注入数据、假启动器；不请求真实站源，不启动本机安装的播放器。

## 公共契约

```dart
// 保持现有服务模型。
const ExternalPlayer({required String name, required String executable});

// Task 1 产生，Task 2 在 PlayerPage 中消费。
Future<List<ExternalPlayer>> AppState.listExternalPlayers();
Future<bool> AppState.saveExternalPlayer({
  String? originalExecutable,
  required String name,
  required String executable,
});
```

UI 的独立组件只依赖已有服务模型及回调，可以先编写和验证，不需要 Task 1 的内部模型。Task 2 最后连接 AppState 新接口时，若 Task 1 尚未完成，只记录依赖并由协调者安排集成复验，不创建另一份数据接口或修改 Task 1 文件。

### Task 1: 扫描、覆盖模型与持久化

#### Goal

完整扫描多版本，提供可编辑和可持久化的播放器目录，兼容旧设置且不制造重复或幽灵条目。

#### Boundary

允许创建/编辑以下实现与测试文件：
- `apps/desktop-flutter/lib/services/external_player.dart`
- `apps/desktop-flutter/lib/core/external_player_catalog.dart`
- `apps/desktop-flutter/lib/services/ui_preferences_store.dart`
- `apps/desktop-flutter/lib/state/app_state.dart`
- `apps/desktop-flutter/test/phase9_external_player_test.dart`
- `apps/desktop-flutter/test/phase9_external_player_catalog_test.dart`
- `apps/desktop-flutter/test/phase9_external_player_catalog_persistence_test.dart`
报告写到协调者指定的本计划 workspace `task-1-report.md`。不可编辑 UI、测试脚手架、其他已有测试或文档。

#### Constraints

遵守 Global Constraints 与 Spec。保持 ExternalPlayer 已有构造、字段、启动与扫描注入参数兼容。内部模型由本模块设计，至少保存名称、路径和覆盖原扫描路径锚点；可使用稳定 ID，必须满足重复编辑、显式选择后再次改路径、旧路径兼容，以及不会被扫描或旧预选路径复活已编辑的条目。

扫描必须同时保留有效登记位置与不同的默认目录安装，不再 first-hit break；去重应使用归一化路径而非名称。用户已编辑条目优先于原扫描条目。原路径已不可见时，保存过的条目仍保留。新增/编辑碰撞另一个条目的路径时返回 false，不静默丢掉数据。

`saveExternalPlayer` 的原路径参数用于编辑已有条目；再次编辑后仍指向同一持久化记录。载入和保存均不得额外启动播放器或调用网络。注册表访问可继续现有只读 PowerShell 单次批量方式。

#### Limits

- 实现尝试：单位为协调者派发的运行，本任务最多 3 次，首次与重派累计，不按工具或测试次数重置。
- 实现与测试文件：单位为唯一文件，最多 7 个，跨本任务所有运行累计，仅限 Boundary 清单。
- 报告文件：单位为唯一 Markdown 文件，最多 1 个，跨运行累计，后续追加同一报告。
- 命令运行：单位为命令，数量不限；不存在每轮命令配额或可累积余额。
- 自检测试循环：单位为测试运行，数量不限；不占协调者重派次数。
- 单次输出：单位为行，最多 80 行，每次命令独立重置，超出写入 workspace 日志并仅报结论。
- 临时诊断产物：单位为文件，最多 2 个，仅在本计划 workspace，运行结束清理，不占实现文件额度。
- 子代理：单位为子代理，最多 0 个；评审由协调者执行。

#### Acceptance Criteria

1. 多个不同 PotPlayer 路径均被扫描，登记及默认目录结果全部保留，大小写/分隔符等价路径只出现一次。
2. 序号不写入基础名称；重命名不影响协议判断。
3. 合并扫描结果、覆盖与自定义条目确定且不重复；连续编辑和重扫无幽灵条目。
4. 保存新条目、改名称、改路径后重启读取一致；旧的单路径设置仍可使用和编辑。
5. 取消不在本模块产生写入；无效/重复输入返回 false；其他设置保存不清空新段。
6. 提供公共契约精确签名且不破坏原 API；相关自检测试和本模块 analyze 通过。

#### Required Evidence to Report

逐项列出变更文件、失败测试与通过测试的命令和实际摘要、公共签名、旧设置迁移策略、重复路径/覆盖锚点策略、尚未验证项。记录测试中的真实路径全部为临时或虚构数据。只向协调者返回状态、报告路径及简短结论。

#### Steps

- [ ] 先运行下述同族多路径的失败回归，确保旧 first-hit 分支会漏掉第二条。

```dart
final players = ExternalPlayers.detect(
  operatingSystem: 'windows',
  environment: const {'ProgramFiles': r'C:\Program Files'},
  registeredCommands: const {
    'PotPlayer': [r'"D:\Portable\PotPlayerMini64.exe" "%1"'],
  },
  exists: (path) => const {
    r'D:\Portable\PotPlayerMini64.exe',
    r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
  }.contains(path),
);
expect(players.map((p) => p.executable).toList(), [
  r'D:\Portable\PotPlayerMini64.exe',
  r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
]);
```

- [ ] 写最小覆盖/持久化回归：扫描 A、编辑 A→B、重扫 A、再次编辑 B→C，仅返回 C；新建自定义 D 并重新 load 后仍存在；大小写路径碰撞不保存；仅旧 externalPlayerPath 的 JSON 仍可列出。
- [ ] 实现完整扫描、纯数据合并与设置读写，连接公共 AppState 接口。不得复制 UI 逻辑。
- [ ] 跑覆盖测试并 analyze 所有本任务实现文件，报告实际退出码和覆盖结论。
- [ ] 自审需求与质量，写报告，不提交 Git。

### Task 2: 选择框内列表、新增和编辑

#### Goal

每次选择时展示可辨识的多版本列表，在同一选择框新增/编辑名称与路径，并正确区分保存、使用与取消。

#### Boundary

允许创建/编辑以下文件：
- `apps/desktop-flutter/lib/ui/player_page.dart`
- `apps/desktop-flutter/lib/ui/external_player_picker_dialog.dart`
- `apps/desktop-flutter/test/phase9_external_player_picker_test.dart`
- `apps/desktop-flutter/test/phase9_external_player_catalog_dialog_test.dart`
报告写到本计划 workspace `task-2-report.md`。不可编辑任何 Task 1 文件、测试脚手架、主题、依赖或其他页面。

#### Constraints

公共契约和 Global Constraints 均绑定。新组件使用已有 ExternalPlayer 类型，接受 loadPlayers/savePlayer 回调及 selectedPath，返回 executable 或 null，不负责启动程序。

同名显示编号 #1/#2；编号是显示值而不是可编辑名称。行内展示基础名称、完整路径及编辑按钮，长列表滚动。新增/编辑姓名、路径表单可取消或保存；保存失败留在编辑状态并显示问题，成功重新加载实际列表。路径无效不能外调。

PlayerPage 继续每次打开该组件；只在确认使用后写上次路径并启动。不要把保存编辑等同于立即外调。保持取消无外调、成功才暂停内置播放。控制器由 widget State 生命周期管理，或明确等待路由退出，避免退场动画访问已释放控制器。

保持现有中文、tokens、无阴影、键盘可达；不改顶栏常驻 tooltip 或其它控制栏行为。已有 Impeccable context 已在本会话加载；请直接读 PRODUCT.md、DESIGN.md 及关联 surface/craft-floor，不运行会重写设计上下文的命令。

#### Limits

- 实现尝试：单位为协调者派发的运行，本任务最多 3 次，首次与重派累计，不按工具或测试次数重置。
- 实现与测试文件：单位为唯一文件，最多 4 个，跨本任务所有运行累计，仅限 Boundary 清单。
- 报告文件：单位为唯一 Markdown 文件，最多 1 个，跨运行累计，后续追加同一报告。
- 命令运行：单位为命令，数量不限；不存在每轮命令配额或可累积余额。
- 自检测试循环：单位为测试运行，数量不限；不占协调者重派次数。
- 单次输出：单位为行，最多 80 行，每次命令独立重置。
- 视觉检查：单位为批次，最多 2 次，跨整个任务累计；每批同时覆盖 1024×640、1440×900，不按缺陷或重派重置。
- 临时诊断产物：单位为文件，最多 4 个，仅在本计划 workspace，结束清理；截图可留在报告旁作证据。
- 子代理：单位为子代理，最多 0 个；评审由协调者执行。

#### Acceptance Criteria

1. 同名不同路径显示两条以上且编号可辨；路径与编辑入口可见。
2. 新增和编辑两字段后列表实际更新，再打开能保留；编号不会写入编辑字段。
3. 取消编辑不保存草稿；取消选择返回 null、不改上次选择、不启动任何程序。
4. 保存失败或非法路径不能假成功、不能自动关闭编辑器或启动。
5. 已配置路径仍每次选择，支持本次换播放器，下次只是预选。
6. 控件生命周期无 disposed controller 异常，两种 Windows 尺寸操作可达。
7. 独立组件测试先不依赖 Task 1；集成时仅消费精确 API，不自行创建数据替代物。自检测试和 analyze 通过。

#### Required Evidence to Report

变更文件、失败/通过测试命令与实际结果、列表/编辑/取消/保存失败覆盖、两种尺寸的检查证据、与 Task 1 的集成状态、未验证项。只向协调者返回状态、报告路径及简短结论。

#### Steps

- [ ] 独立组件回归使用两条同名 ExternalPlayer 和临时 exe 文件，要求界面显示 PotPlayer #1/#2；点编辑看到原名称而不是 #1。

```dart
const players = [
  ExternalPlayer(name: 'PotPlayer', executable: r'D:\P1\PotPlayerMini64.exe'),
  ExternalPlayer(name: 'PotPlayer', executable: r'D:\P2\PotPlayerMini64.exe'),
];
expect(find.text('PotPlayer #1'), findsOneWidget);
expect(find.text('PotPlayer #2'), findsOneWidget);
```

- [ ] 编写可执行界面测试：新增临时第三个程序并保存后行出现；编辑名称/路径保存后显示新值；取消草稿保持原值；返回 false 的保存留在编辑器；外调取消返回 null。
- [ ] 抽出单独选择组件并实现列表/编辑状态，不复制扫描或持久化模型。
- [ ] 将 PlayerPage 接到公共 AppState 回调，更新已有重复选择和取消回归，确认无控制器退场问题。
- [ ] 在两种尺寸一批检查，修复该批发现项后至多一批复核；跑组件和集成测试及 analyze，写报告，不提交 Git。

### Task 3: 协调者独立验收

- [ ] 按本任务开始前快照审查每个模块实际差异与报告，分别给出需求符合性和质量结论。
- [ ] 缺陷回派原任务，读取 todo 中运行次数，最多首次加两次重派；不直接代修。
- [ ] 对合并接口、旧配置、自定义覆盖、多版本显示、取消语义逐条独立核对。
- [ ] 运行目录/持久化/选择框/既有按钮相关测试与 analyze，然后构建 Windows Debug。
- [ ] 最终广域审查仅覆盖本次功能增量和跨任务接口，不将历史未提交改动包装成本轮成果。
- [ ] 交付构建路径、测试证据、已处理风险和明确未完成项；不替换 beta，不宣称解决 PotPlayer 实播故障。
