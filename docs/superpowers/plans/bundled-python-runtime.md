# 内置 Python 运行时与环境设置任务书

**Goal:** Windows x64 普通用户无需安装 Python；软件随包提供轻量环境，离线准备/修复，设置页可检测和选择自定义解释器。
**Architecture:** 发行目录包含只读离线压缩包与校验清单，运行时解压到 AppPaths.dataDir 下的软件专用目录。运行时管理负责校验、原子替换、持久选择与状态；AppState 负责启动/切换缓存，UI 只调用公开操作。
**Tech Stack:** Dart / Flutter / archive / crypto / Windows / PowerShell。
**Spec:** 本文件“已确认决策”即本轮规范。

## 已确认决策
- Windows x64 默认内置轻量 Python 和 CatVod 常用依赖；用户确认只做内置包离线修复，不做联网更新界面。
- 专用运行时优先，允许显式自定义 python.exe；不改系统 PATH、不往系统解释器安装包、不修改或删除自定义环境。
- 设置显示解释器路径、版本、来源、依赖、失败原因；可重新检测、离线修复、恢复默认和选择自定义解释器。
- 运行时在 dataDir，不放 cacheDir；清缓存必须保留。安装目录只读也可使用和修复。
- 用户依据新的官方安全发布信息确认改用 Python 3.14.10 官方 Windows x64 嵌入式包，固定 wheel 依赖并验证 CatVod 兼容；3.13.18 为源码安全发布，不以内置缺补丁的3.13.17代替。
- 保留本地源和现有全部未提交改动；不提交git。扫描仍不执行用户源，只有使用源时启动sidecar。

## 根基证据
- Node 已有 runtime/node/node.exe 内置优先模式，lib/services/node_runtime.dart。
- scripts/package_windows.ps1 已负责 Node、三类sidecar及发布校验，缺宿主即失败。
- Python宿主 host.py:45 已把自身目录加入sys.path，适配嵌入式隔离路径时仍需真实验证。
- archive、crypto 是直接依赖，不新增Dart依赖。
- 设置入口在 lib/ui/diagnostics_pages.dart SettingsPage；复用既有tokens与SettingsSection。

## 固定跨任务契约
发行/开发包目录为 runtime/python，仅含 python-runtime.zip 和 bundle.json（不依赖全局Python）。
```json
{
  "schemaVersion": 1,
  "pythonVersion": "3.14.10",
  "platform": "windows-x64",
  "archive": "python-runtime.zip",
  "archiveSha256": "64位小写hex",
  "probeModules": ["requests", "Crypto", "lxml", "bs4"],
  "packages": [{"name": "requests", "version": "固定版本"}],
  "files": [{"path": "python.exe", "size": 0, "sha256": "64位小写hex"}]
}
```
上面的版本/size/hash仅为schema说明，生成产物必须填实际值，不得保留示例。ZIP不包含bundle.json自身；文件相对路径使用/。官方原包文件和wheel许可证/dist-info必须保留。

UI 与 AppState 契约（由B生产，由C消费）：
```dart
enum PythonEnvironmentSource { bundled, custom, system, missing }
class PythonEnvironmentStatus {
  // 命名参数构造器：executable=''、version=''、source=missing、dependencies=const{}、error=null。
  // 公开字段：executable/version为String，source为枚举，dependencies为Map<String,bool>，error为String?。
  bool get ready;
}
// AppState:
PythonEnvironmentStatus? get pythonEnvironmentStatus;
bool get pythonEnvironmentBusy;
String? get pythonEnvironmentError;
Future<void> refreshPythonEnvironment();
Future<bool> repairPythonEnvironment();
Future<bool> setCustomPythonExecutable(String executable);
Future<bool> useDefaultPythonEnvironment();
```
status.error说明当前环境故障；pythonEnvironmentError说明操作失败。无效自定义选择不改变已保存选择及有效解释器。B在 services/python_environment.dart 定义类型；C静态import和调用，不用dynamic临时绕过。

## Task A — 离线包构建与Windows发布（运行1/3）
**Goal:** 构建经过校验、带许可证、独立可用的离线Python压缩包，并装入Windows debug/release与发行ZIP。
**Boundary:** scripts/prepare_python_runtime.ps1（新）、scripts/python-runtime.lock.json（新）、scripts/package_windows.ps1、apps/desktop-flutter/windows/CMakeLists.txt、.gitignore、专属脚本测试，必要CI准备步骤；不改Dart/UI/用户配置。
**Constraints:** 仅官方Python与PyPI固定wheel，禁止执行远程未知脚本或构建sdist；锁文件固定URL/版本/SHA256，缓存同样校验；生成含requests/urllib3/charset-normalizer/idna/certifi/pycryptodome<4/lxml/beautifulsoup4/soupsieve/typing-extensions的完整闭包。正确配置python314._pth加载Lib/site-packages。bundle.json schema严格匹配以上；包缺失或校验失败不能产出降级发行包。仅构建阶段联网，用户运行/修复零网络。
**Limits:** 派发运行次数cap3，任务累计；源码/测试/配置文本编辑cap8文件，任务累计；命令调用与测试次数不限；对同种失败命令方案cap2次累计，之后按新证据换方案；生成/解压产物cap10000文件每次bundle构建重置不积攒；单次下载cap64MiB/文件不累计，展开bundle cap128MiB/次构建不累计；公开HTTP请求cap50次任务累计。无新证据等待cap3协调轮。
**Acceptance:** 离线缓存复用、哈希错拒绝、缺包拒绝、无用户源/配置入包、官方版本和依赖锁定、许可证存在、真实内置python不靠系统环境可导入四模块。主程序包体增量实测。
**Evidence:** red/green命令、官方版本与哈希来源、所有源码文件、真实bundle路径/SHA/压缩与展开体积、完整依赖及许可证、native导入测试、未验证项。发布最终ZIP待B/C完成后的主程序构建，由协调验收。

## Task B — 环境管理与运行时接入（运行1/3）
**Goal:** 没系统Python也能从离线包准备并使用软件专用环境；设置操作与旧爬虫启动正确联动。
**Boundary:** lib/services/python_environment.dart（新）及必要一个bundle-store helper、lib/services/spider_process.dart、lib/services/spider_registry.dart、lib/state/app_state.dart、专属python_environment_test.dart/bundled_python_integration_test.dart；不改A打包文件、C UI、pubspec。
**Constraints:** ZIP/清单哈希、逐文件尺寸/哈希、路径穿越/绝对路径/Windows保留路径/链接均验证；先验证并stage，失败不破坏有效旧环境/自定义环境。只写dataDir下软件专用runtime，不能写安装目录。运行中的Python源切换/修复明确拒绝，别杀正在用的源。偏好持久化到configDir；切换成功清解释器/Router快照缓存。旧系统Python与直接js/py支持不退化；无内置包时清楚提示缺包并可保留系统备用，发行包不能缺包由A保证。
**Limits:** 派发运行cap3次任务累计；源码测试编辑cap8文件任务累计；命令与测试不限；同失败命令方案cap2次累计；单bundle输入cap64MiB/次操作，展开cap128MiB/次操作，文件cap10000/次操作，均每操作重置不积攒；测试fixture产物cap10000/次测试不累计。运行/修复网络请求cap0，任务累计。无新证据等待cap3协调轮。
**Acceptance:** PATH与launcher均无Python时真实内置解释器运行CatVod首页；只读安装目录可准备；坏zip/manifest/单文件拒绝且旧环境保留；清缓存保留；自定义保存/重启/失败回滚与恢复默认；首次Python源调用等待环境ready不假报不支持；并发操作互斥，UI不做同步重活。
**Evidence:** 每标准真实red/green、SDK命令、改动/API行号、native隔离环境smoke、与现有本地源/101运行时回归、未验证项。对大量旧AppState测试用合法依赖注入或测试命令环境隔离避免反复复制实际bundle，不能弱化无Python真实smoke。

## Task C — 运行环境设置页（运行1/3）
**Goal:** 用户可看懂环境来源/版本/依赖与错误，执行检测、离线修复、自定义选择和恢复默认。
**Boundary:** lib/ui/python_environment_page.dart（新）、lib/ui/diagnostics_pages.dart 设置入口、必要advanced_settings_page.dart、专属widget/navigation测试；不改A/B/runtime服务或pubspec。
**Constraints:** 静态使用上述B接口和类型，复用现有设计系统。按钮有文字/忙碌反馈，错误可见，false/throw不误报成功，mounted与异步清理安全；路径输入+已有file_picker选择.exe；解释清缓存不删环境/修复无网络/自定义不会被修改；不增加在线更新/下载按钮。
**Limits:** 派发运行cap3次任务累计；源码/测试编辑cap5文件任务累计；命令/测试不限；同失败方案cap2次累计；fixture cap10000文件每测试重置不积攒；网络请求cap0任务累计。无新证据等待cap3协调轮。
**Acceptance:** 真实widget覆盖未检测/ready/missing/degraded、四操作成功与错误、busy重复拒绝、路径无效选择、切换不抢旧环境、窄窗无溢出与真实设置导航；不以dynamic或纯Mock行为作为生产通过。
**Evidence:** UI关键key与接口、red/green完整结果、临时路径隔离、可见错误与busy/布局覆盖，未做nativeGUI应明示。

## 预检契约表
| 任务/接口 | 产出与消费 | 结论 |
| A→B | runtime/python/python-runtime.zip + bundle.json schemaVersion1/files/hash | 压缩包是只读修复源，B只写dataDir，边界不重叠 |
| B→C | services/python_environment.dart 类型与AppState六操作/状态 | 静态调用，B先公开接口，C不得改B或dynamic绕过 |
| A | 依赖闭包/固定hash/原生导入/发布缺件即失败 | 不执行sdist安装脚本，缓存仍验hash |
| B | 哈希与原子stage/错误保留旧环境/无系统Python | 测试路径注入，不写真实用户目录 |
| C | 只UI调用/错误/布局/导航 | 不负责环境安装算法 |

## 最终验收记录
- A（打包/发布）run2 六项返工限定复审：Spec/Quality 通过；协调独立复跑 `test_python_runtime.ps1 -Review -Integration` GREEN 15，零联网。
- B（环境管理）run3 收尾：F1–F7 + 首页身份/launcher死参数/备份碰撞共 10 项全部 RED→GREEN；限定终审 Spec/Quality 通过，新破坏清单为空。
- C（设置页）run2 四项返工限定复审：Spec/Quality 通过，54 UI+导航与 43 设置回归全绿。
- 协调独立联合回归：302/302 通过；全量 `flutter analyze`：No issues found。
- 协调独立发行验收：Release 构建成功；真实 `package_windows.ps1` 产出 ZIP，内含 `runtime/python/{python-runtime.zip,bundle.json}` 与 `runtime/node/node.exe`，release-info 声明 `python:3.14.10`，无用户数据/spiders/db 泄漏。
- 端到端 smoke：从发行 ZIP 内解出 `python-runtime.zip` 并展开，PATH 仅 System32 下 `python.exe -I -B` 版本 3.14.10，requests/Crypto/lxml/bs4 全部可导入。
- 体积实测：发行 ZIP 91.76 MiB，其中内置 Python 压缩后 18.43 MiB（20.1%），不含 Python 基线约 73.33 MiB。
- 已知未验证：真实 GUI 点击全流程、全新无 Python 虚拟机、真实网络故障下的导航错误、JDK 依赖站源。
- 用户要求：不提交 git。

## 最终验收
协调独立读取关键补丁与安全边界、复跑定向测试和必要回归、flutter analyze、Windows debug/release构建、实际发行ZIP内容与无系统Python smoke、体积增量与SHA256。每个发现缺陷返工或交用户范围决定，不只记风险后交付。用户要求未提交git。
