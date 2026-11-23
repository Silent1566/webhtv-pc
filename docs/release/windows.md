# Windows 构建与发布流水线

- 适用：WebHTV PC（`apps/desktop-flutter`，Windows x64，便携 zip）
- 工作流：`.github/workflows/desktop-ci.yml`（`build-windows` job）、`.github/workflows/desktop-release.yml`（`meta` → `build-windows` → `publish`）
- 打包器：`scripts/package_windows.ps1`；启动烟测：`scripts/smoke_windows.ps1`
- 设计依据：`docs/webhtv-pc-design.md` §20（构建与打包）、§22.5（发布门禁）

## 1. 流水线中的 Windows 部分

Windows 与 Linux 现在收敛在同一对工作流里，Windows 是其中一个 job：

| 工作流 | 触发 | 作用 | 产物 |
| --- | --- | --- | --- |
| Desktop CI（`build-windows`） | push `main` / `beta` / `dev*`、PR 到 `main`、手动 `workflow_dispatch` | `dart analyze` + `flutter test` + Release 构建 + 打包 + 烟测 | workflow artifact（7 天） |
| Desktop Release（`build-windows`；`publish`） | 手动 `workflow_dispatch` | 上述门禁 + 可选签名 + 打包 + 烟测，两个平台都成功后由 `publish` 统一发布 | Release 资产 + workflow artifact（30 天） |

CI 在 `main` / `beta` / `dev*` 推送、PR 到 `main` 与手动触发时运行；实际步骤与触发条件以工作流文件为准。`beta` 是集成分支，功能先进 beta 再进 main，所以它必须在合并前就拿到完整的双平台门禁结果。

本地开发仍用 puro：

```powershell
cd apps/desktop-flutter
puro -e webhtv -p . dart analyze
puro -e webhtv -p . flutter test
```

CI 不依赖 puro：固定 Flutter **3.47.5 stable**（与本地 `.metadata` revision 一致），并显式安装 JDK 21 / Node 22 / Python 3.12——单测会真实启动 JVM、Node、Python sidecar。

## 2. 发布输入

`Windows Release` 的输入与安卓仓库保持一致：

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `release_tag` | 空 | 空 = 按 commit 时间自动生成。stable：`v<versionName>-yyyyMMddHHmm`；beta：`v<versionName>-beta-yyyyMMddHHmm` |
| `release_channel` | `auto` | `auto`：`main` → stable，其它分支 → beta |
| `release_notes` | 空 | 支持字面 `\n` 换行；会追加未签名与运行环境说明 |
| `prerelease` | `false` | beta 通道强制预发布 |
| `publish_release` | `true` | `false` 只构建、打包并上传 workflow artifact，用于演练 |

版本号唯一来源是 `apps/desktop-flutter/pubspec.yaml` 的 `version:`（如 `0.1.0+1`）；tag 使用其中的 `versionName`，build 号写入 `release-info.json`。
tag 必须与通道匹配；已存在的 tag 只有在指向当前 commit 时才允许复用，否则流水线失败且不会移动 tag。

时间基准：commit 时间（`git show -s --format=%ct`）换算到 Asia/Shanghai（`China Standard Time`），因此同一 commit 重跑会得到同一个 tag。

## 3. 产物

Release 资产（同名文件重跑时覆盖）：

```
webhtv-pc-<version>[-beta]-windows-x64.zip
SHA256SUMS.txt
release-info.json
```

zip 解压即用（含顶层目录）：

```
WebHTV-PC-<version>[-beta]-windows-x64/
  webhtv_pc.exe
  *.dll
  data/...
  runtime/node/node.exe
  runtime/python/{python-runtime.zip,bundle.json}
  sidecars/spider-host-python/{host.py,webhtv_ipc.py,webhtv_catvod.py,base/}
  sidecars/spider-host-js/{host.js,sandbox_worker.js}
  sidecars/spider-host-jvm/host.jar
  BUILD_INFO.txt
  THIRD_PARTY.txt
```

说明：

- 随包带 sidecar 宿主、**Node 运行时**（`runtime/node/node.exe`）及**专用离线 Python 与依赖**（`runtime/python/python-runtime.zip`、`bundle.json`）；Python 环境页面支持检测与离线修复，无需安装系统 Python。JVM 站源仍需本机 JDK 17+。
- 不带站点源、用户配置、日志、测试 fixture；`sidecars/*/manifests`、`sidecars/*/spiders` 是测试 fixture，不入包。
- `THIRD_PARTY.txt` 列出主程序/动态库/sidecar 宿主的 SHA-256 与可获得的 FileVersion；第三方许可见 `data/flutter_assets/NOTICES.Z`。
- 用户数据仍在 `%APPDATA%\webhtv-pc` 与 `%LOCALAPPDATA%\webhtv-pc`，替换解压目录即完成升级。

`release-info.json` 是机器可读的发布事实（schema v1）：`version`/`build`/`channel`/`tag`/`commit`/`builtAt`/`platform`/`arch`/`flutter`/`signature`/`assets[]`/`runtimes`/`notes`。应用通过 GitHub Releases API 读取这些发布事实做更新检查（ADR-0015），`release-info.json` 仍只是构建侧产物。

## 4. 代码签名（可选）

配置以下 repository secrets 后，发布流水线会签名 `webhtv_pc.exe` 并用 `signtool verify /pa` 校验：

| 名称 | 类型 | 说明 |
| --- | --- | --- |
| `WINDOWS_CERT_PFX_BASE64` | secret | PFX 文件的 Base64 |
| `WINDOWS_CERT_PFX_PASSWORD` | secret | PFX 密码 |
| `WINDOWS_CERT_TIMESTAMP_URL` | variable（可选） | 时间戳服务，默认 `http://timestamp.digicert.com` |

未配置时流水线不失败，但会：

- 在 `BUILD_INFO.txt`、`release-info.json.signature.status` 标注未签名；
- 在 Release notes 追加「未签名包，SmartScreen 可能提示未知发布者」；
- 输出 `::warning`。

配置了凭据但签名/校验失败时流水线直接失败，不会静默退化成未签名包。

## 5. 启动烟测

`scripts/smoke_windows.ps1` 复用应用自带探针，不靠固定 sleep：

1. 解压 zip，校验 exe 同级存在三个 sidecar 宿主；
2. 以 `--screenshot-ready-file=<tmp>` 启动 exe；
3. 轮询 ready 文件（默认 30 秒），断言 `StartupInfo.oneLine` 同时包含：
   `WebHTV PC <版本>`、`platform=windows`、`player=media-kit`；
4. 无论成败 `taskkill /T /F` 回收进程树，失败时输出日志与 trace 尾部。

该步骤同时验证「包能启动」「sidecar 布局正确」「版本注入生效」。

## 6. 本地复现

```powershell
# 0. 先在仓库根目录一次性准备固定的原生依赖（libmpv/ANGLE/nuget/sqlite3 源码）。
#    插件 CMake 原本用不设超时的 file(DOWNLOAD)/FetchContent 拉这些，网络一卡
#    构建就停在 "Building Windows application..." 且没有任何输出。
./scripts/prepare_windows_native_deps.ps1

# 1. 构建（与 CI 相同的版本注入）
# 必须先 cd 进工程目录：puro 的 --dir / -p 都**不会**改 flutter 的工作目录，
# 只有 cd 真的会。实测 puro 1.5.0（Flutter 3.47.5）：
#   puro --dir apps/desktop-flutter -e webhtv flutter build windows --release
#     → Error: No pubspec.yaml file found.
#   puro -e webhtv -p apps/desktop-flutter flutter pub get
#     → Expected to find project root in current working directory.（exit 1）
# 因此下面这行 cd 是必需的，不要为了少一行把它换成 --dir/-p。
cd apps/desktop-flutter
puro -e webhtv flutter build windows --release --dart-define=APP_VERSION=0.1.0

# 构建前先确认没有同名进程正在运行：Release 产物被占用时 cmake install 会以
# `file INSTALL cannot copy file ... Permission denied` 失败（error MSB3073）。

# 2. 打包（正式版必须 -Channel stable；只有 beta/dev 才会在文件名里加后缀）
cd ../..
pwsh -File scripts/package_windows.ps1 `
  -BuildDir apps/desktop-flutter/build/windows/x64/runner/Release `
  -OutputDir dist `
  -Version 0.1.0 -BuildNumber 1 -Channel stable `
  -Commit (git rev-parse HEAD) -ShortCommit (git rev-parse --short=7 HEAD) `
  -FlutterVersion 3.47.5

# 3. 解压并烟测
$extract = Join-Path $env:TEMP ('webhtv-smoke-' + [guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath (Get-ChildItem dist/*.zip | Select-Object -First 1).FullName -DestinationPath $extract
$exe = Get-ChildItem $extract -Recurse -Filter webhtv_pc.exe | Select-Object -First 1
pwsh -File scripts/smoke_windows.ps1 -ExePath $exe.FullName -ExpectedVersion 0.1.0

# 4. 校验和
Get-FileHash (Get-ChildItem dist/*.zip | Select-Object -First 1).FullName -Algorithm SHA256
```

`dist/` 已在 `.gitignore` 中，不会污染工作区。

## 7. 已知限制与后续

- **无 MSI**：当前只发便携 zip。MSI 需要先确定签名通道、安装范围、覆盖升级/卸载语义（设计文档 §20.4），本轮不做。
- **在线更新（ADR-0015）**：应用内可手动检查更新、可开启启动时自动检查；下载必须通过发布侧 SHA-256 校验。Windows 便携包在退出后由 PowerShell 脚本整目录换装，旧目录保留为 <安装目录>.webhtv-old 供回滚；签名通道仍未配置，因此不做静默自动安装。
- **本指南仅覆盖 Windows x64**：仓库另有 Linux x86_64 平台工程与打包流程，见 [Linux 指南](../linux-packaging.md)；当前没有 macOS 发布流程。
- **不跑集成测试**：需要真实窗口、播放器与 fixture 媒体，仍由 `tools/phase*` 的本地验收脚本覆盖。
- **Node / Python 随包、JDK 需本机**：Node 内置在 `runtime/node/node.exe`；专用 Python 与依赖以离线包随发行版提供，运行与修复不联网；JVM 站源需用户自备 JDK 17+。
- **CI 触发范围**：当前覆盖 `main` / `beta` / `dev*` 推送、PR 到 `main` 与手动触发，详见 `desktop-ci.yml`。

## 8. 应用更新（ADR-0015）

构建：发布流水线的两个平台构建都必须注入 --dart-define=APP_TAG=<release tag>，
否则安装包会把自己当成开发构建，永远收不到更新提示。本地开发构建不注入，行为是
「只展示最新发布、不自动判断更新」。

发布：每个 Release 必须包含 `SHA256SUMS.txt`。应用下载前先读它（或 GitHub API 的
`assets[].digest`），校验不过就删除文件并报错；没有校验值的发布拒绝安装。

更新索引：发包成功后，发布流水线从真实发布记录自动生成 `releases.json`，上传到
固定 prerelease tag `update-channel`（`.../releases/download/update-channel/releases.json`）。
客户端优先读它，失败才查 Releases API 一次；索引缺失或损坏不会显示成「已是最新」。
流水线改动合并后的**下一次发布**才产生第一个真实索引。

下载加速：应用默认经公开 GitHub 下载代理（`https://gh-proxy.com/`，可切换
`https://ghfast.top/` 或自定义 HTTPS 前缀）下载安装包与校验文件，代理失败自动
回退直连；只代理本项目公开 Release 地址，API 与其它地址直连，代理不接收
Cookie/Authorization。第三方代理能看到公开下载 URL，速度因网络而异；代理结果仍
必须通过完整包 SHA-256，失败不降低校验门禁。

行为：

- 检查：设置 → 维护 → 软件更新；或开启「启动时自动检查」（默认关闭，24 小时最多一次）。
  数据来源是 GitHub Releases API，按稳定版/测试版两个通道筛选；同名版本按 tag 的
  构建时间戳比较先后。
- 安装（Windows 便携包）：下载 → 校验 → 在 `<cache>/updates/<tag>/` 写
  `apply-update.ps1` 并以 detached 方式启动；脚本等本进程退出后解包、把安装目录
  改名为 `<安装目录>.webhtv-old`、移入新 payload、启动新版本；任一步失败还原旧目录。
  日志在 `<cache>/updates/<tag>/update.log`。
- 签名：仍未配置。SHA-256 只证明文件完整，不证明发布者，所以应用不会静默自动安装。
  引入签名通道前，不建议把「下载并安装」做成无人值守动作。
- 受保护目录：便携包若解压到 Program Files 这类需要提权的目录，换装脚本的目录
  改名会失败并保留原目录（日志可读），应用不会提权。

人工验收要点：

1. 用带 APP_TAG 的包启动，在更新页能看到「当前版本 + 发布 tag」；
2. 手动检查能拿到通道里最新的 tag，且不会把测试版推给稳定版用户；
3. 下载进度可见，篡改过的资产会被拒绝（删文件 + 报错）；
4. 退出应用后换装脚本完成替换并启动新版本；失败时旧目录仍在、日志可读；
5. 未签名包与签名包的提示与 release-info.json 中的签名状态一致。
