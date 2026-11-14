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
- **P1-2 边界：只支持不碰 Android UI 的站源**。依赖 `android.app.*` / `android.widget.*` /
  `android.view.*` 等 UI 类型的站源在 PC 端不可用：`src-android-shim/` 不提供这些类，加载时
  **明确拒绝并点名缺失的 Android 类**（`NoClassDefFoundError: android/widget/...`），不静默降级。
  支持范围是纯逻辑站源（HTTP/JSON/正则解析、`com.github.catvod.crawler.Spider` 子类）。
- **dex 预转译只在导入期做一次**：宿主在导入 dex jar 时就调用下面的 CLI 把产物落盘，之后
  sidecar 加载同一站点时 `DexIntake.translate` 直接命中缓存（本机实测首次 3516 ms、二次
  252 ms，均含 JVM 启动），9 s 级的转译耗时不会叠进 `initialize` 的 15 s 握手。
  产物缓存在 `<站点目录>/dexBundles/`（`classes.jar` + `intake-dex.json`），是**运行时缓存，
  不要提交入库**。

  ```powershell
  java -cp "host.jar;lib/*" webhtv.spider.DexIntakeCli --site <站点目录> [--archive <jar 路径>]
  ```

  也接受 `--site=<值>` / `--archive=<值>` 形式。`--archive` 缺省时按 Dart 侧
  `JarIntake._entryIn` 的顺序取入口：先 `<站点目录>/index.jar`，再该目录下唯一的 `.jar`
  （有多个 jar 时拒绝猜测，要求显式 `--archive`）。stdout **只有一行** JSON——
  成功 `{"ok":true,"bundle":..,"classCount":..,"cached":..,"sourceSha256":..,"archive":..}`，
  失败 `{"ok":false,"stage":..,"message":..}`（`stage` 取 `dex-读取`/`dex-转译`/`dex-帧修复`/`dex-落盘`）；
  stderr 是给人看的日志，退出码 `0` 成功 / `1` 失败。
- **转译产物仍需要父类垫片**：`com.github.catvod.crawler.Spider`、`android.content.Context`
  等不在站源 jar 内，来自 `src-android-shim/`；只把产物加进类路径会得到
  `NoClassDefFoundError`（垫片就位后实测可正常加载 + 强制链接）。
- 源码入口（`.java`）在首次启动时要编译，冷启动比 `.jar` 慢（本机约 1.5 s）；
  发行包应提供 `.jar` 形态。
- `JAVA_HOME` 不在 sidecar 环境白名单内（§9.8），因此主程序用绝对路径启动 `java.exe`。
  主程序会探测候选并**校验版本**：实测本机 PATH 上 `jre1.8.0_501` 排在 JDK 21 之前，
  只取第一个会拿到 Java 8 并因 `UnsupportedClassVersionError` 启动即崩。
  同理，`DexIntake` 起 dex2jar 子进程时只用 `java.home` 推导出的 `java`，绝不查 PATH。
