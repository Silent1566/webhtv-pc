# 本地源站点接入与在线 HTML 实施任务书

**Goal:** 修复本地多选导入后站点选择器看不到源的问题，补在线 HTML、全选和修改时间。
**Architecture:** 爬虫注册表与 HTML 登记表仍分离；AppState 将本地爬虫合并到有效配置，HTML 作为打开网页的站点入口而非爬虫协议。保存的原始配置不变。
**Tech Stack:** Dart / Flutter / Windows WebView2。

## 已确认的设计记录（本文件同时为本轮 spec）
- 用户选择在线 HTML 保存原网址、打开时加载；本地 HTML 沿用虚拟主机映射。
- Python/JS 导入后进入统一站点列表；HTML 在列表点击打开页面，不标记为可统一搜索。
- 扫描结果支持全选/取消全选、修改时间、最新优先排序；不自动覆盖重复 key。
- 完成标准：导入即出现、重启不丢、启停删除同步、原配置不被污染、错误如实可见。

## 根因证据
- app_state.dart:1361-1365 effectiveConfig 只合并 JSON 注入，不包含源注册表。
- app_state.dart:5535-5545 导入后仅 notifyListeners，无站点装配。
- app.dart:857 选择器读取 siteItems。
- spider_registry.dart:63-74 扫描只看根目录首层，本地源位于 local/<key>/。

## 全局约束
- 保留所有已有未提交改动；不提交 git，不添加依赖，不修改用户实际配置目录。
- 扫描、登记在线地址不执行源代码，不联网下载；运行只发生在显式打开或使用时。
- 网络源仅接受有效 http(s) 地址；添加失败不能误报成功。
- 遵循 DESIGN.md、PRODUCT.md 和现有设置页 tokens，不重做整体界面。

## 任务 A：HTML 登记与文件元数据（运行 1/3）
Boundary: lib/services/web_home_store.dart、lib/services/local_source_import.dart、lib/ui/web_home_page.dart；专属 test/online_web_home_test.dart。
Interfaces:
```dart
// WebHomeSource 新增可选字符串属性，旧数据兼容空字符串。
final String remoteUrl;
final String modifiedAt;
bool get isRemote;
// WebHomeStore 同步登记，重复 URL / 不合法 URL 明确抛异常。
WebHomeSource addRemote(String url, {String? name});
```
- [ ] 写线上登记/旧记录/时间保持/重复和非法 URL 的失败测试并运行。
- [ ] 持久化 remoteUrl、modifiedAt；本地导入保存 candidate.modified。
- [ ] WebHomePage 在线分支加载原 URL，离线分支保留映射；桥注入顺序不退化。
- [ ] 专属测试通过并报告 red/green 证据。

## 任务 B：站点融合、重启恢复和打开动作（运行 1/3）
Boundary: lib/state/app_state.dart、lib/services/spider_registry.dart、lib/ui/app.dart；必要局部 helper；专属 test/local_source_sites_test.dart。
Interfaces:
```dart
Future<WebHomeSource> addOnlineWebHome(String url, {String? name});
```
Consumes: A 的 WebHomeStore.addRemote / WebHomeSource.isRemote。
- [ ] 为导入即显示、重启恢复、无配置可选、HTML 非搜索、同 key 不覆盖写失败测试并运行。
- [ ] 有限扫描 local/<key>/，保留旧根级 manifest，重复处理不静默覆盖。
- [ ] 本地爬虫进入 effectiveConfig；HTML 进入 siteItems，选择器点击走 WebHomePage。
- [ ] 导入、刷新、启动、启停和删除的配置缓存与路由装配保持一致。
- [ ] 检查 JSON 注入/远端直连回归并报告证据。

## 任务 C：管理页交互（运行 1/3）
Boundary: lib/ui/local_sources_page.dart；必要专属 UI helper；专属 test/local_sources_page_test.dart。
Consumes: B 的 addOnlineWebHome；A 的 remoteUrl/modifiedAt/isRemote。
- [ ] 用 widget 测试复现缺全选/时间/在线地址入口并运行。
- [ ] 增加全选/取消全选、选择计数、修改时间与最新优先排序。
- [ ] 在线 URL 与可选名称输入，调用 AppState 接缝，错误反馈；忙碌时禁用重复动作。
- [ ] 本地时间未知显示未知，不把导入时间冒充文件修改时间；在线更新时间未知明确显示。
- [ ] widget 测试通过，检查窄窗无溢出并报告证据。

## 审核记录
- A 首次与第一次返工：独立复跑 HTML/本地源 69/69 通过，但只读审查 Spec/Quality 不合格。
- A 最后返工（运行3/3）：F1–F5 范围限定复审均 ADDRESSED，独立复跑 88/88 通过；用户明确确认本轮新增本地导入 Windows-only。
- B 首次执行（运行1/3）：站点融合与启动恢复测试交付，独立规格/质量审查中。
- C 原执行者后台续接两次异常，新执行者承接最后运行3/3，核对静态调用、平台说明及操作失败反馈。
- 联合定向回归独立运行 201/201 通过；全量分析、Windows debug 构建继续验收。
- B 保持现有 mergeInjectedSites 的配置/JSON 注入同 key 覆盖语义，仅本地源低于既有有效结果；不改旧合并逻辑。
- C 接缝明确：扫描候选已有 DateTime modified，仅需展示；A 的字段与 addRemote 已可消费。

## 任务级兜底记录
- B/C 到第3次执行仍终审不合格，触发R8仅针对当前任务的直接修复许可，不延续到下次任务。
- 最终四项：本地-only门禁和启动服务；只读资源预检；HTML默认/显式首页守卫；路径回车重入与同key导入期间占用。
- 新增 test/local_source_boundary_test.dart 六项先真实RED，再最小修复GREEN；不写回合成配置，不新增依赖，不提交git。
- 删除只读资源时安全拒绝，不自动更改用户文件属性；已知风险已路由返工，不带缺陷交付。
- 最终限定复审：四项 ADDRESSED，Spec/Quality 合格；扩展定向回归 235/235，全量 flutter analyze 无问题，Windows debug 构建成功。
- 交付边界：未做真实GUI/示例网址公网内容端到端验证；HTML仍为网页宿主，不参与统一搜索；源码未提交git。

## 限额与审核
- 每个任务首次执行加最多两次返工，总计最多 3 次派发，累计不重置。
- A 最多编辑 4 个文件，B 最多 7 个文件，C 最多 4 个文件；各任务累计。
- 工具命令调用和测试运行次数不限；同种失败方案最多尝试 2 次累计，之后改用新证据支持的方式。
- 每周期无额外额度；不运行占位等待、轮询、sleep。
- 主协调独立查看关键差异，顺序运行专属测试+原有本地源/注入/直连回归，flutter analyze，Windows debug 构建。
- 任一发现的缺陷必须返工或交用户做范围决定，不以已知风险名义直接交付。
