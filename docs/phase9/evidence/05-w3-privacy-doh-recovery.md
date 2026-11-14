# 05 · W3 / P2-8 DoH、隐身与崩溃恢复

- 日期：2026-10-22
- 上游：`Startup.java`（OkDns）、`catvod/net/OkDns.java`、`catvod/bean/Doh.java`、
  `CrashActivity.java`、`PlaybackRecoveryActivity.java`、`Setting.isIncognito()`
- 状态：三项均已落地；边界见 §4

## 1. DoH（DNS over HTTPS）

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 编解码/配置 | `lib/core/doh.dart`（新） | RFC 1035 查询构造与应答解析（A/AAAA/CNAME、压缩指针、rcode）；`doh` 服务商解析（对象/字符串、去重、只接受 https）；`hosts` 静态映射（精确/后缀/`*.`/IPv6）；TTL 夹取；磁盘缓存模型（上限 512 条、过期裁剪） |
| 设置 | `lib/core/doh_settings.dart`（新） | 顶层 `doh`：`enabled/url/cacheMinutes`；URL 必须 https；缓存 1–1440 分钟 |
| 解析服务 | `lib/services/doh_resolver.dart`（新） | POST `application/dns-message` 查询；A 失败再试 AAAA；多端点顺序切换；内存 + 磁盘缓存；失败回落系统 DNS（限流日志）；`ips` 作为端点自身的 bootstrap 地址（钉 IP + SNI 用域名） |
| 传输接线 | `lib/services/outbound_proxy.dart` | `HttpClient.connectionFactory`：先 DoH/hosts 解析，再建连接；https 用 `SecureSocket.secure(host: 原域名)` 保证 SNI 与证书校验；走代理时不动目标地址 |
| 状态/UI | `lib/state/app_state.dart`、`lib/ui/advanced_settings_page.dart` | 配置装配时按输入签名重建客户端；高级设置「加密 DNS（DoH）」：开关、自定义端点、缓存时长、服务商/hosts 计数 |

已用 `dart run` 探针确认：`connectionFactory` 返回普通 Socket 时 https 不会被自动升级
（example.com 返回 400），必须自己 `SecureSocket.secure`（返回 200）。实现按后者。

真实网络验证（2026-10-22，端点 `https://cloudflare-dns.com/dns-query`）：

```text
DoH 解析 example.com    -> 104.20.23.154, 172.66.147.243
DoH 解析 www.baidu.com  -> 45.113.192.101, 45.113.192.102
经 DoH + connectionFactory 请求 https://example.com/   -> 200（577 字节）
经 DoH + connectionFactory 请求 https://www.baidu.com/ -> 200（17143 字节）
```

（IP 是当时快照，会变；这一步只证明「DoH 解析 → 按 IP 连接 → SNI/证书校验按域名」
整条链路可用，不是固定期望值。）

## 2. 隐身模式

- 顶层 `incognito` 布尔；缺席 = false = Phase 0–8 行为。
- `recordProgress` 不写历史（只记一次日志）、`updateHistoryPoster` 不回填、
  `recordSeasonProgress` 不写季度投影、搜索关键词不落盘（仅本次会话内存）。
- 设置入口：高级设置「隐私 → 隐身模式」。

## 3. 崩溃恢复

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 模型 | `lib/core/session_recovery.dart`（新） | 会话标记（pid/启动时间/版本/播放上下文）、崩溃记录格式、横幅文案；崩溃日志 64 KiB 上限 |
| 存储 | `lib/services/session_recovery_store.dart`（新） | 同步 IO：`beginSession/readMarker/updatePlayback/endSessionCleanly/acknowledgeRecovery/appendCrash/readCrashLog` |
| 状态 | `lib/state/app_state.dart` | bootstrap 读上一次标记（pid ≠ 自己才算崩溃）并写本次标记；`pendingRecovery`/`recoveryCrashLog`/`dismissRecovery`/`endSessionCleanly`；`recordProgress` 节流更新播放上下文 |
| 入口 | `lib/ui/app.dart`、`lib/ui/recovery_banner.dart` | `FlutterError.onError` + `PlatformDispatcher.onError` 写崩溃日志；窗口关闭/销毁时删标记；启动横幅「继续上次播放 / 崩溃日志 / 忽略」 |
| 续播 | `lib/ui/playback_resume.dart`（新） | 从历史页抽出的续播实现；崩溃恢复复用同一条「重新解析」路径 |

标记里**不存 URL、不存 Header**：恢复时按站点重新解析，避免把时效直链或凭据写盘。

## 4. 边界（明确披露）

- DoH 只接站点/解析/字幕等出站请求；**本地回环播放代理不接**——它有自己的 DNS
  重绑定防护（每次连接前解析并复核全部地址），合并两套解析链会削弱该防护。
- DoH 失败只回落系统 DNS 并记一次日志，不会让站点不可用。
- 隐身只挡本机自动写入；安卓主动推送属于用户显式操作，仍按既有同步逻辑合并。
- 崩溃恢复**不自动重启、不自动起播**：必须用户点「继续上次播放」；
  同进程重复 bootstrap（恢复备份/重置）不会误判为崩溃。
- 没有实现 Android 的 mpv `PlaybackRecoveryMonitor`（播放器进程崩溃自动恢复窗口）；
  PC 播放器与主进程同生命周期，这一层没有对应物。

## 5. 测试

```text
test/phase9_doh_test.dart                 15 用例
test/phase9_privacy_recovery_test.dart    12 用例
```

覆盖：DNS 报文构造/解析（A/AAAA/压缩指针/rcode/截断）、TTL 与缓存裁剪、
端点与 hosts 宽松解析、DoH 查询与缓存命中、静态 hosts 优先、失败回落、
多端点切换、磁盘缓存跨实例、设置夹取；隐身偏好与三类写入闸门、搜索历史不落盘；
会话标记往返、pid 判定、有界崩溃日志、损坏标记兜底；横幅文案与动作回调；
高级设置区块可达并能改开关。

回归（本轮）：

```text
dart analyze                              → No issues found
phase9_* 全量                              → 224 用例通过
phase2_startup_home / phase2_playback_target
phase8_settings_entries / phase9_outbound_proxy
phase9_danmaku_display                    → 40 用例通过
```
