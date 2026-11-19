# Windows 随包 libmpv：现状与替换评估

> 起因：音量归一（`af=dynaudnorm`）在 Windows 上**不可能生效**——随包 libmpv 没有编进任何
> ffmpeg 滤镜。本文记录现状取证、候选方案、实测数据与迁移步骤，供"要不要换内核依赖"决策。
> 评估日期 2026-11-19，基于 `beta` 分支 commit `0954d31`。

## 1. 现状：pin 的是谁的构建

| 项 | 值 |
| --- | --- |
| 上游仓库 | `media-kit/libmpv-win32-video-build`（media_kit 自建的 libmpv，**最后发布 2023-09-24**） |
| 归档 | `mpv-dev-x86_64-20230924-git-652a1dd.7z`（MD5 `a832ef24b3a6ff97cd2560b5b9d04cd8`） |
| 谁在拉取 | `media_kit_libs_windows_video/windows/CMakeLists.txt`（URL+MD5 硬编码）；本仓库 `scripts/prepare_windows_native_deps.ps1` 预缓存同一份文件，并通过 `windows/runner/native_deps_cache.cmake` 播种，避免插件 CMake 的无线超时下载 |
| 落盘 | `build/windows/x64/libmpv/libmpv-2.dll` → 构建后 `build/windows/x64/runner/Release/libmpv-2.dll` |
| DLL 版本 | `mpv v0.36.0-403-g652a1dd907` / FFmpeg **n6.0** |
| 体积 | 28.4 MB（压缩后 12.3 MB），SHA256 `d5f0694b08c124e785d858d00082f3e3b158dd9138bfc48c0382bf1eb443a5fc` |

`media_kit` / `media_kit_libs_windows_video` 已是最新版（1.2.6 / 1.0.11），**不存在"升依赖就能拿到新内核"的路径**。

### 1.1 为什么它没有滤镜（实测）

在真实 DLL 上打开一个 WAV、逐条设置 `af`/`vf` 并看 mpv 日志：

```
af=lavfi=[anull]        → AVFilterGraph: No such filter: 'anull' → Audio filter initialized failed!
af=lavfi=[null]         → AVFilterGraph: No such filter: 'null'  → 同上
af=lavfi=[volume=0.5]   → 同上
af=lavfi=[dynaudnorm]   → AVFilterGraph: No such filter: 'dynaudnorm' → 同上
af=scaletempo           → 正常（mpv 原生滤镜，不经 lavfi）
```

连 `anull`/`null` 都不存在，说明这份 DLL 的 **libavfilter 没编进滤镜表**（不是某个滤镜缺席）。
后果分两档：

- 裸名 `af=dynaudnorm` → `rc=-9` 被内核直接拒，什么都没改，播放照常（**安全的失败**，现状即此）；
- `af=lavfi=[dynaudnorm]` → 属性写入 `rc=0`、回读也"成功"，但建链时失败 → mpv 丢掉整条音轨（**静音**）。

所以 `lib/core/mpv_properties.dart` 里明确写了"不可改成 lavfi 形态"，并把平台事实作为单测断言。

## 2. 候选：shinchiro 的 mpv Windows 构建

`shinchiro/mpv-winbuild-cmake` 是 mpv 官方安装页推荐、社区长期使用的 Windows 构建源，**每日更新**，带完整 FFmpeg。

| 项 | 值 |
| --- | --- |
| 归档 | `mpv-dev-x86_64-20261111-git-bcde6b93cc.7z`（30.3 MB，tag `20261111` 不可变） |
| 归档 SHA256 | `273c079b11ea5575822f972756f4c9a71149a5c10130353abeb8586738938452` |
| DLL 版本 | `mpv v0.42.0-38-gbcde6b93c` / FFmpeg `N-128766-gcd4e96eb3` |
| DLL 体积 | **116.1 MB**（压缩后 46.4 MB），SHA256 `88504ee5560942a955405e99dfb5971368e4cf851321f36565bf2a667271db1b` |
| 体积影响 | Release zip 现在 103 MB → 预计 **约 137 MB**（+34 MB） |

### 2.1 换上去到底行不行（实测，非推测）

用 `MediaKit.ensureInitialized(libmpv: <候选 DLL>)` 加载候选 DLL，**不改任何 Dart 代码**：

```
mpv=v0.42.0-38-gbcde6b93c  ffmpeg=N-128766-gcd4e96eb3
基线（无 af）      current-ao=null  audio-out-params.format=s16
af=dynaudnorm      current-ao=null  audio-out-params.format=doublep   ← 滤镜真的进链了
                   readback=dynaudnorm
                   PlayerController.applyMpvProperties → true，rejected=[]
af=lavfi=[dynaudnorm]  同样生效（当前白名单按设计拒收，保持拒收）
```

`format` 从 `s16` 变成 `doublep`（dynaudnorm 的输出格式）是"滤镜确实挂上"的硬证据。

在这份内核上跑本仓库所有真实 `NativePlayer` 用例（9 个文件、89 个用例、1 skip）：
`All tests passed`，其中 `player_audio_normalization_native_test` 走的是 `afApplicable=true` 分支
（回读一致、重开保留、20 次连写收敛），说明**能力分支当初就是按"内核做得到"写的，换内核不需要改 Dart**。

**未实测**：LUT（`vf=lavfi=[lut3d=…]`）在同一内核上是否恢复。headless 下 `vo=null` 不建视频链，
探针拿不到证据（`current-vo` 恒为空）；从"完整 FFmpeg"推断应当一并恢复，但要按第 3 节门禁实测。

## 3. 迁移方案（推荐 A）

### 方案 A：换成完整 FFmpeg 的 libmpv（推荐）
- 步骤：新增 `scripts/prepare_libmpv_windows.ps1`（下载+校验 shinchiro 归档，解出 `libmpv-2.dll`）；
  `flutter build windows` 之后把该 DLL 覆盖到 `build/windows/x64/runner/Release/libmpv-2.dll`，
  并同步覆盖 `build/windows/x64/libmpv/libmpv-2.dll`（单测走 PATH，必须先命中它）；
  `package_windows.ps1` 对随包 DLL 校验 SHA256（照 `libLiteRt` 的既有做法）；
  两个 workflow 各加一步准备，并在单测步骤显式把候选目录放到 `PATH` 最前。
- 优点：零 Dart 改动；归一真的可用；LUT 大概率一并恢复；来源是社区标准构建，长期有更新。
- 代价：包体 +34 MB；mpv 0.36 → 0.42 六个 minor 的行为差（见风险）；第三方许可需要补记录。

### 方案 B：自建"只留需要滤镜"的 libmpv
用 msys2 在 CI 里按 `--enable-filter=dynaudnorm,lut3d,...` 自己编一份，体积可控（估 40–60 MB DLL）。
- 优点：体积与能力都可控；来源自己掌握。
- 代价：新增一条 Windows 原生构建流水线（工具链、缓存、失败面），维护成本远高于方案 A。

### 方案 C：维持现状
保持"能跑、如实提示未生效、音轨安全"，并在 UI 上说明 Windows 不支持音量归一。
- 代价：功能永远不可用；文档里那条"P1 已实现"必须改成"仅 Linux 生效"。

### 迁移验收门禁（任一方案都必须过）
1. 真实内核探针：`af=lavfi=[anull]` 能建链（证明滤镜表存在）、裸名 `af=dynaudnorm` 生效且 `audio-out-params.format` 变化。
2. 全量 `flutter test`（Windows + Linux）与新 DLL 一起跑绿（本次只跑了 9 个 NativePlayer 文件）。
3. 打包产物：`dist/*.zip` 里 `libmpv-2.dll` 的 SHA256 == 期望值；`scripts/smoke_windows.ps1` 启动烟测通过。
4. 人工回归清单：硬解/软解、LUT、音频直通、字幕（libass 版本变了）、OSD 文案、`demuxer-cache-state`（网速显示）、`video-params`（HDR 判定）、拖动/seek、倍速与音调。
5. 许可：随包补 `libmpv`/`FFmpeg` 许可与来源说明（当前只有 `data/audio_ai/LiteRT-LICENSE.txt` 一项第三方许可见 `NOTICES.Z`）。

## 4. 风险与未决项

| 风险 | 说明 / 缓解 |
| --- | --- |
| mpv 跨 6 个 minor | 0.36 → 0.42：`af`/`vf` 属性语义、`osd` 文案、缓存相关属性都可能变。门禁 2/4 就是为它设的 |
| media_kit 只面向 0.36 | media_kit 1.2.6 的绑定按 0.36 生成；0.42 上 89 个真实内核用例全过，但绑定里若有被移除的 API，只有跑不到的分支才会暴露 → 门禁 2 必须做过 |
| 包体 +34 MB | 若不可接受 → 方案 B；或考虑 `-v3`（AVX2）变体（体积相近，兼容性更差，不推荐） |
| 第三方构建可信度 | 归档按 SHA256 固定到不可变 tag；随包记录来源与许可；`package_windows.ps1` 校验随包 DLL 哈希 |
| LUT 是否恢复 | 未实测（headless 不建视频链）；门禁 1/4 覆盖 |
| Windows 音频直通与 `ao` 行为 | 0.42 的 audio-out 参数名/取值可能变（`audio-out-params` 已有断言，风险低但要回归） |

## 5. 本次取证方式（可复现）

- 候选归档：`curl -L https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261111/mpv-dev-x86_64-20261111-git-bcde6b93cc.7z`，
  `tar.exe -xf` 解出 `libmpv-2.dll`（bsdtar 支持 7z）。
- 加载候选：`WEBHTV_TEST_LIBMPV=<候选 libmpv-2.dll>`，并把候选目录放在 `PATH` 最前（本仓库单测已支持该环境变量）。
- 观察点：`mpv-version`/`ffmpeg-version`、`af` 回读、`current-ao`、`audio-out-params.format`、
  以及 mpv 日志里的 `No such filter` / `Audio filter initialized failed`。
