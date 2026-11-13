# Windows 构建与发布流水线

- 适用：WebHTV PC（`apps/desktop-flutter`，Windows x64，便携 zip）
- 工作流：`.github/workflows/windows-ci.yml`、`.github/workflows/windows-release.yml`
- 打包器：`scripts/package_windows.ps1`；启动烟测：`scripts/smoke_windows.ps1`
- 设计依据：`docs/webhtv-pc-design.md` §20（构建与打包）、§22.5（发布门禁）

## 1. 两条流水线

| 工作流 | 触发 | 作用 | 产物 |
| --- | --- | --- | --- |
| Windows CI | push `main` / `dev*`、PR 到 `main`、手动 `workflow_dispatch` | `dart analyze` + `flutter test` + Release 构建 + 打包 + 烟测 | workflow artifact（7 天） |
| Windows Release | 手动 `workflow_dispatch` | 上述门禁 + 可选签名 + 打包 + 烟测 + GitHub Release | Release 资产 + workflow artifact（30 天） |

CI 在 `main` / `dev*` 推送、PR 到 `main` 与手动触发时运行；实际步骤与触发条件以工作流文件为准。

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

`release-info.json` 是机器可读的发布事实（schema v1）：`version`/`build`/`channel`/`tag`/`commit`/`builtAt`/`platform`/`arch`/`flutter`/`signature`/`assets[]`/`runtimes`/`notes`。当前应用**没有自动更新**，不生成更新通道清单。

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
- **无自动更新**：`docs/phase9/README.md` P2-7 明确更新需要签名通道与 ADR，本轮不生成更新清单。
- **本指南仅覆盖 Windows x64**：仓库另有 Linux x86_64 平台工程与打包流程，见 [Linux 指南](../linux-packaging.md)；当前没有 macOS 发布流程。
- **不跑集成测试**：需要真实窗口、播放器与 fixture 媒体，仍由 `tools/phase*` 的本地验收脚本覆盖。
- **Node / Python 随包、JDK 需本机**：Node 内置在 `runtime/node/node.exe`；专用 Python 与依赖以离线包随发行版提供，运行与修复不联网；JVM 站源需用户自备 JDK 17+。
- **CI 触发范围**：当前覆盖 `main` / `dev*` 推送、PR 到 `main` 与手动触发，详见 `windows-ci.yml`。
