# 本地源启用开关与批量操作 实施任务书

**Goal:** 本地源页的四类源（Python / JavaScript / 本地 HTML / 在线 HTML）都能启用、停用；
并提供多选批量启用、批量停用、批量删除。
**Architecture:** 启停状态按源类型落到各自的既有持久层——HTML 源沿用 `webhome/registry.json` 的
`enabled`，本地 py/js 源新增 `<configDir>/local_sources.json` 的 `disabled` 集合（默认启用，
只记停用）。`AppState` 暴露**一套**启停 API，页面不需要知道两种存储的差异。
**Tech Stack:** Dart / Flutter（不新增依赖）。

## 已确认的设计记录（本文件同时为本轮 spec）
- 停用语义 = **从站点列表隐藏 + 立即停止该源运行中的 sidecar**；再启用即恢复可选。
- 批量交互 = **进入多选模式 + 顶部批量条**（与历史页「批量删除」同形态）；删除有二次确认。
- 改动范围只在本地源页（`LocalSourcesPage`）；Spider 运行时页保持只读展示。
- 不提交 git，不写用户真实配置目录，不新增依赖。

## 根因证据
- `lib/ui/local_sources_page.dart:296-310`：py/js 行只有删除按钮，没有开关；HTML 行有开关。
- `lib/state/app_state.dart:6875` `webHomeSources` 直接读登记表，py/js 侧没有任何启用状态。
- `lib/state/local_site_sources.dart:66-78`：站点条目无「停用」概念，py/js 一律进列表。
- `lib/state/app_state.dart:2241-2248`：唯一的本地源失效入口，启停后必须走它。
- `lib/ui/local_sources_page.dart:470-500`：候选区已有全选/计数/排序，已导入区没有多选。

## 全局约束
- 停用必须**真的**停掉运行中的 sidecar（`stopSpider`），不能只隐藏 UI。
- 同一 key 的停用状态与「同 key 冲突拒绝」无关：冲突仍是保留既有站点并跳过。
- 批量操作必须逐 key 报告成败，不能把部分失败写成整体成功。
- 删除仍沿用既有安全边界（只删 `local/<key>`、运行中拒绝、符号链接拒绝）。

## 任务 A：启用状态持久层 + AppState 接缝（Lead 执行）
Boundary: `lib/services/local_source_enable_store.dart`（新增）、`lib/state/app_state.dart`、
`lib/state/local_site_sources.dart`；专属 `test/local_source_enable_test.dart`。
Interfaces:
```dart
class LocalSourceEnableStore {
  LocalSourceEnableStore({required this.path, LogService? log});
  Set<String> get disabledKeys;
  bool isEnabled(String key);
  bool setEnabled(String key, bool enabled);   // 写盘，失败返回 false
  bool forget(String key);                     // 删除源时清残留
}
// AppState
bool localSourceEnabled(String key);
Future<bool> setLocalSourceEnabled(String key, bool enabled);
Future<LocalSourceEnabledOutcome> setLocalSourcesEnabled(Iterable<String> keys, bool enabled);
```
- [ ] 停用 py/js 立即从 `localSourceSites` / `effectiveConfig` 消失；再启用恢复。
- [ ] 停用运行中的本地源会 `stopSpider`；启用不自动启动。
- [ ] 停用不影响 HTML 源的既有 `enabled` 语义（两套存储各自不变）。

## 任务 B：本地源页多选批量条 + 每行开关（子代理执行）
Boundary: `lib/ui/local_sources_page.dart`；专属 `test/local_sources_page_test.dart`。
Consumes: A 的 `localSourceEnabled` / `setLocalSourceEnabled` / `setLocalSourcesEnabled`。
- [ ] py/js 行有开关；四类源行都有开关，状态取自 AppState。
- [ ] 「批量管理」进入多选态：行前复选框、全选/取消全选、已选计数。
- [ ] 批量条：批量启用 / 批量停用 / 批量删除（确认框），逐 key 成败可见。
- [ ] 忙碌时禁用批量动作；窄窗不溢出；错误如实显示。

## 任务 C：视觉对照（Lead 执行）
Boundary: `tool/local_sources_capture_test.dart`（新增）。
- [ ] 改前基线（`before`）与改后（`after`）同一场景、同一视口、同一主题。
- [ ] 批量态单独出一张 after 截图。

## 交付记录（执行后追加）
- 启停状态：py/js 落 `<configDir>/local_sources.json`（只记停用，原子写、读坏不写回）；
  HTML 沿用 `webhome/registry.json` 的 `enabled`，两者由 `AppState.localSourceEnabled` 统一。
- 停用同时隐藏站点、停止该源全部站点别名（含握手中的进程）；启用不自动拉起运行时。
- 运行时入口新增门禁：源停用后 `ensureRunning` 直接拒绝，避免隐藏列表但进程复活。
- 页面：py/js 行开关 `local-toggle-<key>`；批量管理 `local-sources-batch` 进入多选态，
  批量条含全选/计数/启用/停用/删除（二次确认）/退出。
- 视觉证据：`.local/local-sources-visual/{before,after}`（同视口 1000×1100、暗/亮各一张，
  after 另含批量态）。
- 测试：`test/local_source_enable_test.dart`（15）+ `test/local_sources_page_test.dart`（34）。

## 完成标准
- 四类源都能启用、停用；停用即隐藏且停掉运行时；再启用恢复可选。
- 批量启用/停用/删除可用且有二次确认；失败逐条可见。
- `flutter analyze` 无新增问题；相关测试全绿（含既有 local_sources_* 用例）。
- 改前/改后截图对照留存。
