# 14 · 导航栏缩略图与关键帧跳转

- 规格：`docs/reference/potplayer-checklist.md` P2-12；实施任务书：`docs/phase9/design/12-player-navigation-plan.md`。
- 状态：缩略图预览、设置、快捷键与 **MP4** 关键帧跳转已验证通过；**MKV/AVI 关键帧跳转仍未闭环**（见 §已知限制）。原生侧无法在现有接口内原子选择 seek 路径，该缺陷如实保留、未冒充修复。
- 边界：沿用 media-kit/libmpv 与现有播放器设计；无新增依赖、无外部 ffmpeg 运行时要求。测试视频由开发环境 ffmpeg/ffprobe 生成，不属于产品依赖。

## 使用

- 点播、时长已知时，`Ctrl+Shift+←/→` 跳到前一个/后一个关键帧；右键 → 播放分组提供同名入口。普通 `←/→` 仍后退/前进 10 秒。
- 设置 → 播放参数 →「导航栏缩略图」，或右键播放分组中的同名开关。**默认关闭**，开启可能增加网络请求。
- 开启后，鼠标悬停或拖动进度条会显示目标时间附近的关键帧预览；不是任意毫秒精确截图。加载/失败有短反馈，不等待图片才执行 seek。
- 直播（即使引擎报告非零时长）与未知时长禁用关键帧导航和预览请求。
- 开关保存在 `settings.json` 顶层 `player.showThumbnailPreview`，旧/脏配置回落 false；修改缓存、双击等其他播放参数不会丢掉该值。

## 实现与约束

| 模块 | 文件（相对 apps/desktop-flutter/lib） | 约束 |
|---|---|---|
| 导航 | `ui/player_controller.dart` | `relative+keyframes`（`±0.0001` 秒）；检查 native 返回码并等待实际位置；跳转未真的移动位置时返回 false，页面给 3 秒「关键帧跳转不可用」提示（fail-closed，不静默）；换源后旧导航不发命令/不通知旧 onSeek；播放/暂停状态不变 |
| 预览服务 | `services/player_thumbnail_service.dart` | 独立静音 Player+VideoController，320×180；禁音轨/字幕；默认零创建；不可变 Header 快照 |
| 请求调度 | 同上 | 最多一项执行和一项合并后的最新等待请求；至多32张LRU；每个请求提交起最多5秒，包括排队；失效/关闭/销毁取消旧结果；旧引擎完全释放前不启动新引擎 |
| 进度条 | `ui/player_overlay.dart` | 200ms防抖，OverlayPortal+IgnorePointer；目标取实际Slider trackRect；不增高32px进度行、不阻塞onSeek；退出/禁用/换源/dispose忽略晚到图片 |
| 偏好/接线 | `core/player_options.dart`、`ui/player_page.dart`、`ui/app.dart`、`ui/settings_detail_pages.dart` | 沿用现有落盘/主题/右键分组；新快捷键可选，不抢普通箭头；未增顶栏溢出菜单项 |

## 审查发现与闭环

1. 小于底层时间粒度的偏移在精确关键帧处 no-op：真实 libmpv 探针由 `±0.000001` 调整为 `±0.0001`，双向 GOP 序列验证。
2. mpv 命令完成早于实际位置更新：导航等待实际位置且逐个 await 后检查 generation，避免发布旧/换源后的 onSeek。
3. 初次提取仍在进行时最新悬停请求曾被丢弃：RED 实际返回 null；改为单项 latest coalescing，冷启动 A→最后B 无需再次悬停也能返回B。
4. Header/首帧就绪：固定纹理尺寸不等于媒体已加载；主/预览冻结 Header，预览等待可seek的视频元数据，真实鉴权及同URL新Header验证。
5. 控制栏隐藏可能遗留portal：真实页面回归证实隐藏后的hit-test变化触发MouseRegion退出，图片收起，跨5秒预算后也不复现。
6. 原截图夹具未统一字体：默认时间宽61.25（Ahem方块）被回归捕获；统一CJK/monospace及固定AppBar字体后重拍。Before由 `aac86ce` 原始overlay重建，只调整测试导入路径，当前checkout/HEAD未回退。
7. 仅检查seek状态可能早于seek启动的截图风险：同session连续40次交替/同GOP抽取，与冻结6s/2s原始JPEG逐字节一致，当前Linux/mpv v0.40.0下未复现；不外推为所有平台证明。

## 已知限制（未闭环，不要当成已修）

**MKV / AVI 的关键帧跳转目前在未缓存路径下无效。** 复现与定性（Linux，mpv v0.40.0，同一已记录 libmpv）：

| 场景 | 观测 |
| --- | --- |
| 未缓存 MKV / AVI | 命令 rc=0，但位置不动：`2.72→2→2→2→2→2` |
| 原因 | mpv v0.40.0 `demux_mkv.c:3481-3483` 对 seek 目标施加 forward −5ms / backward +5ms 方向容差，把 `±0.0001` 量成 no-op |
| 静态放大偏移 | `±0.01` 会跳过 120fps 全关键帧 MP4 的紧邻帧（`.400→.416667`，应 `.408333`）；统一 `+5ms` 会跳过已缓存 240fps MKV 的紧邻帧 |
| 缓存路径差异 | `cache=yes` 时走 `demux.c` 的 cache range 查找，不经过该 5ms 补偿，因此同一偏移在缓存命中时反而「看起来正常」——这正是它容易被误判成已修的原因 |
| 为什么本轮不修 | 现有 `NativePlayer` 接口只能取到释放锁后的 cache 状态快照，而真正的 range 选择在 demux 锁内、seek 延迟队列执行；没有原子接口把「分类」与「执行」绑定。用全局 cache 开关强制路径会改变用户播放选项；按帧率拒绝会偷偷改变支持范围。两者都未获产品确认 |

当前行为是 **fail-closed**：控制器检测到位置没有真的移动就返回 false，页面显示 3 秒「关键帧跳转不可用」，不会静默假装跳了。`integration_test/player_navigation_engine_flow_test.dart:377` 的多容器门禁用 `skip` 保留了这个已复现缺陷（不是被删除，也不假装通过）；修复原生策略后删掉 `skip` 即恢复门禁。

需要产品决定才能继续：(a) 接受「MP4 可用、MKV/AVI 不可用」并明确标注；(b) 投入原生层原子 seek 策略；(c) 在所有格式上关闭关键帧，只保留缩略图。

## 视觉证据

目录：`screenshots/player-navigation/`。

- 正常字体、同场景/暗色/视口：`before-default-1280x720.png` ↔ `after-default-1280x720.png`；`before-default-640x360.png` ↔ `after-default-640x360.png`，两对逐字节一致。
- 开启后：`after-preview-image-*.png`、`after-preview-error-640x360.png`；预览卡192×136，32px进度行保持，加载/成功/失败同尺寸。
- 设置：`settings-after.png`，新增项为additive，给After-only；所有文字/图标字体已核验。
- 真实关键帧：`keyframe-6s.jpg`、`keyframe-2s.jpg`，烧录时间码及frame150/frame50，不是主播放器截图复用。

## 原生证据与复验范围

子任务自验证：Linux，mpv v0.40.0；12秒25fps视频、50帧GOP，关键帧0/2/4/6/8/10秒。暂停态导航 `2.72→2→4→6→4→2→0`；播放态保持播放。JPEG 320×180、43153B，主播放器4秒/暂停状态未改变；真实Header鉴权16次、拒绝0次；预览2创建/2释放。

## Lead 独立验收（Linux，cwd `apps/desktop-flutter`）

```
flutter test --no-pub --concurrency=1 <19 个风险套件>   → 324 passed, exit 0
flutter analyze --no-pub <15 个改动文件>                → No issues found, exit 0
dart format --output=none --set-exit-if-changed <同上>  → 0 changed, exit 0
flutter test --no-pub -d linux integration_test/player_navigation_engine_flow_test.dart
                                                        → 3 passed, 1 skipped（即上面的已知缺陷）
```

19 个套件覆盖导航新增行为与播放器既有风险面：双击配置、长按倍速、直播控制、样式落盘、偏好存储、浮层布局/命中测试、缓冲段、播放页浮层、全屏。

没有声明 Windows/macOS 已实机通过。用户已另行要求提交、推送并向 `beta` 发起中文 PR；本次按部分实现创建 Draft PR，不自动合并。已修复的本地构建输入仅为gitignored offline Python bundle，复用既有产物并按当前lock校验，无CMake修改/下载。
