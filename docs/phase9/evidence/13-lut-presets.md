# 13 · LUT 内置预设与在线导入

- 日期：2026-11-16
- 触发：对齐安卓版的内置 LUT；并补上在线获取
- 相关规格：`docs/phase9/design/01-player-closure.md` §6（P0-5 LUT）、`DESIGN.md` §画面菜单

## 1. 目标与边界

**做**：

- 内置 13 个 3D .cube，效果与命名对齐安卓 `app/src/main/assets/lut_presets/`；
- 把「手打路径」的入口换成列表式选择面板：内置 / 我的 / 在线；
- 支持导入本地 .cube、删除用户预设；
- 在线：任意 http(s) 直链下载，以及经 GitHub 公开 API 搜索仓库内的 .cube。

**不做**：

- 不做 LUT 强度混合（`mix/`）、不做 `interp` 参数、不做 1D LUT / .3dl / .m3d。
  理由见 §2：`vf` 白名单只认一种形态，改它是改安全边界，不是加功能；
- 不做「应用前后对比预览」：需要截图差分，属于另一条验收链；
- 不做星标/收藏：安卓有，但桌面端目前没有「收藏」这一层数据模型，先按使用频率收敛。

## 2. 为什么内置 LUT 必须先落盘

mpv 侧只接受真实文件路径：

    lavfi=[lut3d=file='<路径>']

Flutter asset 在运行时不保证是一个可直接打开的绝对路径（打包形态随平台而变），
所以 `LutStore.materialize` 负责把 asset 字节写进 `cacheDir/lut/<id>.cube` 再返回路径。
两条约束：

1. **幂等**：已存在且字节数相同就直接复用，切换预设不会反复写 1 MB；
2. **先写 .tmp 再 rename**：中途失败不会留下半截 .cube 被下次误当成可用文件。

为什么不能顺手加 `interp`：`core/mpv_properties.dart` 的 `vf` 白名单把形态钉死成
`^lavfi=\[lut3d=file='(?:[^'\\]|\\.)*'\]$`。实测「引号外多一个逗号就能挂上第二个滤镜
（`movie=` 能读本地文件）」，所以放宽形态等于开一条命令注入的口子。这也直接决定了
「强度混合」「对比预览」本轮做不了——不是没时间，是不能这么做。

## 3. 实现

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 资源 | `apps/desktop-flutter/assets/lut/*.cube`（新，13 个，10,832,768 B） | 从安卓 assets 拷入，文件名转 ASCII、显示名保留中文 |
| 注册 | `pubspec.yaml` | `assets: - assets/lut/` |
| 目录模型 | `lib/core/lut.dart` | `builtinLutPresets`（13 项：id / 资源键 / 中文名 / 尺寸）、`LutSource`、`findBuiltinLut`、`parseCube` 增加 `id` 与 `source` 入参 |
| 仓库 | `lib/services/lut_store.dart`（新） | 内置落盘、用户目录扫描、导入、删除、直链下载、GitHub 搜索/列文件/下载；失败统一 ` LutStoreException + code |
| 播放参数 | `lib/core/player_options.dart` | 新增 ` lutPresetId`（不参与注入，只记「选的是哪一档」） |
| 选择面板 | `lib/ui/lut_picker_sheet.dart`（新） | 三段式：内置 / 我的（导入、删除）/ 在线（关键词搜索、从链接导入） |
| 播放页 | `lib/ui/player_page.dart` | `_showLutSettings` 改为打开面板；`_applyLutPreset` 负责落盘 + 注入 + 持久化；启动注入时按 id 重新落盘 |

### 3.1 为什么 ` lutPath 仍是播放真相

`PlayerOptions` 原本只有 ` lutPath`。新增的 ` lutPresetId` **只用于选择态展示**：

- 旧配置没有 ` lutPresetId` → 解析为 `''`，行为与改动前完全一致（不迁移、不丢设置）；
- 播放注入只看 ` lutPath`，白名单校验链一行没动；
- 但缓存目录随时可能被系统或清理功能删掉，所以启动注入时若 ` lutPresetId` 命中内置项，
  会先重新 materialize 一次再把新路径写回配置——只用 ` lutPath` 会在缓存被清后静默失效。

## 4. 在线部分为什么选 GitHub 公开 API

| 方案 | 结论 |
| --- | --- |
| 自建 catalog JSON | 需要托管；仓库当前没有发布静态资源的通道，先不做 |
| 网页搜索 / 爬取 | 结果非结构化，站点一改就坏 |
| GitHub 公开 API（采用） | 无需 token；结构化的仓库搜索 + tree 接口能精确列出 .cube；raw 链接直取文件 |

代价与应对：

- 未授权额度 60 次/小时 → 结果按 star 排序、只取前 8 个仓库、单仓库最多列 120 个 .cube；
- 403/429 被翻译成「已限流，请稍后再试或改用从链接导入」，不自动重试（重试只会更快烧额度）；
- 下载前用 Content-Length 拦一次 8 MiB 上限，读入后再按实际字节拦一次；
- 所有下载/导入都**先过 parseCube 再落盘**，非法文件不会出现在列表里。

## 5. 验收

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 静态分析 | `flutter analyze`（5 个改动/新增 lib 文件 + 3 个新测试） | No issues found |
| 目录与解析 | `flutter test test/lut_catalog_test.dart` | 12 例通过（含「13 个资源都能被 parseCube 解析」「尺寸与目录一致」） |
| 仓库层 | `flutter test test/lut_store_test.dart` | 16 例通过（落盘幂等、缺资源不写空文件、导入去重、非法拒收、8 MiB 上限、403 归一、tree 过滤） |
| 面板 | `flutter test test/lut_picker_sheet_test.dart` | 4 例通过（列出 13 项并标当前项、选中回传、清除回传、搜索→列 .cube） |
| 资源可用性 | 同上 | 测试直接走 rootBundle 读 `assets/lut/utopia.cube`，证明 pubspec 注册生效 |

**未做**：真机播放验证（应用内切 LUT 后截图比对像素差）。
这一步需要 Linux/Windows 桌面实例 + 真实视频，本轮没有完成；
所以在 §1 承诺的「切换后画面确实变了」目前只有单元/组件级证据，没有像素级证据。
