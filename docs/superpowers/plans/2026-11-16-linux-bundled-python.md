# Linux 内置 Python 实施任务书

> For agentic workers: use subagent-driven-development with the session dispatcher rules. Every child edits only its assigned boundary; Lead owns acceptance.

**Goal:** Linux x86_64 发布包自带 Python/CatVod 依赖，普通用户首次使用无需安装或配置解释器。
**Architecture:** Hybrid。Lead 冻结平台适配与安全解包；离线包构建和 Linux 发布接入并行；Lead 做真实首启动验收。
**Tech Stack:** Python 标准库、Dart/Flutter、CMake、GitHub Actions、AppImage/deb。
**Spec:** 本文件 Accepted scope，来源为本会话用户“完善吧”对上一轮产品级修复目标的明确要求。

## Accepted scope / Global Constraints
- 当前目标为既有 Linux x86_64 发布链，Ubuntu 22.04/glibc 2.35 基线；不扩展 ARM/macOS。
- 保留 Windows x64 内置环境、系统/自定义备用和已有公开 PythonEnvironment/AppState API。
- Python 固定 3.14.10，CatVod 依赖版本沿用 scripts/python-runtime.lock.json:1 的完整闭包；Crypto 使用 pycryptodome 3.24.1 (<4)。Linux wheel 单独锁定 URL、尺寸、SHA256。
- 只有构建阶段可联网。用户首次使用、检测和修复全部离线；不修改系统 Python/PATH、不碰真实用户配置或刚才配置好的解释器。
- 随包 runtime/python/{python-runtime.zip,bundle.json}；schemaVersion=1，platform=linux-x64，入口 bin/python3；Windows 仍为 windows-x64/python.exe。现有字段 packages/files/probeModules 不变，四模块顺序 requests,Crypto,lxml,bs4。
- 最终 ZIP <=64MiB，解压 <=128MiB，文件 <=10000；不含链接/特殊文件/重复或穿越路径；逐文件尺寸/SHA256/CRC 与归档 SHA256 均验证。Linux 解压到 dataDir 后只为验证过的 bin/python3 设置 0700。
- 包缺失、错误平台或校验失败必须阻止 Linux 构建/发布，不能悄悄发布需系统 Python 的降级包。
- 实现子代理不提交或推送、不分派子代理；报告为证据，不是 Lead 验收结论。交付阶段由 Lead 按用户明确要求提交、推送并创建目标 beta 的中文 PR。

## Task 1: 运行时 seam — Lead（run 1/3）
Boundary: apps/desktop-flutter/lib/services/python_environment.dart, python_bundle_store.dart; test/python_environment_test.dart, bundled_python_integration_test.dart, linux_python_bundle_test.dart。
- [x] 新增 Linux bundle/权限/跨 OS 拒绝测试并确认原实现两项失败。
- [x] 按 Abi 选择 Windows/Linux schema 和入口，校验后仅 chmod Linux 入口。
- [x] 平台化纯 fixture；Windows ACL/junction 的原生场景保持 Windows-only。
- [x] Linux 两项新增测试与旧 fixture 测试通过（31 pass；14 个 Windows 原生场景不在 Linux 冒充通过）。

## Task 2: Linux 离线包构建 — child（run 2/3，Lead accepted）
### Goal
构建经源哈希锁定、带许可、可移动且不依赖系统 Python 的 Linux Python 离线包。
### Boundary / source pointers
可编辑的源文件仅 scripts/prepare_python_runtime_linux.py（新建）、scripts/python-runtime-linux.lock.json（新建）、tests/test_prepare_python_runtime_linux.py（新建）。可创建生成物于 runtime/python/** 和 .local/python-runtime-linux/**；报告写到分派给你的 brief 相邻 report 文件。
先读 scripts/prepare_python_runtime.ps1:36、:119、:181 和 scripts/python-runtime.lock.json:1；解包契约以 apps/desktop-flutter/lib/services/python_bundle_store.dart:7、:71、:205 为准。
### Frozen interface
CLI: python3 scripts/prepare_python_runtime_linux.py [--output-dir runtime/python] [--cache-dir .local/python-runtime-linux/cache] [--lock-file scripts/python-runtime-linux.lock.json] [--offline] [--validate-only]。
导出纯函数 validate_bundle(directory: pathlib.Path) -> dict，返回已验证 manifest；失败抛 ValueError（可用其子类）。此函数验证 schema、完整文件/CRC/hash/大小/平台和锁定包版本，但不执行归档代码、不联网；Task 3 可直接复用它。
--validate-only 验证既有输出且不能下载/重建；--offline 仅允许哈希匹配的缓存。
### Constraints
Linux CPython 使用 astral-sh/python-build-standalone 的固定发行资产，不执行远程未知脚本或构建 sdist。
已验证资产：https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.14.10%2B20261110-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz
其发行 SHA256SUMS 中 SHA256 为 c2ff2e97422f5d3896a16e0317fd212ba977bbf2688d93a6f7a03d817506bd30；checksum 来源 https://github.com/astral-sh/python-build-standalone/releases/download/20261110/SHA256SUMS。
安装 wheel 的平台须兼容 glibc <=2.35；固定全部依赖 URL/hash/size。不要用浮动 pip install。保留 CPython 和依赖许可。
上游 tar 内部链接如需扁平化，只允许已验证的归档内目标，拒绝绝对/越界/循环链接及设备文件；最终 ZIP 只能有普通文件。可移除非运行必需的测试、缓存、静态开发文件以满足既有上限，不能删除许可或必要模块。
产出固定时间/排序的 ZIP。缓存命中也必须校验；损坏输入/输出不能覆盖有效旧输出。原生执行只能在来源与每个文件均通过校验之后进行。
### Limits
Implementation attempts: at most 3 total per run; does not reset within a run; unused attempts are not banked.
Source files edited: at most 3 tracked files total per run, only the named Boundary; generated cache/output files: unlimited inside the named generated directories.
Commands run: unlimited per run.
Test runs: unlimited per run.
Report files: at most 1 per run, at the assigned adjacent report path.
No per-cycle reset or banking of bounded totals.
### Acceptance Criteria / Required Evidence
- [x] 测试先红后绿；覆盖冷构建/缓存离线复用、源哈希错、输出篡改/缺失、越界或链接、包体限制与失败保留旧包。
- [x] 原生生成真实 runtime/python 包；在 PATH 空、PYTHONHOME/PYTHONPATH 不参与的隔离环境中，从另一个临时路径执行该解释器并真正 import requests/Crypto/lxml.etree/bs4，版本准确。
- [x] --offline 重建/复用和 --validate-only 均通过，许可在包内。
- [x] 报告 status、变更 diff 范围、完整命令和短结果、最终 ZIP/展开大小/文件数/哈希、原生 probe、限制或 hand_back 原因。若契约上限无法满足，hand_back，不改 Lead 的文件。

## Task 3: Linux 构建与发布门禁 — child（run 2/3，Lead accepted）
### Goal
Linux 开发构建、AppImage/deb 与 CI/release 都携带并验证离线 Python；发布信息不再要求系统 Python。
### Boundary / source pointers
可编辑的源文件仅 scripts/package_linux.py、tests/test_package_linux.py、tests/test_linux_workflows.py、.github/workflows/desktop-ci.yml、.github/workflows/desktop-release.yml、apps/desktop-flutter/linux/CMakeLists.txt。报告写到分派给你的 brief 相邻 report 文件。
先读 scripts/package_linux.py:341、:464、:493；apps/desktop-flutter/linux/CMakeLists.txt:79；.github/workflows/desktop-release.yml:474；tests/test_package_linux.py:1、tests/test_linux_workflows.py:1。
Task 2 同时实现，读源码可不限，不能改其 Boundary。
### Frozen interface / Constraints
复用 scripts/prepare_python_runtime_linux.py 的 CLI 与纯 validate_bundle(Path)->dict（ValueError 表示无效）；模块可能稍后才出现，不要代写 stub 或改它。包目录/manifest 契约见 Global Constraints。
CMake 应将已校验 runtime/python 两文件带入 bundle，缺失/无效就失败；不要在 CMake 内偷偷联网。CI 在 flutter build linux 前显式准备它。开发者准备构建输入与终端用户安装配置是两回事。
package_linux.py 增加 --python-runtime-dir（缺省仓库 runtime/python），在构建 AppImage/deb 前做严格校验并复制两文件；拒绝污染、链接、输出/输入重叠。两个包都包含相同数据，不带用户 spiders/config/db。Node、JVM、native library 审计不退化。
release-info.json runtimes.bundled 增加 Python 的版本、归档路径/hash，requiresLocal 移除 Python 3；deb 不再 Recommends python3，JDK 仍可选系统依赖；notes 亦一致。
CI 运行 Linux native bundled integration test，WEBHTV_REQUIRE_BUNDLED_PYTHON=1（该新测试由 Lead 完成）；缺包绝不能 markTestSkipped 后假通过。发布两格式解包 smoke 要验证 Python bundle 也存在并能在隔离临时目录运行；不能仅校验文件名。
### Limits
Implementation attempts: at most 3 total per run; does not reset within a run; unused attempts are not banked.
Source files edited: at most 6 tracked files total per run, only the named Boundary.
Generated test fixtures: unlimited inside system temporary directories; do not mutate runtime/python or the builder's cache.
Commands run: unlimited per run.
Test runs: unlimited per run.
Report files: at most 1 per run, at the assigned adjacent report path.
No per-cycle reset or banking of bounded totals.
### Acceptance Criteria / Required Evidence
- [x] 用真实有效 fixture 测试 package API：缺包/篡改/错平台拒绝；AppImage/deb 均含两文件；metadata、deb 依赖不再要求系统 Python；旧 Node/native 排除规则仍通过。
- [x] CMake 缺包拒绝和有效包安装验证；workflow 既有 contract tests 通过，运行先准备后构建且原生验收不静默跳过。
- [x] 报告 status、diff、测试先红后绿命令/结果、安装或包内容证据；有跨接口问题以 hand_back 明确指出，不越界。

## Task 4: 首次使用、文档与整体验收 — Lead（run 1/3）
- [x] 新增 Linux 原生 AppState 集成测试：全新 profile、系统候选为空、PATH 空，从导入/选择 CatVod 自动触发内置环境准备并返回确定的 homeContent；无手动 repair/setCustom。缺包强制 gate、只读安装目录不被写、重启读取 active 指针、清缓存保留、修复坏包保留旧环境。
- [x] 将 Linux 高级自定义路径文案改成 Python 可执行文件而不是 Windows-only python.exe；仅 copy，不改布局。
- [x] docs/release/linux.md 记录内置运行时、构建准备和离线修复；Windows 说明不改变。
- [x] Lead 读取每项最终 diff、复跑风险相关测试、dart analyze、Linux build；原生包可用时验证解包后的真实启动。没有验证到的项如实交付，不能把本机备用环境当成发布证明。

## Decision log / Review
- Settled: 用户无需安装配置；当前 Linux x86_64；沿用 Windows 安全版本/包版本与离线模型。
- Existing standard: schemaVersion=1、dataDir 原子 generation、完整性与链接边界；不降低原有安全门禁。
- Ruled out: 用户机 pip 自动补包、联网首次准备、依赖系统 Python、修改真实用户偏好。
- Completion: 构建/发布缺包失败，真实离线解释器 + 首使用 AppState CatVod 通过，Windows 契约不回归。

## Final Lead verdict / release hand-off

代码与既定运行时/构建门禁任务通过最终验收：81项Linux管线测试、103项相关Dart测试和真实Linux Release编译通过；新原生测试证明无需系统Python或手动设置。两项P2回滚发现均已修复并独立复审关闭。

发布门禁尚待正式Ubuntu22.04 CI运行；本机Docker无权限且缺libmpv.so.2，完整真实客户端AppImage/deb打包被原native审计正确拒绝，无部分安装包发布。不要把这个开发环境限制改成用户必须安装Python，或绕过native审计。

- [ ] 在原Ubuntu22.04 CI环境生成并验收正式安装包；保留原生依赖准备、无Python首使用和两格式smoke mandatory gate。

验收记录：.superpowers/sdd/2026-11-16-linux-bundled-python/delivery-summary.md。
