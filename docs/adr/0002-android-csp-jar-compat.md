# ADR-0002：Android `csp_*.jar` 站源的兼容路径

- 状态：已接受（兼容层定位），**A1/A2 未实施**；D 方案（桌面 JVM ABI）**已实施**（见 §3 与 §6）
- 日期：2026-10-05
- 决策：**不把 Android 运行时（模拟器/容器）作为主路线**；把它定义为**可选、非默认、
  用户显式开启**的兼容层。主路线仍为设计文档 §9.3 定义的桌面 JVM ABI（`tvbox-java-v1`）。
- 相关章节：§1（语言相同≠运行时复用）、§5.6（不推荐方案）、§9.3（ABI 版本表）、
  §9.4（HTTP Spider ABI）、§9.8（进程隔离）、§9.9（兼容层设计）、§17.2、§21 Phase 3、
  §22.2（性能门禁）、§22.3（安全与隐私验收）

## 1. 背景

生态中大量配置的站点形如：

```json
{ "key": "csp_PianDan", "type": 3, "api": "csp_PianDan", "jar": "https://…/custom_spider.jar" }
```

`api` 里的 `csp_<类名>` 指向 jar 内的 Spider 子类。

> **实施后更新（D 方案已落地）**：`csp_*` 站点现已不再一律报不可用——PC 端会先找本地
> 缓存的**桌面** jar（`<config>/spiders/csp/<key>/`）并映射到 `jvm` 运行时（见 §5）。
> 缺 jar 或 jar 内含 `classes.dex` 时仍如实报不可用，原因里带缓存目录与 dex 说明。
> 本 ADR 第 1–4 节保留决策当时的背景与理由，A1/A2 仍**未实施**。

本 ADR 回答一个此前未展开的问题：**是否存在一条能真正运行现成 Android jar 的路径？**
以及它与 §5.6「Android 模拟器包装」的不推荐结论如何共存。

### 1.1 关键事实：能执行 dex 的只有 ART，不是 JVM

| 载体 | 能否运行现成 `csp_*.jar` | 原因 |
| --- | --- | --- |
| 桌面 JVM（`tvbox-java-v1`） | ❌ | jar 内为 `classes.dex`；且站源依赖 `Context`、`DexClassLoader`、`okhttp3` 等 Android 侧依赖 |
| dex→class 转译 + Android shim | ⚠️ 仅自编译的简单 jar | 现代 dex 特性（invoke-custom、默认方法、混淆）会破坏转译；shim 需覆盖 `SharedPreferences`/`Base64`/反射/资源。已有先例仅用于**测试**（`johnsonlee/testpilot`），不是产品运行时 |
| **真 Android 运行时（ART）** | ✅ 唯一可行 | `Context`、`DexClassLoader`、Android 工具类齐备 |

因此，**要兼容现成 Android jar，就必须有一台 Android 在跑**。差异只在「Android 放在哪」。

## 2. 决策

### 2.1 保留 §5.6 的结论

§5.6 拒绝的是「**把 Android 模拟器包装作为产品形态**」——即让 PC 版等于一个模拟器壳。
该结论不变：模拟器冷启动、内存占用与架构转译都无法满足 §22.2 的冷启动/首帧门禁，
也不能作为默认交付形态。

### 2.2 新增：兼容层定位

本 ADR 将「Android 运行时」重新定位为**兼容层**，规则如下：

1. **默认关闭。** 未在设置中显式开启时，`csp_*`/`jar` 站点仍显示结构化不可用结论
   （与当前行为一致），不得静默尝试启动模拟器。
2. **非主路线。** 桌面 JVM ABI（`tvbox-java-v1`）才是 Phase 3 承诺的 PC Java 运行时；
   兼容层只是「让存量 Android jar 能用」的补充路径。
3. **独立 sidecar 进程。** 符合 §9.8：主进程不加载任何不可信代码；Android 运行时与
   UI 进程隔离，崩溃只影响该站点。
4. **走既有 HTTP 契约。** Android 侧必须实现 §9.4 `webhtv-cat-http-v1` 的六个路由
   （`/init` `/home` `/category` `/detail` `/search` `/play`），宿主侧复用现有
   `CatHttpClient` 与 `looksLikeCatHttp`，不新增 ABI 版本。§9.4 已明确「PC 端如需扩展，
   必须新开 ABI 版本或 capability，不能悄悄改变 `tvbox-http-v1` 语义」，因此
   **只实现这六个路由**，`/live` `/proxy` `/action` 保持未实现并如实报错。
5. **不进入安装包。** Android 运行时（镜像 + 桥接 APK）体积远超安装包预算，
   只能作为用户按需安装的外部依赖；缺失时 UI 必须显示可定位原因。
6. **合规边界不变。** §3.1「不内置爬虫、不内置站点配置」继续适用：兼容层只负责
   **执行用户自行导入的站源**，不随包分发任何 jar/镜像/站源。

## 3. 候选方案对比

| 方案 | 载体 | 能跑现成 jar | 一次性成本 | 运行成本 | 打包影响 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| **D** 桌面 JVM ABI | `sidecars/spider-host-jvm` | ❌（需桌面版 jar） | 3–6 人日 | 极低 | 小（几十 MB） | ✅ **主路线，已实施** |
| **E** 远程 Android 设备 sidecar | 用户手机/盒子 | ✅ | 2–4 人日 + 新 ABI | 低（借设备） | 无 | ✅ 性价比最高，**未实施** |
| **A1** Android Emulator | 本机 `emulator.exe` + AVD | ✅ | 2–4 周（自建桥接 APK + 宿主适配） | 高（1–4 GB、冷启 30–90 s） | 需外装镜像（~1.5 GB） | ⚠️ 仅「单机自足」时启用 |
| **A2** Redroid 容器 | WSL2 + Docker | ✅ | 同上 | 中（1–2 GB 常驻） | 需 WSL2 + Docker | ⚠️ 同上，Windows 无官方支持 |
| **A3** 真机 + adb | USB/局域网 | ✅ | 低 | 低 | 无 | 🟡 与 E 同源，适合开发期验证 |
| **A4** WSA | Windows 子系统 | ✅ | — | — | — | ❌ 2025-03-05 已从 Microsoft Store 下架，不作为产品依赖 |
| **B** dex→class 转译 | 纯 JVM | ⚠️ 不可行 | — | — | — | ❌ 仅适合逆向分析 |
| **C** 桌面嵌 ART / Chaquopy | — | ❌ | — | — | — | ❌ 无成熟产品，方向不符 |

### 3.1 A1/A2 的实施前提（未满足前不得标记为可用）

A1/A2 落地必须先补齐以下三项，否则「能启动模拟器」不等于「站点可用」：

1. **桥接 APK（必做）。** 这是第 4 个 sidecar 运行时的实体：需复刻 CatVod `Spider`
   基类、`DexClassLoader` 加载、`Result`/`Vod` 模型，并暴露 §9.4 六路由 HTTP 服务。
   **这一项是 A1/A2 的主要成本，而不是「启动模拟器」。**
2. **宿主适配层（约 30 行）。** `api` 是类名（`csp_PianDan`），不是 URL，需要把它与
   `jar` 作为 `extend` 转发到桥接地址；jar 下载与 md5 校验可复用 `cat_bundle` 的思路。
3. **端口转发与生命周期。** A1 用 `adb forward`，A2 用容器端口映射；退出时必须终止
   模拟器/容器，满足 §22.2「退出后主进程、sidecar 和代理端口全部释放」。

### 3.2 A1/A2 的已知风险

| 风险 | 说明 |
| --- | --- |
| **架构不匹配** | 现成 jar 常带 `arm64-v8a`/`armeabi-v7a` 的 `.so`。x86_64 镜像需 ARM 转译（慢且不总可用）；arm64 镜像更慢。这是「能跑但很卡」的头号原因。 |
| **冷启动门禁** | §22.2 要求冷启动 P95 < 3 s。模拟器冷启 30–90 s，必须常驻或懒启动，并在 UI 诚实显示「Android 兼容运行时启动中」。 |
| **常驻资源** | 1.5–4 GB 内存常驻，与 §22.2「内存无持续增长异常」需一并测量。 |
| **网盘线路** | 网盘直链常依赖 Android 侧 cookie/签名会话；§9.4 未定义 `/proxy`，GB 级流经 `adb forward` 亦可能成为瓶颈。此类线路可能仍不可用，必须如实报错。 |
| **依赖外部镜像** | 镜像与桥接 APK 由用户按需安装；版本漂移由用户承担，应用只报告可用性。 |

### 3.3 A1/A2 的验收要求（实施时必须全部满足）

1. **可用性如实上报**：未安装/未开启/启动失败时显示可定位原因，不得显示空列表
   （§9.9「不得静默把失败站点显示为空列表」）。
2. **进程隔离**：模拟器/容器作为独立 sidecar 管理，崩溃只影响该站点（§9.8）。
3. **门禁**：新增 `test/phase3_android_bridge_test.dart`（真实桥接服务六路由 +
   崩溃/超时/取消隔离）与 `integration_test/android_bridge_flow_test.dart`
   （真实窗口 + 真实桥接 + 真实 jar）。
4. **性能事实行**：冷启动耗时、常驻内存、退出后残留进程三项必须写入
   `docs/phase3/evidence/`，与 §22.2 门禁对照后明确「达标 / 不达标并记录原因」。
5. **默认关闭**：设置页提供显式开关与风险提示；未开启时行为与当前完全一致。

## 4. 与现有实现的关系

| 现有实现 | 位置 | 兼容层如何复用 |
| --- | --- | --- |
| §9.4 六路由契约 | `lib/core/cat_http.dart`（`CatHttpRoute`、`looksLikeCatHttp`） | 直接复用，无需新 ABI |
| `csp_` 形态判定 | `lib/services/spider_router.dart`（`hasStrongNonCatHttpSignal`） | 兼容层开启时改为可路由到桥接地址 |
| jar 下载/校验 | `lib/services/cat_bundle.dart` | 复用 md5 先取后下载的模式 |
| sidecar 监管 | `lib/services/spider_process.dart` | 复用超时/取消/退避/Job Object |
| 桌面 JVM ABI | `sidecars/spider-host-jvm` | 与兼容层并列，互不影响 |

## 5. 已实施的 D 方案（桌面 JVM ABI，`tvbox-java-v1`）

D 方案已落地，它是本 ADR 中唯一**默认可用**的 PC Java 运行时：

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| 宿主 | `sidecars/spider-host-jvm/host.jar` | 纯 JDK、零第三方依赖；`build.ps1` 用自带 `javac`/`jar` 构建（`--release 17`） |
| 站源基类 | `src/webhtv/spider/Spider.java` | `tvbox-java-v1` 抽象基类，同时提供 TVBox 风格钩子桥接 |
| 入口加载 | `src/webhtv/spider/EntryLoader.java` | 支持 `.jar` / 类目录 / `.java` / 源码目录四态 |
| 主程序接线 | `lib/services/spider_registry.dart` | `runtime=jvm*`/`java*` → `java -Xmx… -jar host.jar …` |
| `csp_*` 映射 | `lib/services/spider_router.dart`（`CspJvmBinding`） | `csp_<类名>` → 本地缓存桌面 jar；含 `classes.dex` 时明确报不支持 |
| 门禁 | `test/phase3_jvm_spider_test.dart`（18 例）、`integration_test/jvm_spider_flow_test.dart`（3 例）、`run_windows_acceptance.ps1` 的 `jvm-host-preflight` | 真实 JVM 子进程 |

实施中确认的两个**非显然**约束（已写入设计文档 §9.9 与 `sidecars/spider-host-jvm/README.md`）：

1. **JVM 堆参数必须显式给出。** 宿主用 Windows 作业对象把内存限制为 manifest 的
   `limits.memoryMiB`（默认 256 MiB），是硬限制；而 JVM 默认按物理内存 1/4 预留堆
   （本机实测 640 MiB），会直接 `os::commit_memory failed (DOS error 1455)` 退出，
   表现为「sidecar 启动即崩」而非可诊断错误。
2. **Java 运行时必须按版本探测，不能按 PATH 顺序取第一个。** 本机 PATH 上
   `jre1.8.0_501` 排在 JDK 21 之前；`host.jar` 为 `--release 17`，Java 8 会因
   `UnsupportedClassVersionError` 启动即崩。探测同时要求同目录有 `javac`，因为
   `.java` 源码入口需要 `javax.tools` 编译器。

**D 方案的边界**：它不运行现成 Android jar（见 §1.1）。`csp_*` 站点在 PC 端能映射到
`jvm` 运行时，但只接受**无 Android Context 的桌面 jar**。

## 6. 后果

- **正面**：给出了一条**真实可行**的 Android jar 兼容路径，且不破坏既定架构与 §5.6 结论；
  用户在有需求时可显式开启，代价与风险被明确披露。
- **负面**：兼容层不是零成本——主要成本在自建桥接 APK；且受 ARM 转译与冷启动限制，
  不能承诺「全部 Android jar 可用」。
- **对外表述约束**（沿用 §3.3）：只能说「支持 WebHTV / TVBox / 猫源配置协议和 Spider
  运行时；单个站源能否使用，以实际测试通过为准」。**不得承诺兼容全部 TVBox/猫源**。
