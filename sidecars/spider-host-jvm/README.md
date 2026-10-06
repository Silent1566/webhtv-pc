# spider-host-jvm — 桌面 JVM Spider 宿主（`tvbox-java-v1`）

设计文档 §9.3、§9.7、§9.8、§9.9；架构决策 [ADR-0002](../../docs/adr/0002-android-csp-jar-compat.md)。

本目录是 `webhtv-ipc-v1` 的第四份宿主实现（前三个：`spider-host-python`、`spider-host-js`、
主进程内 CatSpider HTTP）。它让**无 Android Context 的桌面 Java 站源**能在 PC 版运行。

## 1. 它做什么、不做什么

**做**：用纯 JDK 起一个 sidecar 进程，通过 stdio 上的 `webhtv-ipc-v1` JSON-RPC 帧把
`home/category/detail/search/play` 暴露给主程序；站源在独立进程内运行，崩溃/超时/内存
超限只影响该站点（§9.8）。

**不做**：**不加载 Android 站源**。Android `csp_*.jar` 里是 `classes.dex`，只有 ART 能执行，
JVM 无法加载；这类站点会明确报「Android jar，JVM 无法加载」，而不是启动后崩溃
（ADR-0002 §1.1）。Android 兼容层（模拟器/容器）是另一条**默认关闭**的可选路径。

## 2. 构建

```powershell
pwsh -File sidecars/spider-host-jvm/build.ps1
# 产物：sidecars/spider-host-jvm/host.jar（约 33 KiB）
```

- **零第三方依赖**：只用 JDK 自带的 `javac` / `jar`，不下载 Gradle/Maven 依赖，
  因此发行包构建不依赖网络（§20.5）。
- `--release 17` 固定字节码版本：需要 **JDK 17+**（不是 JRE）。源码入口
  （`.java`）还需要 `javax.tools` 编译器，所以必须用 JDK。
- 中间产物落在 `.build/`，构建结束自动清理，仓库里只留 `host.jar`。
- `host.jar` 提交入库：无第三方依赖、体积小，避免每个开发者都要先装 JDK 才能跑测试。

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

- **Android jar 不支持**（`classes.dex`）。见 ADR-0002。
- 源码入口（`.java`）在首次启动时要编译，冷启动比 `.jar` 慢（本机约 1.5 s）；
  发行包应提供 `.jar` 形态。
- `JAVA_HOME` 不在 sidecar 环境白名单内（§9.8），因此主程序用绝对路径启动 `java.exe`。
  主程序会探测候选并**校验版本**：实测本机 PATH 上 `jre1.8.0_501` 排在 JDK 21 之前，
  只取第一个会拿到 Java 8 并因 `UnsupportedClassVersionError` 启动即崩。
