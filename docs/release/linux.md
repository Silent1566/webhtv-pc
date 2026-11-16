# Linux x86_64 发行与内置 Python

## 普通用户

Linux 正式发行包（AppImage、deb）随包提供专用 Python 3.14.10 与 CatVod 常用依赖。
使用 Python 站源不需要安装系统 Python，不需要运行 pip，也不需要填写解释器路径。
首次使用 Python 站源时，应用自动校验并将离线包解压到应用数据目录，准备完成后再启动独立 sidecar。

- 安装包内的修复源：runtime/python/python-runtime.zip 和 bundle.json。
- 准备后的解释器：默认位于 ~/.local/share/webhtv-pc/runtime/python/env-*/bin/python3；遵循 XDG_DATA_HOME 或显式 profile 目录。
- 运行环境页显示实际来源、路径、版本及 requests/Crypto/lxml/bs4 的检查结果。
- “离线修复内置环境”只使用随包修复源，不联网、不下载、不改系统 PATH 或系统 Python。
- 清理应用缓存不会删除内置运行环境；正在运行 Python 源时不能修复或切换解释器。
- 自定义解释器是可选高级设置；已有选择被保留，失败的切换不会覆盖最后有效的选择。
- JVM 站源仍需要可用的本机 JDK 17+；单个站源及播放能力以实测为准。

发行包不包含用户的站点源、配置、数据库或日志。应用支持用户自己的配置，不提供默认影视内容。

## 发行构建（面向开发者）

目标基线为 Ubuntu 22.04/glibc 2.35、Linux x86_64。构建机器需要 Python 3 等现有构建工具；这些是构建依赖，不是终端用户使用 Python 站源的要求。

在仓库根目录准备固定版本运行时：

    python3 scripts/prepare_python_runtime_linux.py \
      --output-dir runtime/python \
      --cache-dir .local/python-runtime-linux/cache \
      --lock-file scripts/python-runtime-linux.lock.json

联网只发生在构建阶段。CPython 使用 python-build-standalone 的固定发行资产，所有 wheel 的完整依赖闭包固定 URL、尺寸和 SHA256，Crypto 包为 pycryptodome<4。归档中保留 Python 和依赖许可证。

缓存完整时可加 --offline；构建前可用下列命令只校验现有产物：

    python3 scripts/prepare_python_runtime_linux.py \
      --output-dir runtime/python --validate-only --offline

然后按既有流程构建 Flutter、准备 Node/JVM 宿主与 native 依赖并生成 AppImage/deb。Linux CMake 和打包程序都会拒绝缺少或无效的 Python 包，不能生成依赖系统 Python 的降级发行包。

    cd apps/desktop-flutter
    flutter pub get
    flutter build linux --release

打包程序的 --python-runtime-dir 默认指向仓库 runtime/python；只读离线包复制到两个发行格式中。版本、归档路径和 SHA256 进入 release-info.json。Node、JVM 和原有 native 库审计规则保持有效。

## 验收

不能把开发机已有的系统 Python 或自定义 venv 当作内置运行时证明。Linux release/CI 强制执行：

    cd apps/desktop-flutter
    WEBHTV_REQUIRE_BUNDLED_PYTHON=1 flutter test \
      test/linux_bundled_python_integration_test.dart

此测试使用全新隔离 profile、空系统候选和空 PATH，从本地测试 CatVod 的导入/首次使用自动准备内置环境，真正导入四项依赖并返回确定的首页结果；不调用手动修复或自定义切换来帮助首次启动。还检查只读修复源未被改写、重启复用、清缓存保留、活动源拒绝修复、坏修复源保留旧环境。

缺包时强制验收失败，不能静默跳过。发布 smoke 还需解包 AppImage 和 deb，检查其运行时数据并在隔离路径验证解释器，而不只是看到压缩包文件名。

## 安全边界

沿用 schemaVersion=1；Windows 入口仍为 python.exe，Linux 为 bin/python3。应用只支持当前 ABI 对应的平台包，验证 SHA256/CRC、尺寸、路径和文件集合后才设置 Linux 入口的 0700 权限并执行。
最终 ZIP 上限 64MiB、展开上限 128MiB、文件上限 10000。链接、特殊文件、路径穿越、重复路径和损坏输入会被拒绝；失败准备不提交新的 active 指针。
