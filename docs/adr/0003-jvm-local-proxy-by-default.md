# ADR-0003：jvm 站源默认获得本机代理授权（对齐安卓 `/proxy`）

- 状态：已接受（2026-11-26）
- 取代：ADR-0002 附录 B 中「`proxyHttp` 只对显式授权加固壳站点启用」的**范围**部分
  （加固壳自动授权的规则保留，jvm 站源改为默认授权）
- 相关：设计文档 §9.4（只实现六个 cat-http 路由）、§9.8（进程隔离）、§11.3（本地代理约束）

## 1. 背景

站点播放数据里的弹幕源常写成安卓那套本机中转：

```
http://127.0.0.1:0/proxy?do=danmu&name=逐玉&episode=1&season=1
```

安卓侧由 `server/process/Proxy.java:42` 把 query 交给 `BaseLoader.get().proxy(params)`，
即**应用收下 `/proxy`，转发给当前站源的 `proxy(Map)`**。PC 侧原本只有加固壳（generated-shell）
站点被自动授权 `localProxy`，普通用户 jar（`runtime=jvm`，如 `热播影视/AppRJ`）的
manifest 是 `localProxy: false`、能力集无 `proxy` → 没有数据面 → 没有会话 →
`SpiderProxySession.scopeUrl` 无从映射 → 请求打到一个不存在的端口，报「网络不可达」。

## 2. 决策

1. `runtime=jvm` 的站源**默认** `permissions.localProxy = true`，并在能力集里声明 `proxy`
   （新装写入默认值；存量由启动迁移 `JarIntake.ensureJvmLocalProxy` 补齐）。
2. `python-catvod` / js 站源**不**授权：它们没有这条数据面，声明了也只会被宿主裁掉。
3. 声明不等于可用：宿主握手时按站源是否真的实现 `proxy(Map)` 重新裁剪能力集
   （`SidecarServer` 的 `supportsProxyHttp()` → `DexNative.proxyMethod != null`）。
   未实现的站源拿不到 `proxy` 能力，数据面不启动。
4. 弹幕地址的映射仍只接管「回环 + `/proxy` + `?do=`」形态（`SpiderProxySession.scopeLocalProxyUrl`）；
   非回环地址、无 `do` 的本机地址一律不动。

## 3. 安全评审

**新增能力**：第三方 jar 可以让应用把它代理的请求经回环数据面 `/s/<token>/proxy` 转发，
并在 `do=…` 上被转发回它自己的 `proxy(Map)`。

**不构成新增网络能力**：这些 jar 的 manifest 本来就是 `network: true`（直接抓取），
代理通道没有给它任何它原本拿不到的出口。

**已有护栏（全部继承，不放松）**：

- 只监听回环；每个播放会话独立高熵 token；随会话撤销 / TTL 过期立即失配；
- 字节与请求数上限、并发上限、清单体积上限；
- 目标策略校验（私网 / 回环 / 链路本地 / 云元数据地址在既有策略里被拒）；
- 日志只记 token 指纹与目标主机，不记 query。

**残余风险**：

1. 数据面与「媒体代理」耦合——同一 token 既可拉媒体也可走 `do=` 动作。缓解：动作最终由
   站源自身实现，应用不实现任何业务动作；token 生命周期与单次播放绑定。
2. 存量迁移会改写用户目录里的 `manifest.json`（仅两个字段）。缓解：只升不降、幂等、
   失败只记 warning 不阻断启动；用户重导站点会得到同样的值。
3. 站源若实现 `proxy(Map)` 但其行为恶意，它能拿到的仍是自己那份网络能力 + 一次回环转发。

## 4. 回滚

把 `JarIntake` 两处 manifest 默认值改回 `false`，并删除/停用 `ensureJvmLocalProxy` 调用；
存量已迁移的站点需把 `localProxy` 改回 false（或删目录重导）。行为上等价于本 ADR 之前的状态：
弹幕等 `/proxy` 动作对普通 jar 不可用。

## 5. 2026-11-27 事故与修复（必读）

首版只改了 Dart 的两处 manifest 默认值 + 启动迁移，真机一跑就**整站崩**：

```
sidecar 意外退出（code=1）：java.lang.IllegalStateException: 代理处理器必须是静态 Object[] 方法
ERROR [site] 详情加载失败 site=热播影视 … SPIDER_CRASHED
```

根因是 JVM 侧两个判定不一致：`DexNative.proxyMethod()` 遇到「非静态 proxy」**抛异常**，
而 `CatVodSpiderAdapter.supportsProxyHttp()` 直接把它透传给能力协商 → 进程在协商阶段被打死。
普通用户 jar（如 `AppRJ`）的 `proxy` 不是静态方法，所以一授权就炸。

修复：`supportsProxyHttp()` 捕获该异常并返回 `false`（非静态 proxy = 不支持流式代理，
不是致命错误），重建 `sidecars/spider-host-jvm/host.jar`。此后：

- 非静态 proxy 的站源：不再崩，只是拿不到 `proxy` 能力 → 没有数据面 → 弹幕等 `do=…` 仍不可用；
- 静态 proxy 的站源：能力保留，`/s/<token>/proxy?do=…` 可用。

**教训**：把「授权」与「能力探测」分开看——授权只是允许协商，真正决定会不会崩的是
探测路径对异常的处理。改授权前必须先读探测实现。

## 6. 验收

- `jar_intake_proxy_migration_test.dart`：补授权 / 幂等 / 非 jvm 不动 / 脏 manifest 容错；
- `spider_proxy_url_scope_test.dart`：`127.0.0.1:0` 与 `:9978` 映射、无 `do` 不劫持、非回环不动；
- `spider_proxy_session_test.dart`（外部）：精确地址仍接管、`9978` 旧契约不破；
- 真实播放：日志出现 `播放结果本机代理地址映射 N 条 … fields=danmaku.0`，弹幕源变为
  `/s/[redacted]/proxy?do=danmu…`。
