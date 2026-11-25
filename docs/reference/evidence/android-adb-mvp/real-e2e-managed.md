# Managed-ADB 端到端真实复测（Lead）与阻断点

- 日期：2026-11-24；目标设备的模拟器 192.168.50.3:5555（Android9/API28，WebHTV5.6.0）。
- 运行方式：私有脚本（git-ignored）`apps/desktop-flutter/.superpowers/sdd/2026-11-24-android-adb-mvp/real/real_appstate_e2e_test.dart`，真实 AppState + 真实 AndroidAdbRuntime + 真实 ADB 服务器与转发 + 真实 T4 网关；临时数据目录，结束即删。
- **结论：管理型链路（连接→导入→激活→浏览→详情→播放决策→受控会话→唯一转发）全部跑通到真实设备；最后一跳取流被上游响应的重复 Content-Length 头挡住。真实播放尚未证明。**

## 已证实的部分（一次运行内）

| 阶段 | 结果 |
|---|---|
| 连接 | uuid 打码 0970****，reachableBase 为本机回环，网关转发生效 |
| 导入 | 该设备上 6 份源全部以 `bridge_transport='adb'` 导入（站点数 88/83/127/106/2/204） |
| 激活 | 选中含 validation-source-B 的那份；站点 api 指向本机回环 |
| 旧播放桥 | 管理型记录下为 null（单一转发所有者） |
| 浏览 | validation-source-B 首页 29 个分类 / 4 条 |
| 详情 | 1 条、4 条线路、22 集 |
| 播放决策 | 原始 guest 地址 `http://127.0.0.1:5000/proxy/...`；决策后为本机代理地址 |
| 转发授权 | resolver 授权成功，guest 5000 → 本机转发端口（每次运行不同） |
| 取流 | **失败**：见下 |

## 阻断点（已定位到根因，非管理型接线问题）

同一 guest 5000 目标经运行时转发**直取**（绕过本机代理）时报：

```
HttpException: The Content-Length header occurred more than once,
at most one is allowed., uri = http://127.0.0.1:<forward>/proxy/baidu/5/2048/msubep-5-1
```

即安卓侧 `/proxy` 响应带了**两个 Content-Length 头**，Dart 的 HttpClient（以及本机代理的上游请求）在解析响应头阶段就拒绝，代理随之把 502 交给播放器（`{"status":502,"msg":"请求上游失败：HttpException"}`）。

- 这不是「转发没建」「策略拒绝回环」「端口算错」：直取同一转发端口时同样失败，说明问题在响应头合法性。
- 也不是本轮引入的回归：老 `AndroidPlaybackBridge` 路径同样是本机 HttpClient 取 guest 回环，遇到同一响应会同样失败；之前的手工探针能取到 206，是因为用了不校验收发头级别的读取方式（原始 socket/toybox），与播放器实际路径不同。
- 触发源：`validation-source-B` 的 `/proxy/baidu/...` 线路。

## 影响

- 该家族源（返回重复 Content-Length 的 `/proxy` 响应）在**任何**基于 Dart HttpClient 的取流路径上都不可播放，与管理型/传统桥接无关。
- 其它源、以及不经过 `/proxy` 的直链线路不受影响（本轮未逐一回归全部 204 个源）。

## 三条可选处置（需要产品决策）

1. **修安卓侧**：`/proxy` 响应只写一个 Content-Length（或改用 chunked）。最干净、对其它客户端也有益，但需要重新构建并让用户更新 APK（当前设备是 5.6.0）。
2. **PC 侧容错读取**：为受管媒体做一条 socket 级、严格校验的 JSON/媒体读头路径，容忍重复的非歧义头。改动集中但属于协议容错，需单独设计与安全评审（不能变成宽松解析器）。
3. **接受限制并如实上报**：把这类源标为「该源响应头不合规，PC 无法取流」，UI 给出可定位原因，不做静默降级。

## 复现

```bash
cd apps/desktop-flutter
WEBHTV_REAL_ADB=1 ../../.local/linux-build/flutter/bin/flutter test \
  .superpowers/sdd/2026-11-24-android-adb-mvp/real/real_appstate_e2e_test.dart
```

脚本用临时目录、不写用户配置、不改 APK、结束时关闭自建 ADB 服务与转发。
## 更正（同日，安装修复版 APK 后）

### 已做的事

按用户选择「修安卓侧并重建 APK」：

1. `Proxy.addHeaders`：chunked 响应不再复制上游分帧头（新增 `ProxyChunkedResponsePolicy` + 单测，11 项通过）。
2. `OriginMediaRelay.spiderProxy`：同样跳过 `content-length`/`transfer-encoding`/`connection`。
3. 重建 `leanbackArm64_v8aDebug` 并用同签名 `adb install -r` 覆盖安装（与已装 APK 同为 Android Debug 证书）。
4. 安装前后：versionCode 560 / versionName 5.6.0 不变；204 个站点、配置摘要 `aa4e383a…` 前后一致（用户配置未丢）。

### 结果：这两个改动**没有**解决本源的取流阻断

重新跑真实端到端，仍是同一个错误。进一步直接读取该端点的**原始响应头**（ADB 转发到 guest 5000 后裸 socket GET）：

```
HTTP/1.1 206 Partial Content
server: POMS/CloudUI 1.0
...
Content-Length: 1024
...
Content-Length: 1024        <-- 同一个头出现两次
```

即：重复的 `Content-Length`（以及重复的 `Content-Disposition`/`accept-ranges`）是**上游 CDN 响应**被逐字转发出来的，来源是 guest 内 5000 端口那个应答者（`POMS/CloudUI`，网盘系 CDN），**不是**我们仓库里的 `Proxy.java` 或 `OriginMediaRelay`。

### 因此

- 本轮两处安卓改动是**协议卫生上的正确修复**（chunked 响应本就不该复制上游分帧头），但对这个源无效——它的应答方不在我们可控的代码里（在 jar/上游 CDN 一侧）。
- 我此前把根因写在 `Proxy.java:76-77` 是**过度推断**，已在此更正：那段代码确实存在同类缺陷，但不是本次 502 的成因。
- 现在要真正播这个源，只剩 PC 侧容错读取（严格解析、容忍重复但值相同的分帧头）或如实标记不可播放两条路。

## 归因精度与部署变体更正

重复头已在 guest5000 的原始响应上确证，响应宣称 `Server: POMS/CloudUI`。Server 字段可以被中继保留，不能单凭它证明重复头由 CDN 本体产生；可确证的是“不在本轮修改的 WebHTV9978响应路径，位于guest5000/第三方源链路”。CDN或该链路内的转发程序，具体责任尚未证明。

原APK清单没有leanback特征，使用arm64；此前部署的leanback调试变体与原mobile界面不一致。已选择构建mobileArm64_v8aDebug以恢复原变体，同时保留用户授权的头过滤修复、签名与配置数据。## 结果：容错读取生效，真实取流通过

安装回原变体（`mobileArm64_v8aDebug`，209,971,208 字节，与原包同变体），同签名 `-r` 覆盖安装后：

- 204 个站点、配置摘要 `aa4e383a…` 仍与安装前一致。
- 真实端到端复测（Lead 自己的脚本，有界读取 + 硬断言）：

| 项 | 结果 |
|---|---|
| 状态码 | **206** |
| 采样字节 | 65536（Range `bytes=0-65535`） |
| Content-Range | `bytes 0-65535/2861233241` |
| Content-Type | `video/mp4` |
| MP4 ftyp | true（偏移 4 起为 `ftyp`） |
| 路径 | 经本机代理会话 → 受管转发 → guest 5000 |

即 `PASS real managed media via AppState proxy`。

说明：同一转发端口的**严格** HttpClient 直取仍然报重复头（这是预期）；真正播放走的是会话内「严格失败 → 受限容错重试」这一条路径，容错读取只在值完全相同的情况下折叠重复头，值冲突仍失败。上一轮宽松读取（`fold` 无上限）已改为 65536 字节封顶，避免把整段媒体读进内存伪装成功。
