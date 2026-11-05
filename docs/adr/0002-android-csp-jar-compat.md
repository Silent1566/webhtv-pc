# ADR-0002：Android `csp_*.jar` 站源的兼容路径

- 状态：已接受（兼容层定位），**A1/A2 未实施**；D 方案（桌面 JVM ABI）**已实施**（见 §3 与 §6）；
  方案 B（dex→class 转译）**已实施，但范围受限**（P1-2，边界见 §3.4）——它**取代**了 §3 表格里
  对 B 的旧结论「❌ 仅适合逆向分析」
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

> **实施后更新（D 方案与方案 B 已落地）**：`csp_*` 站点现已不再一律报不可用——PC 端会先找
> 本地缓存的**桌面** jar（`<config>/spiders/csp/<key>/`）并映射到 `jvm` 运行时（见 §5）；
> 含 `classes.dex` 且**不含原生库**的 jar 会在导入期预转译成 class jar 再映射（方案 B，见 §3.4）。
> 仍如实报不可用的只有：缺 jar、含 `lib/*.so` 原生库、dex 不可转译或入口损坏——原因里带
> 缓存目录与转译阶段名。本 ADR 第 1–4 节保留决策当时的背景与理由，A1/A2 仍**未实施**。

本 ADR 回答一个此前未展开的问题：**是否存在一条能真正运行现成 Android jar 的路径？**
以及它与 §5.6「Android 模拟器包装」的不推荐结论如何共存。

### 1.1 关键事实：能执行 dex 的只有 ART，不是 JVM

| 载体 | 能否运行现成 `csp_*.jar` | 原因 |
| --- | --- | --- |
| 桌面 JVM（`tvbox-java-v1`） | ❌ | jar 内为 `classes.dex`；且站源依赖 `Context`、`DexClassLoader`、`okhttp3` 等 Android 侧依赖 |
| dex→class 转译 + Android shim | ⚠️ → ✅ **范围受限已实施**（P1-2，见 §3.4） | **本行判据是 2026-10 的初判，判断的是「普遍可用」**：现代 dex 特性（invoke-custom、默认方法、混淆）会破坏转译；shim 需覆盖 `SharedPreferences`/`Base64`/反射/资源；已有先例仅用于**测试**（`johnsonlee/testpilot`）。P1-2 以「收窄支持范围 + 垫片只覆盖实测可达闭包 + 其余明确拒绝」让它在限定条件下可用 |
| **真 Android 运行时（ART）** | ✅ 唯一可行 | `Context`、`DexClassLoader`、Android 工具类齐备 |

因此，**要兼容依赖 Android UI 或原生库的现成 jar，就必须有一台 Android 在跑**。差异只在
「Android 放在哪」。不碰 UI 且无原生库的那部分另有一条**范围受限**的 dex 通路（见 §3.4），
但它覆盖不了前一类，也不能替代下面这些候选方案。

## 2. 决策

### 2.1 保留 §5.6 的结论

§5.6 拒绝的是「**把 Android 模拟器包装作为产品形态**」——即让 PC 版等于一个模拟器壳。
该结论不变：模拟器冷启动、内存占用与架构转译都无法满足 §22.2 的冷启动/首帧门禁，
也不能作为默认交付形态。

### 2.2 新增：兼容层定位

本 ADR 将「Android 运行时」重新定位为**兼容层**，规则如下：

1. **默认关闭。** 未在设置中显式开启时，Android 运行时兼容层（模拟器/容器）不启动，
   不得静默尝试启动它；`csp_*`/`jar` 站点其余形态的可用与不可用一律如实上报，不因开关
   未开启而谎报（dex 通路不受此开关约束，见 §3.4）。
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
| **B** dex→class 转译 | 纯 JVM | ⚠️ → ✅ **已实施（范围受限）** | 已支付（P1-2） | 中（导入期转译约 10 s/站点，之后命中缓存） | 小（dex2jar 2.4.28 + asm 共 17 个 jar，随 `lib/` 入库） | ⚠️ **仅限不碰 Android UI 的站源**，边界见 §3.4。旧结论「❌ 仅适合逆向分析」指「普遍可用」的判据，已被 §3.4 取代 |
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

### 3.4 方案 B 的实施边界（P1-2）

**本节取代 §3 表格里对 B 的旧结论。** B **已实施**，但它不是「支持 Android 站源」的通行证，
而是一条**范围被收窄的补充通路**：dex 路线补上一条通路，**单个站源能否使用仍以实际测试为准**
（与 `PRODUCT.md` 的口径一致）。

#### 3.4.1 实现了什么

| 组成 | 位置 | 做法 |
| --- | --- | --- |
| dex→class 转译 | `sidecars/spider-host-jvm/src/webhtv/spider/DexIntake.java` | dex2jar **2.4.28**（`lib/` 内 13 个 jar 闭包入库）把 `classes.dex` 转成 class，再用 asm 9.x 以 `COMPUTE_FRAMES` **重算栈帧**（dex2jar 2.4.28 产出的 StackMapTable 与真实字节码不一致，JVM 校验器会以 `VerifyError` 拒绝加载） |
| 转译产物缓存 | `<站点目录>/dexBundles/classes.jar` + `intake-dex.json` | 以源 jar 的 SHA-256 为键；源没变时第二次调用只读记录（实测约 36 ms），不重复转译 |
| 导入期预转译 | `lib/services/dex_translate.dart` → `webhtv.spider.DexIntakeCli` | 导入时就转一次，避免约 10 s 的转译叠进 `initialize` 的 15 s 握手；CLI 的 stdout 只有一行 JSON，`stage` 取 `dex-读取`/`dex-转译`/`dex-帧修复`/`dex-落盘` |
| Android 垫片 | `sidecars/spider-host-jvm/src-android-shim/`（38 个源文件 / 51 个 class，随 `host.jar` 分发） | 自写 `android.content.*`（`Context`/`SharedPreferences`）、`android.util.Base64`/`Log`、`android.os.*`、少量 `android.graphics.*`/`android.view.*`，以及 `com.github.catvod.crawler.Spider` 基类 |
| ABI 适配 | `src/webhtv/spider/CatVodSpiderAdapter.java` | CatVod 风格站源的方法返回 **JSON 字符串**（TVBox 约定），基类 `webhtv.spider.Spider` 的 ABI 是 **Map**；适配器反射调用后把 JSON 解析成 Map，只翻译方法名与取值形态，不做业务解释 |
| 入口接线 | `src/webhtv/spider/EntryLoader.java`（第 5 种入口形态） | 含 `classes.dex` 的 jar 先经 `DexIntake` 转译，类路径只放**转译产物**（原 jar 里只有 dex，`URLClassLoader` 只会把它当资源） |

P1-2 的实测事实：转译 **1227 个类**、帧修复 **1227 成功 / 0 失败**；垫片 **51 个 class** 已打进
`host.jar`；真实站点 `AList`（真实 dex + 真实 `host.jar` + 真实 ext）`initialize` 成功并返回
真实分类列表与搜索结果（退出码 0）；依赖 UI 的站点（如 `Media`）被**明确拒绝**并点名缺失的
Android 类（退出码 3）。

#### 3.4.2 当初为什么判不可行，这次为什么可行

- **当初的判据（§1.1 表第 2 行）判断的是「普遍可用」**：现代 dex 特性（`invoke-custom`、
  默认方法、混淆）会破坏转译；垫片需覆盖 `SharedPreferences`/`Base64`/反射/资源，成本不封顶；
  已有先例（`johnsonlee/testpilot`）只用于测试。**这条判据本身没有被推翻。**
- **P1-2 的应对是「把命题改小」，不是证伪判据**：把支持范围**收窄到不碰 Android UI 的站源**；
  垫片只覆盖目标站点的**实测可达闭包**，不为「未知站源可能用到什么」预付成本；闭包之外的
  一律**明确拒绝并点名**。代价是**不能承诺支持所有 dex**，收益是这条通路在限定范围内真的可用。

#### 3.4.3 明确边界（本节的核心价值，逐条生效）

1. **只支持不碰 Android UI 的站源。** 依赖 `android.app.*` / `android.widget.*` /
   `android.webkit.*`，以及垫片未覆盖的 `android.view.*` 类型的站源，在 PC 端**明确拒绝**：
   加载阶段抛 `NoClassDefFoundError`，适配器把它包成可读结论并**点名缺失的 Android 类**
   （如 `android/widget/TextView`），**不静默降级**、不返回空列表。垫片只为少数与播放控件
   相关的类型提供 `android.view.*` 空壳，**那不等于支持 UI**。
2. **含原生库（`lib/*.so`）的 jar 仍然拒绝。** dex 转译只改字节码形态，不解决 native 实现，
   且判定顺序上**原生库的拒绝优先于 dex**（`lib/services/jar_intake.dart`），入口不落盘。
   原纪律不变。
3. **类不在随包 dex 里的站源无效**（如 `Nostr` / `DanmakuSpider`）：站源在运行时另行取代码，
   dex 转译对它们没有输入。
4. **`invoke-custom` / 混淆过的 jar / 更新版本的 dex 未验证**，因此**不得承诺「支持所有 dex」**。
5. **转译产物与站点 ext（含 token/secret）不得提交入库**：`dexBundles/` 是运行时缓存。
6. **只支持 `dex2jar` 能产出 JVM 可校验字节码的场景。** 帧修复失败**不阻断**转译：该类原样
   保留并记一条 `dex-帧修复` 日志，成功/失败计数写在日志里，不为失败伪造成功。

#### 3.4.4 与 ADR 其它决策的关系

- **D 方案（桌面 JVM ABI）仍是主路线**（§5）：无 Android Context 的桌面 jar 直接映射 `jvm`。
- **B 是补充路径**：仅在「入口是含 dex 的 jar」时启用，不改变 D 的加载语义，也不引入新 ABI
  （仍走 `tvbox-java-v1` 与 §9.4 六路由）。
- **A1/A2（Android 运行时/模拟器）仍未实施**，本 ADR **不改其结论**（§2.1、§3.1–§3.3 照旧）。
- **对外表述约束不变**（§6）：只能说「dex 路线补上一条通路，单个站源能否使用仍以实际测试为准」，
  **不得声称「支持 Android 站源」**。

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
| 入口加载 | `src/webhtv/spider/EntryLoader.java` | 支持 `.jar` / 类目录 / `.java` / 源码目录 / **含 `classes.dex` 的 jar**（先转译再加载，见 §3.4）五种入口形态 |
| 主程序接线 | `lib/services/spider_registry.dart` | `runtime=jvm*`/`java*` → `java -Xmx… -jar host.jar …` |
| `csp_*` 映射 | `lib/services/spider_router.dart`（`CspJvmBinding`） | `csp_<类名>` → 本地缓存的入口（桌面 jar 或类目录）；含 `classes.dex` 的入口走 §3.4 的 dex 通路——可转译（无原生库）则预转译后加载，含原生库/不可转译/损坏则明确报不支持 |
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
`jvm` 运行时，但只接受**无 Android Context 的桌面 jar**；含 dex 的入口另走 §3.4 的方案 B 通路。

## 6. 后果

- **正面**：给出了一条**真实可行**的 Android jar 兼容路径，且不破坏既定架构与 §5.6 结论；
  用户在有需求时可显式开启，代价与风险被明确披露。
- **负面**：兼容层不是零成本——主要成本在自建桥接 APK；且受 ARM 转译与冷启动限制，
  不能承诺「全部 Android jar 可用」。
- **对外表述约束**（沿用 §3.3）：只能说「支持 WebHTV / TVBox / 猫源配置协议和 Spider
  运行时；单个站源能否使用，以实际测试通过为准」。**不得承诺兼容全部 TVBox/猫源**。
