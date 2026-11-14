# 00 · 差距分析交付证据（Phase 9 文档阶段）

- 日期：2026-10-21
- PC 基线：`81c398c`（工作区另有未提交的横向拖动改动，与本阶段无关）
- 安卓基线：`F:/Workspace/webtv2/webhtv` @ `77e2fbefdc30`（2026-10-20）
- 门禁输出：`docs/phase9/evidence/gap-matrix-gate.txt`（退出码 0，G9.1–G9.5 全绿）

## 1. 清点结果

| 类别 | 数量 | 来源 | 未映射 |
| --- | ---: | --- | ---: |
| manifest 屏幕（Activity） | 43 | 四个 `AndroidManifest.xml` 的 `<activity>` | 0 |
| 对话框 | 84 | `app/src/main/java/.../ui/dialog/*.java` | 0 |
| 设置 Fragment | 9 | `app/src/*/java/**/ui/fragment/Setting*Fragment.java` | 0 |
| 顶层模块 | 34 | `app/src/main/java/com/fongmi/android/tv/*/` | 0 |

映射见 `docs/phase9/design/05-upstream-map.md`。

## 2. 缺口结论

| 档 | 数量 | 内容 |
| --- | ---: | --- |
| P0 | 8 | 轨道选择、片头片尾、循环/定时、播放参数、LUT、字幕源、弹幕库、直播回看 |
| P1 | 10 | 广告过滤、站点注入、健康排序、接口失败切换、分组规则、CSP 预热、直连 js/py、网盘检测、出站代理、AI 扩展 |
| P2 | 9 | 追番、观影报告、短剧、一键同步扩展、登录态、Webhook、更新/备份/重置、DoH/隐身/恢复、文件浏览 |
| P3 | 7 | WebHome、听书/TTS、小说漫画、GitCloud、管理页、远程托管、DLNA/遥控 |
| 不迁移 | 8 | dex 站源、Exo/IJK 内核、TV/手势、Android 系统集成、Lab、游戏模式、品牌页、内置内容 |

矩阵（含每项方案与验收）见 `docs/phase9/README.md` §4–§5。

## 3. 已核实的关键事实（抽样）

- `player_buttons.dart` 明确排除 27 个无实现的按钮，其中包含 `text/audio/video`、`opening/ending`、
  `repeat/timer`、`lut`、`cast`；`player_controller.dart` 只有字幕轨选择，音轨/视频轨是只读诊断。
- `storage.dart` 的 `openingMs`/`endingMs` 接收但不入库（注释明示）。
- `protocol.dart` 解析 `ads`/`hlsRules`/`doh`，但没有消费点（`ads` 仅字段与序列化）。
- `source_field.dart` 用健康度排序站点选择器；`app_state.dart` 的搜索结果按配置顺序稳定排序。
- `parse_runtime.select` 单次选择，`parse_service.dart` 无跨接口 failover。
- `android_sync.dart` 的 `pcSettingsWhitelist` 只有 6 个键，`pcUnsupportedSettingsKeys` 明示
  `tmdb_model`/`ai_title_extraction`/`ai_ad_detection` 不支持。
- `config_pages.dart` 的「选择本地文件」是文本路径对话框，没有原生文件选择器。
- `pubspec.yaml` 无 WebView 依赖；`parse_runtime.dart` 注明 type=0 Web 嗅探不支持。

## 4. 本阶段未验证的内容（已知局限）

- 真实站点/字幕源/弹幕库/直播源的可达性：只承诺 fixture 可复现，真实样本需用户配置，
  按 `design/04` §5 记录脱敏四要素。
- 安卓侧 `webtv2` 之外的变体（`webtv3`/`webtv4`）：本阶段以用户指定仓库为准，
  三者的功能目录一致性已抽查（`web/server/following/lab/tts/remote/dlna/gitcloud` 均存在）。
- 第三方依赖（WebView2、Windows 通知/SMTC、TTS）的可用性：属 W4，需 ADR 后再评估。

## 5. 复现

```powershell
py -3 tools/phase9/verify_gap_matrix.py
# 输出应为 PASSED · G9.1–G9.5 全绿，退出码 0
```
