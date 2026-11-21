# spider-host-jvm — 桌面 JVM Spider 宿主（`tvbox-java-v1`）

设计文档 §9.3、§9.7、§9.8、§9.9；架构决策 [ADR-0002](../../docs/adr/0002-android-csp-jar-compat.md)。

本目录是 `webhtv-ipc-v1` 的第四份宿主实现（前三个：`spider-host-python`、`spider-host-js`、
主进程内 CatSpider HTTP）。它让**无 Android Context 的桌面 Java 站源**能在 PC 版运行。

## 1. 它做什么、不做什么

**做**：用纯 JDK 起一个 sidecar 进程，通过 stdio 上的 `webhtv-ipc-v1` JSON-RPC 帧把
`home/category/detail/search/play` 暴露给主程序；站源在独立进程内运行，崩溃/超时/内存
超限只影响该站点（§9.8）。

**不做**：**不运行依赖 Android UI 的站源**。Android `csp_*.jar` 里是 `classes.dex`，JVM 不能
直接执行；本宿主把**不含原生库**的 dex 在导入期转译成 class jar 后加载（ADR-0002 §3.4），
依赖 `android.app.*`/`android.widget.*`/`android.webkit.*` 等垫片未覆盖类型的站点在加载阶段
**明确拒绝并点名缺失的类**，而不是启动后崩溃。Android 兼容层（模拟器/容器）是另一条
**默认关闭**的可选路径。

**垫片覆盖的是「jar 源路径真正链接到的成员」，不是整个 Android API**：jar/dex 源在方法体里
引用 `android.net.Uri`、`android.util.Pair`、`android.util.LruCache`、`android.os.Build`、
`android.os.Bundle`、`android.os.SystemClock` 时，缺类会让 `NoClassDefFoundError` 在**解析
该方法**的瞬间抛出；站源自己的 `try/catch` 一吞，用户看到的就是「首页 0 条目」而不是缺类。
这六个类已按公开 API 子集补齐（范围与取舍见 §7），并由 `spiders/shimprobe/` 这个验收工件
逐项真实调用（`manifests/shimprobe.json`）。

## 2. 构建

```powershell
pwsh -File sidecars/spider-host-jvm/build.ps1
# 产物：sidecars/spider-host-jvm/host.jar（约 46 KiB）+ sidecars/spider-host-jvm/lib/（17 个 jar，约 2.47 MiB）
```

- **依赖已入库，构建仍不需要联网**：`lib/` 下 17 个 jar（dex2jar 2.4.28 闭包 13 个 +
  asm 9.x + gson + org.json + okhttp + okio）随仓库入库，构建只用 JDK 自带的
  `javac` / `jar`，不下载 Gradle/Maven 依赖（§20.5）。许可与来源逐项登记在
  `lib/THIRD-PARTY-NOTICES.md`（均为 Apache-2.0 / Public Domain，可随包分发）。
  `lib/` 缺件时构建会失败，而不是自动联网补。
- **`host.jar` 必须与 `lib/` 一起分发**：`host.jar` 的 MANIFEST 用 `Class-Path` 指向
  `lib/*.jar`（相对路径），单个 `host.jar` 拷走会缺少 dex2jar/asm 而无法转译。
- `--release 17` 固定字节码版本：需要 **JDK 17+**（不是 JRE）。构建脚本从 `javac`
  反推 JDK 并**显式校验主版本 >= 17**；本机 PATH 上的 `java` 是 JRE 8，构建不会用它。
  源码入口（`.java`）还需要 `javax.tools` 编译器，所以必须用 JDK。
- 中间产物落在 `.build/`，构建结束自动清理，仓库里只留 `host.jar` 与 `lib/`。
- 构建自检：`lib/` 每个 jar 存在、字节数符合清单、能被当 jar 打开、
  `THIRD-PARTY-NOTICES.md` 已登记；`host.jar` 的 `Main-Class` 与 `Class-Path` 逐条核对
  （`Class-Path` 里的每个 jar 在磁盘上必须存在）。
- `host.jar` 提交入库：体积小，避免每个开发者都要先装 JDK 才能跑测试。
- **dex 预转译 CLI 复用同一批入库依赖**：导入期调用的 `webhtv.spider.DexIntakeCli` 与 sidecar
  一样按 `-cp "host.jar;lib/*"` 组类路径（dex2jar / asm 都在 `lib/`），因此它同样离线可用，
  `lib/` 缺件时转译失败而不是联网补。

## 3. 运行

```powershell
java -Xmx128m -Xms16m -jar host.jar `
  --entry spiders/fixture/FixtureSpider.java `
  --manifest manifests/fixture.json
```

| 参数 | 说明 |
| --- | --- |
| `--entry` | 站源入口：`.jar` / 类目录 / `.java` / 源码目录 |
| `--manifest` | manifest JSON；提供 `capabilities`/`limits`/`config` |
| `--class` | 全限定类名；缺省时依次取 manifest 的 `config.className`、`key`（去 `csp_` 前缀） |

类名解析顺序：`--class` → `config.className` → `key`（去 `csp_` 前缀）→ 报错。

退出码：`0` 正常（stdin EOF 或 `destroy`/`shutdown`）；`2` 协议/manifest/入口非法；
`3` 站源初始化失败。

### `-Xmx` 必须显式给出

主程序用 Windows 作业对象把 sidecar 内存限制为 manifest 的 `limits.memoryMiB`
（默认 256 MiB），这是**硬限制**。而 JVM 默认按物理内存的 1/4 预留堆（本机实测
640 MiB），在 256 MiB 作业内会直接 `os::commit_memory failed (DOS error 1455)` 退出，
表现为「sidecar 启动即崩」。

因此主程序按 manifest 推导堆参数（`LocalSpiderCommand.jvmHeapFlags`）：
`-Xmx{memoryMiB/2}`、`-Xms{heap/8}`、`-XX:MaxMetaspaceSize={memoryMiB/4}`、
`-XX:MaxDirectMemorySize={memoryMiB/8}`。手工调试时请照此加参数。

## 4. 写一个桌面 JVM 站源

继承 `webhtv.spider.Spider`，实现需要的能力；也可以直接实现 TVBox 风格的方法名，
基类会自动桥接：

| 协议方法（§9.3） | TVBox 风格钩子 |
| --- | --- |
| `home(filter)` | `homeContent(filter, ctx)` |
| `homeVod()` | `homeVideoContent(ctx)` |
| `category(id, page, filter, extend)` | `categoryContent(tid, pg, filter, extend, ctx)` |
| `detail(ids)` | `detailContent(ids, ctx)` |
| `search(keyword, quick, page)` | `searchContent(key, quick, page, ctx)` |
| `play(flag, id, vipFlags)` | `playerContent(flag, id, vipFlags, ctx)` |

约定：

- `capabilities()` 声明能力；**manifest 优先**，站源自报能力不得超出 manifest（§9.7）。
  未声明的方法返回 `SPIDER_UNSUPPORTED`。
- 耗时操作要周期性调用 `CallContext.checkCancelled()`，否则取消/超时无法生效。
- 只返回协议结构（`class`/`filters`/`list`/`vod_*`/`url`/`header`），**不要碰 stdout**；
  日志走 stderr（`Ipc.log`）。
- 只依赖 JDK 标准库。需要 JSON 时用自带的 `webhtv.spider.Json`。

最小示例见 `spiders/fixture/FixtureSpider.java`（用 `HttpURLConnection` 访问本地
fixture 服务，覆盖五个方法）。

## 5. 错误码

与 `webhtv-ipc-v1` 契约一致（§9.5）：

| 码 | 触发条件 |
| --- | --- |
| `SPIDER_INIT_FAILED` | 入口/manifest 非法，站源无法构造 |
| `SPIDER_UNSUPPORTED` | 方法未在 manifest `capabilities` 中声明 |
| `SPIDER_BAD_REQUEST` | 参数非法（如 `search` 缺 `keyword`） |
| `SPIDER_PARSE_ERROR` | 站源抛出的其它异常 |
| `SPIDER_CANCELLED` | 收到 `$/cancelRequest` / `$/cancel` |
| `SPIDER_RESOURCE_LIMIT` | 帧/响应超限 |

## 6. 门禁

```powershell
# 单元测试（真实 JVM 子进程：握手/五方法/取消/崩溃隔离/EOF 排空）
puro -e webhtv -p . flutter test test/phase3_jvm_spider_test.dart

# 集成测试（真实窗口 + 真实 JVM 侧车 + csp_* 映射）
puro -e webhtv -p . flutter test integration_test/jvm_spider_flow_test.dart -d windows

# 一键验收（含 jvm-host-preflight：host.jar + JDK 17+ + 真实握手）
pwsh -File tools/phase3/run_windows_acceptance.ps1
```

## 7. 已知边界

- **Android jar 只在受限范围内支持**（`classes.dex`）。见 ADR-0002 §3.4。
  `webhtv.spider.DexIntake` 把含 `classes.dex` 的站源 jar 转成
  `siteDir/dexBundles/classes.jar`（带 ASM 帧修复与 SHA-256 缓存），且**已接入
  `EntryLoader`**：`--entry` 传含 dex 的 jar 时，进类路径的是**转译产物**而不是原 jar
  （`EntryLoader.load` 的第五种入口形态）。仍被拒绝的是含 `lib/*.so` 原生库、dex 不可
  转译、以及入口损坏的 jar——主程序侧静态检测（`jar_intake.dart`）在导入期先给出结论，
  含原生库的入口不落盘。
- 转译很慢（本机实测单次约 10–12 s / 1227 个类，dex 1.5 MiB），且需要额外内存；
  产物按源 jar 的 SHA-256 缓存在站点目录的 `dexBundles/intake-dex.json`，源没变时
  第二次调用只读记录（实测约 36 ms），不会重新转译。
- **P1-2 边界：只支持不碰 Android UI 的站源**。依赖 `android.app.Dialog` / `android.app.Activity` /
  `android.widget.*` / `android.view.*` 等 UI 类型的站源在 PC 端不可用：`src-android-shim/` 不提供
  这些类，加载时**明确拒绝并点名缺失的 Android 类**（`NoClassDefFoundError: android/widget/...`），
  不静默降级。唯一例外见下表的 `android.app.Application`：它是壳/载荷在**加载期**就要解析的名字
  （`InitOrigin` 的字段与 `checkcast`），垫片只提供非 UI 的最小面，行为全是 no-op。
  量化口径（`.probe/wex/site2`，1227 个类）：补 `Application` 与 `DialogInterface` 三型前后
  `--selfcheck` 的 `failed` 从 31 降到 22，剩下的 22 条**全部**是 `android/widget/*`、
  `android/view/View$On*Listener`、`android/app/Dialog`、`android/graphics/drawable/*`、
  `android/text/TextWatcher` 这类真正的 UI 类型。
  支持范围是纯逻辑站源（HTTP/JSON/正则解析、`com.github.catvod.crawler.Spider` 子类）。
- **jar 源路径的垫片清单（android.*，语义取自公开文档，独立实现）**：

  | 垫片类 | 覆盖的成员 | 刻意不声明（见各类文件末尾登记） |
  | --- | --- | --- |
  | `android.net.Uri` | `parse/toString`、`getScheme/getAuthority/getUserInfo/getHost/getPort`、`getPath/getEncodedPath/getLastPathSegment`、`getQuery/getEncodedQuery/getQueryParameter/getQueryParameterNames`、`encode/decode`、`isOpaque`、`equals/hashCode`（按 URI 字符串）、`Uri.Builder`（`scheme/authority/encodedAuthority/path/appendPath/query/appendQueryParameter/fragment/clearQuery/build`） | `Parcel`/`File`/`ContentResolver` 相关 |
  | `android.util.Pair` | 全部（`first/second/create/equals/hashCode`；`toString` 为桌面侧排障补的、AOSP 没有） | 无 |
  | `android.util.LruCache` | `sizeOf/entryRemoved/create` 钩子 + `get/put/remove/trimToSize/evictAll` 与全部计数器、`snapshot/toString` | `resize` 等新近成员 |
  | `android.os.Build` | 声明面常量 + `Build.VERSION`（`SDK_INT=34`）+ `getSerial/getRadioVersion` | `SUPPORTED_ABIS` 一族（桌面无诚实取值）、`getString`、`VERSION_CODES` |
  | `android.os.Bundle` | `Map` 支撑：`put*/get*` 对 String/int/long/boolean/float/double/CharSequence/StringArrayList/CharArray/Serializable、容器方法与拷贝构造；key 缺失才回落默认值，**类型不符一律 `ClassCastException`** | `Parcelable`/`Parcel`/`Bundle` 嵌套包、数组族其余成员、`clone` |
  | `android.os.SystemClock` | `uptimeMillis/elapsedRealtime/elapsedRealtimeNanos/currentThreadTimeMillis/sleep` | `setCurrentTimeMillis`、`currentGnssTimeClock` |
  | `android.app.Application` | `extends Context`（AOSP 的中间层 `ContextWrapper` 不提供）、`getApplicationContext()` 返回自身、`getPackageName()` 固定 `webhtv.spider.host`、`register/unregisterActivityLifecycleCallbacks`（no-op，注册时打一条 stderr） | 全部真机能力；`ContextWrapper`、`attachBaseContext`、`onCreate/onTerminate/onConfigurationChanged`；`Context` 的存储访问器（`getSharedPreferences/getFilesDir/getCacheDir/getSystemService`）一律抛 `UnsupportedOperationException`——桌面端没有 base Context，返回 null 会让站源以为「读到了空配置」 |
  | `android.app.Application$ActivityLifecycleCallbacks` | 只声明**类型本身**（空接口），让实现它的载荷类（`InitOrigin$1`）能加载 | AOSP 那 7 个回调（`onActivityCreated/Started/Resumed/Paused/Stopped/SaveInstanceState/Destroyed`）**全部**以 `android.app.Activity` 为参数，本垫片不伪造 Activity，一个都不声明（理由登记在类注释） |
  | `android.content.DialogInterface` | `cancel()`、`dismiss()`、`BUTTON_POSITIVE/BUTTON_NEGATIVE/BUTTON_NEUTRAL` | `OnKeyListener`（需要 `KeyEvent`，不在本批次文件清单内）、`OnClickListener/OnMultiChoiceClickListener/OnShowListener` |
  | `android.content.DialogInterface$OnCancelListener` | `onCancel(DialogInterface)`（签名完整） | 无 |
  | `android.content.DialogInterface$OnDismissListener` | `onDismiss(DialogInterface)`（签名完整） | 无 |

  三处非显然的设计：

  - `Uri.buildUpon()` 存在**两个重载**（`()Landroid/net/Uri$Builder;` 与 `()Landroid/net/Uri;`）。
    原因：旧字节码按后者链接，而 bridge 方法只能由协变覆写产生，所以 `Uri` 继承包内可见的
    `android.net.LegacyUriBuilderApi`（声明返回 `Uri`），用 `Uri.Builder buildUpon()` 覆写，
    并让 `Uri.Builder extends Uri`。`build.ps1` 因此同时断言三个类都在 host.jar 内。
  - `Build` 的常量是**桌面载体声称的 SDK 34**，不是真机：型号固定 `WebHTV-Desktop-JVM`，
    序列号/基带为 `unknown`，`SUPPORTED_ABIS` 一族宁可不声明也不编造 Android ABI 名。
  - `Bundle` 把「key 缺失」与「类型不符」严格分开：缺失才回落默认值，类型不符**即使走带默认
    值的重载也抛** `ClassCastException`（AOSP 是先强转后回落，CCE 在判断 null 之前）。与 AOSP
    的唯一差异是不打那条 `Log.w`：垫片宁可让站源的打包/解包类型错误当场暴露，也不要静默
    变成默认值。

  验收方式（真实 sidecar 进程、真实 home 调用；六项探测全部通过才算过）：

  ```powershell
  java -Xmx128m -Xms16m -jar host.jar --entry spiders/shimprobe/ShimProbeSpider.java --manifest manifests/shimprobe.json
  ```

  探针站源不写任何兜底 `catch`：任一垫片类缺失都会让宿主回一个带类名的错误信封
  （`NoClassDefFoundError: android/os/Bundle` 落在 `error.message` 里，实测 code 为 `SPIDER_PARSE_ERROR`），
  不会被吞成空列表。
- **dex 预转译只在导入期做一次**：宿主在导入 dex jar 时就调用下面的 CLI 把产物落盘，之后
  sidecar 加载同一站点时 `DexIntake.translate` 直接命中缓存（本机实测首次 3516 ms、二次
  252 ms，均含 JVM 启动），9 s 级的转译耗时不会叠进 `initialize` 的 15 s 握手。
  产物缓存在 `<站点目录>/dexBundles/`（`classes.jar` + `intake-dex.json`），是**运行时缓存，
  不要提交入库**。

  ```powershell
  java -cp "host.jar;lib/*" webhtv.spider.DexIntakeCli --site <站点目录> [--archive <jar 路径>] [--selfcheck]
  ```

  也接受 `--site=<值>` / `--archive=<值>` 形式。`--archive` 缺省时按 Dart 侧
  `JarIntake._entryIn` 的顺序取入口：先 `<站点目录>/index.jar`，再该目录下唯一的 `.jar`
  （有多个 jar 时拒绝猜测，要求显式 `--archive`）。stdout **只有一行** JSON——成功
  `{"ok":true,"bundle":..,"classCount":..,"cached":..,"sourceSha256":..,"archive":..,"repairedClasses":..,"stubbedMethods":..,"retargetedCalls":..,"retypedInstantiations":..,"records":[..],"selfcheck":{..}}`
  （`selfcheck` 只在 `--selfcheck` 时出现，见下节），
  失败 `{"ok":false,"stage":..,"message":..}`（`stage` 取 `dex-读取`/`dex-转译`/`dex-帧修复`/
  `dex-修复`/`dex-落盘`）；stderr 是给人看的日志，退出码 `0` 成功 / `1` 失败。

### dex2jar 语义修复（`DexRepair`）

帧修复只让产物**能过校验器**，不保证**语义正确**：混淆过的 dex 会踩到 dex2jar 的误译，产物看着
能加载、一用就崩。`DexRepair` 排在帧修复之后、落盘之前，只按**原始 `classes.dex` 的事实**改字节码：

| 误译 | dex 的事实 | 后果 | 修法 |
| --- | --- | --- | --- |
| `new` 类型误译 | `new-instance Lf;`（产物写成 `NEW g`，g 是 f 的某个祖先） | 执行到该处 `InstantiationError`/`IncompatibleClassChangeError`（对象身份不对，接口判断直接崩） | 把 `NEW` 的类型改成 dex 里的真实类型 |
| 伪 abstract 类 | 该类在 dex 中非抽象、且有实现 | `InstantiationError`（只在 `new` 它时才炸） | 清类/方法的 `ACC_ABSTRACT`，方法补**显式失败**桩体 |
| 自递归 `invokespecial` | `invoke-super` | 无限递归 / 半构造对象 | 改指向父类的同名同描述符方法 |

三条都必须「拿不准就不改」：`new` 改类型只接受**收窄**——产物类型是 dex 类型的祖先，且 dex 类型
不是抽象类。对位分两档，**先下标、后描述符链**，两档都失败就整条方法原样保留并记一条（记录里带
两档各自的原因）：

| 档 | 依据 | 什么时候用 |
| --- | --- | --- |
| 下标对位 | 产物的 `NEW` 序列与 dex 的 `new-instance` 序列逐条同序 | 绝大多数方法；判据最强，能过就不换档 |
| 描述符链对位 | 每个 `NEW` 各自配到的**构造器描述符**：dex 侧按寄存器把 `new-instance` 与 `invoke-direct <init>` 配对，产物侧按栈把 `NEW` 与 `invokespecial <init>` 配对 | dex2jar 重排过指令、序号对不上时 |

描述符链档的「唯一」是硬条件，任一不满足就整条方法不动：两侧描述符集合与每组数量必须一致；同一
描述符出现多次时，该描述符下两侧的类型必须各自唯一（否则顺序不可信、目标不唯一，绝不用「猜一个
最像的」）；每处差异仍必须是收窄。实测它救回的正是 `z3/o.a(C)V`：dex 的 `new-instance` 顺序是
a,r,a,r…、产物是 r,a,r,a…，下标档把 `NEW z3/c` 和 dex 的 `z3/r` 配到一起，只能整条方法原样保留，
运行期炸 `InstantiationError: z3/c`；描述符链档按 `()V` 指纹唯一对上 `NEW z3/c → z3/b`（b 是 c 的
具体子类、c 抽象），首页 `homeContent` 才真正跑通。

为什么「祖先 → 具体子类」这一条就够：误译的机制始终是 dex2jar 拿**构造器的声明类**当
`new-instance` 的类型，而声明类必是真实类型的祖先。实测到的三种形态都是它的特例：

1. **抽象父类**：`new-instance Lf;`，构造器声明在抽象父类 g 上 → 产物 `NEW g`；
2. **`java/lang/Object`**：构造器一路解析到 `Object.<init>`（类自己没有构造器）→ 产物 `NEW
   java/lang/Object`，调用方再按接口用它就是 `IncompatibleClassChangeError`；
3. **普通父类**：`new-instance Lw3/a;` + `invoke-direct Ljava/lang/ThreadLocal;-><init>`，`w3/a`
   继承 `ThreadLocal` 的构造器 → 产物 `NEW java/lang/ThreadLocal`；这类如果漏掉，运行期表现为
   `ThreadLocal.get()` 返回 `null`（`w3/a.initialValue` 根本没被调到），一路 NPE 到看不出根因。

因此方法筛选也不能按「NEW 的类型可疑」筛：误译后的类型可以是任何类。现在凡是产物的方法里含
`NEW`，就把该方法的 dex `new-instance` 序列读进来对位（先下标档、失败再描述符链档；本仓真实
5.6 s，与只筛「可疑类型」时无可见差别——多的那几毫秒远小于一次误判的排查成本）。
伪 abstract 的桩体一律 `throw new UnsupportedOperationException("dex2jar 未能转译 <owner>.<name><desc>")`，
**不生成返回默认值的桩**——那会把「编译失败」变成「静默跑错」。父类不在 dex 里（如 `android.*`）
时一律不重定向。

报告字段（CLI 单行 JSON 与 `intake-dex.json` 同口径，宿主如实上报）：

| 字段 | 含义 |
| --- | --- |
| `repairedClasses` | 字节码被改动过的类数（任一类修复命中即计一次） |
| `stubbedMethods` | 补了「显式失败」桩体的方法数（本仓真实 payload 实测 0：它没有伪 abstract 方法） |
| `retargetedCalls` | 重定向到父类的 `invokespecial` 数 |
| `retypedInstantiations` | 改成 dex 真实类型的 `NEW` 数 |
| `records` | 逐条修复/跳过原因（上限 1000 条，超出留一条截断说明；真实 payload 一次约 650 条，200 条会把「跳过原因」挤掉） |

`intake-dex.json` 里的 `repairVersion` 是**产物口径**：修复规则一变就必须升它，旧缓存（SHA 相同、
字段缺失）随之失效并重新转译，否则修复永远跑不到真实 payload 上。当前口径是 `3`（新增「描述符链
对位」：下标对不上时按构造器描述符重新配对，判据仍是收窄）。

### 导入期自检（`--selfcheck`，默认关闭）

```powershell
java -cp "host.jar;lib/*" webhtv.spider.DexIntakeCli --site <站点目录> --selfcheck
```

转译完成后另起**一个独立的一次性 JVM**（同一 `host.jar`+`lib/*`、`-noverify`、超时 60 s），对产物
逐个类做 `Class.forName(name, false, loader)`，把「这份 payload 还剩多少坑」变成可数的清单：

```json
"selfcheck":{"classes":1193,"failed":31,
  "counts":{"VerifyError":0,"IncompatibleClassChangeError":0,"NoClassDefFoundError":31,"UnsupportedClassVersionError":0,"other":0},
  "failures":[{"class":"com.github.catvod.spider.InitOrigin$1","error":"NoClassDefFoundError","message":"android/app/Application$ActivityLifecycleCallbacks"}]}
```

| 字段 | 含义 |
| --- | --- |
| `classes` | 产物里的类数（与 `classCount` 同口径） |
| `failed` | 加载失败的类数；**`-1` 表示自检本身没跑成**（起不来/超时/没产出），与「跑成了、0 失败」严格区分 |
| `counts` | 按异常简单类名分桶的计数：`VerifyError` / `IncompatibleClassChangeError` / `NoClassDefFoundError` / `UnsupportedClassVersionError` / `other` |
| `failures` | 前 20 条 `{class, error, message}`（消息截到 240 字符）；总数看 `failed` |
| `error` | 只在自检没跑成时出现，说明原因 |

三条边界，刻意留着：

- **只加载类**：`initialize=false`，静态块一行不跑；不实例化、不调用 `init`/`homeContent`，因此
  **不联网、不碰站源业务状态**，读数可复现；
- **独立进程**：站源的类在宿主进程里只有一次被加载的机会，探针必须是一次性的；且与真实 sidecar
  同一口径（同一类路径、同样 `-noverify`）；
- **`-noverify` 的取舍**：校验器被关掉，所以 `VerifyError` 基本上恒为 0——这一桶是留给「校验之外的
  链接错误」的兜底，不要把它读成「字节码一定过得了校验器」（去 `-noverify` 的真实边界见 §7 的
  `-noverify` 那条）。

自检整轮实测只多 0.4 s（1193 个类，5.6 s → 6.1 s），可以常开在导入期。

自检失败**不影响** `ok`：转译本身是成功的，失败信息只进 `selfcheck.error`。宿主可以把它当「产物
可信度」的量化基线——`failed` 里全是 `NoClassDefFoundError` 说明缺的是垫片（`src-android-shim/`），
出现 `IncompatibleClassChangeError` / `VerifyError` 则说明还有 dex2jar 的语义坑没修。
- **转译产物仍需要父类垫片**：`com.github.catvod.crawler.Spider`、`android.content.Context`
  等不在站源 jar 内，来自 `src-android-shim/`；只把产物加进类路径会得到
  `NoClassDefFoundError`（垫片就位后实测可正常加载 + 强制链接）。
- 源码入口（`.java`）在首次启动时要编译，冷启动比 `.jar` 慢（本机约 1.5 s）；
  发行包应提供 `.jar` 形态。
- `JAVA_HOME` 不在 sidecar 环境白名单内（§9.8），因此主程序用绝对路径启动 `java.exe`。
  主程序会探测候选并**校验版本**：实测本机 PATH 上 `jre1.8.0_501` 排在 JDK 21 之前，
  只取第一个会拿到 Java 8 并因 `UnsupportedClassVersionError` 启动即崩。
  同理，`DexIntake` 起 dex2jar 子进程时只用 `java.home` 推导出的 `java`，绝不查 PATH。

- **语义修复后仍可能需要 `-noverify`**：dex 允许「`new-instance Lf;` + `invoke-direct Lg;-><init>`」
  （f 继承 g 的构造器），JVM 校验器不允许对 `new f` 调父类 `<init>`，而补一个转发构造器属于改写
  类形态，故不自动生成。本仓真实 payload（wex 加固壳）实测：`-noverify` 下 `initialize`/`home`
  均能真实执行；去掉 `-noverify` 会在 `<init>` 处 `VerifyError`（与修复前的 `Bad type on operand
  stack` 同属「产物不能过校验器」这一类）。
- **对位不上的 `new` 不改**：大方法里 dex2jar 会重排指令，`NEW` 与 `new-instance` 序列对不上时
  保持原样并在 `records` 里点名。真实 payload 里这类方法仍是**已知未修项，且其中一条在热路径上**：
  `z3/o.a(C)V`（dex 是 `new-instance Lz3/b;`，产物是 `NEW z3/c`，c 是 b 的父类）——它让 wex payload
  的 `homeContent` 在 `-noverify` 下抛 `InstantiationError: z3/c`（c 在 dex 里是抽象类）。修它需要
  「按构造器调用对齐」而不是按下标对位，属于下一轮的事；在没有对位校验之前，一律不动。
- **`NEW Object` 与接口身份**：`IncompatibleClassChangeError: Class java.lang.Object does not
  implement ...` 就是本类误译在运行期的样子（`OkHttpClient$Builder.sslSocketFactory` 那条链）。
  `retypedInstantiations` 里「`NEW java/lang/Object → 具体类`」的条数就是这一类坑已被修掉的数量。
## 8. 加固壳解包（shell-unpack）

wex/shinidie 这类加固壳 jar 不能直接喂 DexIntake：真正的 payload 被一个 native 解密器
（`assets/*.so`）在运行期流式还原，加密体放在 `assets/*.guard`。`shell-unpack/ShellUnpack.java`
用 unidbg 跑那段 native，一次性把壳 jar 解成普通 payload jar。

**为什么是单文件源码模式**：unidbg（约 40 MB）是用户机器上按需下载的运行时，不入库、构建不
联网，所以解包器不能在编译期依赖 unidbg——只能由 JDK 源码启动器在运行期用 `-cp` 把它带进来。

```powershell
java -cp "<unidbg-dir>/*" sidecars/spider-host-jvm/shell-unpack/ShellUnpack.java --shell <壳jar> --out <payload.jar> [--work <临时目录>] [--timeout <秒>]
```

- `-cp` 里是通配符，由 JVM 自己展开；`.java` 由源码启动器现场编译并运行（JDK 21）。
- `--work` 缺省在系统 temp 下自建、结束时清理；显式给出则保留（排障用）。
- `--timeout` 是整次解包的兜底秒数（默认 300），超时按 `解包-调用` 失败收场。

配方 `wex-shinidie`（spike 实证，细节见 `.probe/wex/SPIKE-RESULT.md`）：

1. 读壳 jar：取 `assets/*.guard`（加密体）与 `assets/*.so`（native 解密器，优先 ELF64 AArch64
   `e_machine=0xB7`，缺失时退 ELF32 ARM `0x28`）；`.guard` 不是恰好一个就拒绝猜测。
2. unidbg `AndroidEmulator` + `DalvikVM` 加载该 `.so` 并执行 `JNI_OnLoad`；hook `JNIEnv` 函数表
   第 215 项（`RegisterNatives`），必须看到 `proxyInvoke`/`getSpider`/`getLoader` 三个方法。
3. 造一个假 `android.content.Context`：`getCodeCacheDir()` 指 `<work>/codecache`、
   `getClassLoader().getResourceAsStream("assets/<name>.guard")` 指真实加密文件、
   `File.setReadOnly()` 必须返回 `true`（返回 `false` 时 native 会回滚并删掉刚写好的 payload）。
4. 调 `DexNative->getLoader(Context)`，native 把解密结果流式写到 `<work>/codecache/sharedb/config.db`。
5. 校验该文件是 zip 且含 `classes.dex`，再 `.part` → rename 落到 `--out`；失败时**不留** `--out`。

`recipe-识别` 并说明原因。

### 装配约定：壳 jar 作入口 + payload.jar 同目录

解包出来的 payload **不能**直接当站点入口，也不能当唯一产物：站点入口必须是**壳 jar**，
payload 另存同目录的 `payload.jar`。理由来自壳的加载链（`javap` 实证）：

```text
WexHanXiaoQuanGuard.<init>            // 站源类，继承 BaseSpiderGuard → com.github.catvod.crawler.Spider
  └ BaseSpiderGuard.<init>
      └ Init.getSpider(this.getClass().getName())    // 传的是**壳类全限定名**
          └ DexNative.getSpider(Init.loader(), name) // Init.loader() 此时是 null
```

- 入口类只存在于**壳 jar** 里；payload 里是 `WexAiHanXiaoQuan` 这类真实现。把 payload 当
  `index.jar` 会让宿主在 `com.github.catvod.spider.XxxGuard` 上 `ClassNotFoundException`（侧车
  退出码 3、站点点开是空的），所以 `manifest.json` 的 `config.className` 写**壳入口类**
  （`api` 去 `csp_`，保留 `Guard`）。
- 壳里的 `com.github.catvod.spider.DexNative` 只有三个 native 方法（`getLoader(Object)` /
  `getSpider(Object,String)` / `proxyInvoke(Object,Object)`）。`host.jar` 里编进了一个**同包同名的
  纯 Java 影子类**（`src-android-shim/src/com/github/catvod/spider/DexNative.java`）：站源加载器
  是 parent-first，宿主 loader 先于站源 jar，于是壳的 native 调用全部落到影子实现上，
  连壳的 `static { System.loadLibrary(...) }` 都不会执行。`build.ps1` 对
  `com/github/catvod/spider/DexNative.class` 有断言，缺了它壳站点会在 `UnsatisfiedLinkError`
  里被壳自己的 `catch` 吞成「首页 0 条目」。

目录约定（`<site>/` 由 App 的导入逻辑装配）：

| 文件/目录 | 内容 |
| --- | --- |
| `index.jar` | **壳 jar**（`EntryLoader` 会把它转译进 `dexBundles/`） |
| `payload.jar` | 解包产物（真实样本也是 `classes.dex`） |
| `dexBundles/` | 壳的转译产物（`EntryLoader` 写） |
| `payload-dex/dexBundles/` | payload 的转译产物（`DexNative` 写/读） |
| `manifest.json` | `config.className` = 壳入口类（`XxxGuard`） |

**为什么 payload 的转译产物另放 `payload-dex/`**：壳与 payload 都是 `classes.dex`，而
`DexIntake` 的产物路径固定是 `<站点>/dexBundles/classes.jar`；共用一份会互相顶掉，壳的入口类
就没了。`DexNative` 找不到 `payload-dex/dexBundles/classes.jar` 时会自己转译一次（首次约 5-9 s，
挤在侧车握手窗口里），所以 App 侧导入时先转译（`csp_jar_probe` 的 `_translateStep`）把它挪到
导入期完成。

payload 定位优先级（`DexNative.locatePayload`）：系统属性 `-Dwebhtv.shellPayload=<文件|目录>` →
`Context.root()` 反推的站点目录 → **调用方类的 CodeSource**（`index.jar` 或
`dexBundles/classes.jar` 的上一级）→ `user.dir`。找不到就抛带路径清单的 `IllegalStateException`，
**不返回 null**：壳那边会把空指针吞成「首页 0 条目」。

payload 里的站点实现按「名字对得上」的顺序解析：原样全限定名 → 去 `Guard` → 追加 `Guard` →
**子序列匹配**（壳类名与 payload 类名可能被插进一段，实测 `WexHanXiaoQuanGuard` 的真实现是
`WexAiHanXiaoQuan`，连续子串包含对它无解）→ payload 里恰好只有一个 `Spider` 实现时用它。
子序列命中多个就抛异常并列出候选（不猜）；全部落空抛异常并列出已尝试的类名与 payload 里的
实现清单。
