# Android 更新分发机制：PC HTTP 403 的最小借鉴方案

## 范围与证据口径

- 核验日期：2026-11-23；仅源码研究，无网络请求、Gradle、构建或运行时验证。
- Android 根目录：`/home/maple/Workspace/webhtv/dev1/webhtv`；Android 引用均相对该根目录。
- Android 检查提交：`73b56b2cdd98fc227c31077f09c5f90c672dc8ee`；PC 检查提交：`18fdf2d2a87a26d9cf568b4e6f2a4bb9b13ddbb3`。
- 文末 A/P 来源索引给出各论断的 `file:line`，均对应上述提交；A 为 Android，P 为 PC。代码定义能力不等于实测端点可用性。
- Lead 本次匿名探测 `https://api.github.com/repos/Silent1566/webhtv-pc/releases?per_page=30` 得 HTTP 403、`x-ratelimit-limit=60`、`remaining=0` 和 `API rate limit exceeded`。这是委托方提供的实测证据，非本研究复测，也不推定用户现场响应头完全相同。

## 结论先行

**可借鉴 Android 的“CI 发布固定静态清单，客户端先读清单，最后才查 REST API”；不必照搬 CNB/OCI 全套。** Android 当前主元数据源实际是 GitHub 固定 `update-channel` Release 的 JSON，不是 CNB，也不是 Releases REST API。[A1][A2]

PC 当前直接查询 Releases API，任意 403/429 都显示“被限流”；检查入口没有静态源或 ETag/304 分支。因此本次额度耗尽已被实测证实，但不能把所有未来 403 都认定为已证实的额度耗尽。[P1][P2]

## 1. Android 元数据查询：先静态，再 API

令 `N = <mode>-<abi><channelSuffix>.json`：mode 为 `mobile`/`leanback`，abi 为 `arm64_v8a`/`armeabi_v7a`，stable 后缀为空，beta 为 `-beta`；例如 `mobile-arm64_v8a.json`、`leanback-armeabi_v7a-beta.json`。[A3][A4]

以下为**代码拼出的原始 URL**，不是已验证可用列表；静态清单与发布说明请求还可能经过用户配置的代理前缀重写。[A2][A5]

| 顺序/用途 | 精确 URL 形状 | 条件与来源 |
| --- | --- | --- |
| 两通道第一源 | `https://github.com/Silent1566/webhtv/releases/download/update-channel/{N}` | `hasManifest()` 成功即返回。[A1][A2] |
| stable 第二源 | `https://github.com/Silent1566/webhtv/releases/latest/download/{N}` | 第一源无有效清单才尝试。[A1][A2] |
| stable 最后查询 | `https://api.github.com/repos/Silent1566/webhtv/releases/latest` | 从 assets 精确找 `{N}`。[A1][A6] |
| beta 第二源 | `https://cnb.cool/fish2035/webhtv-release/-/git/raw/main/apk/{N}` | 迁移兼容的 CNB 静态镜像，**仅 beta 走此分支**。[A1][A2] |
| beta 最后查询 | `https://api.github.com/repos/Silent1566/webhtv/releases?per_page=20` | 按返回顺序找 prerelease 或 tag 含 `-beta-` 且有同名清单的首条发布。[A2][A6] |
| API 查询后的清单读取 | `https://api.github.com/repos/Silent1566/webhtv/releases/assets/{id}` | id>0，以 `Accept: application/octet-stream` 读资产。[A6] |
| 可选说明补查 | `https://api.github.com/repos/Silent1566/webhtv/releases/tags/{tag}` | notes/desc 都空才补查；非 v 开头且无结果时再试 `v{tag}`。[A7][A2] |

- stable/beta 并行检查，共享约 22 秒截止；单次清单/API 调用限 4 秒。HTTP 文本入口仅接受 HTTPS，上限 2 MiB，非 2xx 抛错；此入口未定义 ETag/304 缓存。[A8]
- 清单解析 name（tag）、versionName、channel、code、apk、size、sha256、notes/desc、downloads.github 和可选 downloads.oci。`hasManifest()` 只要求 name/versionName 非空、code>0、GitHub URL 或有效 OCI 描述存在；**不强制 SHA-256，也不严格核验返回 channel 等于请求 channel**。[A7][A9]
- 通道/机型隔离主要靠文件命名和精确资产名匹配；有更新还需通过版本比较，不因通道不同就直接覆盖。[A3][A6][A9]
- 静态优先不等于绝不请求 API：说明缺失仍补查。CI 内嵌说明可减少这一额外依赖，不能声称全部既有清单完全脱离 API。[A7][A10]

## 2. CI 清单发布与同步

1. 从 `dist/*.apk` 实际文件生成同名 JSON，写入 tag、versionName、channel、code、字节数、SHA-256 和 tag 固定下载 URL；非空发布说明也写入。OCI 描述仅在发布成功且 digest/size 与 APK 一致时加入。[A10]
2. 版本 Release 上传 APK/JSON；已有 Release 用 `--clobber` 修复资产，beta 或显式 prerelease 使用预发布标记。[A11]
3. 复制本通道 JSON，尽力从最近另一个通道 Release 补齐清单，上传至固定 `update-channel`。固定 Release 创建为 prerelease，避免抢占 stable latest；工作流统一并发组且不取消进行中的发布。[A12]
4. CNB 同步可选且默认关闭。启用后把 apk 字段改为 `https://cnb.cool/fish2035/webhtv-release/-/releases/download/{tag}/{basename}.apk`，将 JSON 复制到镜像仓库 main 的 `apk/` 并提交推送，再处理 CNB Release 附件；不是客户端调用 CNB Release API 查最新。[A13]
5. OCI 开关默认 true，但未配置仓库时跳过；故支持 OCI 不证明每个实际发布都有 OCI，CNB 也同理。[A14]

## 3. 元数据源与包下载路由分层

- `Updater.SOURCE_CNB/SOURCE_GITHUB` 标识清单来源；`update/UpdateSource` 的 github/oci 决定**包下载顺序**。未知值归一为 OCI 优先，GitHub 优先时反向后备；缺少一类描述时只保留另一条。这个设置不改变第 1 节的元数据顺序。[A1][A7][A15]
- GitHub 包 URL 通常是 `https://github.com/Silent1566/webhtv/releases/download/{tag}/{filename}.apk`；历史命名 `getCnbAsset()` 现在其实返回 GitHub latest/download，不能仅凭名字认定 CNB 主源。[A2][A16]
- OCI 先从更新 JSON 获得描述，再请求 `{HTTPS endpoint}/v2/{repository}/manifests/{manifestDigest}` 和 `/v2/{repository}/blobs/{layerDigest}`。它是包分发后备，不是更新索引的替代品。[A7][A17]
- OCI 校验 manifest digest、唯一 APK layer 的 media type/digest/size，以及下载后实际大小与 SHA-256；401 时从受校验的 HTTPS challenge 获取临时 pull token，不是把 CI 发布凭据放进客户端。[A17][A18]
- 下载失败可尝试下一路由，用户取消则停止。路由顺序、缺失描述降级，以及静态优先、CNB beta 后备、固定清单/串行发布有单测；本次**只阅读测试，未执行**。[A19][A20]

## 4. 完整性与 Android 特有边界

- Android 在 size>0 时核对大小、提供 sha256 时校验摘要，并检查 APK 包名/版本与已安装签名；部分 ROM 无法读取候选签名时，允许摘要已验证的包进入后续系统检查。清单读取路径没有定义独立清单签名验证，不能把摘要当成发布者认证。[A21][A7][A9]
- PC 已要求 SHA-256（API digest 优先，否则读 SHA256SUMS.txt），缺失则拒绝下载安装，摘要不匹配删除文件。换元数据源不能削弱此约束；PC ADR 也明确摘要不能证明发布者身份。[P3][P4]
- 可直接借鉴：CI 从真实产物生成索引、固定轻量入口、通道/平台匹配、tag 固定下载地址、摘要与后备路线保持同一产物身份。[A10][A12][A15][P3]
- 不可直接复制：APK 路径、mobile/leanback、Android ABI token、versionCode、PackageManager signer/历史兼容、OCI APK media type；PC 保持 Windows zip、Linux AppImage/deb 与原有比较规则。[A3][A4][A17][A21][P5]

## 5. 唯一推荐：PC 固定 Release 静态索引优先，原 API 后备

以下是**建议，尚未实施/发布**，不是现存 URL 或新增产品决定。固定 Release 可复用已有 GitHub CI/资产权限，无需新域名、Pages/CNB 托管或用户登录配置。[P6][A12]

1. 桌面 CI 在正常 Release 资产与 SHA256SUMS 发布成功后，由发布事实生成 `releases.json`，上传至专用 prerelease tag `update-channel`。拟议入口：`https://github.com/Silent1566/webhtv-pc/releases/download/update-channel/releases.json`。不手工维护第二套版本事实；CI 可用现有发布授权读取发布记录，客户端不携带 token。[P6]
2. 沿用 `_parseReleases` 消费的 JSON 数组字段：`tag_name/name/body/html_url/published_at/prerelease/draft/assets[{name,size,browser_download_url,digest}]`。排除索引专用 Release 自身，保留当前正常发布的选择范围；不直接拿 `release-info.json` 当更新索引。[P2][P6]
3. 一份索引列出各平台资产，继续按现有 zip/AppImage/deb 后缀选择，不复制每 ABI 一文件。stable 排除 beta；**PC beta 取全部非草稿发布（含 stable）**，不能误改为只看 beta。仍按版本名、再构建时间选最新和判断升级。[P2][P5]
4. 先读静态索引，有效就不查 REST。静态不可用/无效时仅尝试一次现有 Releases API；再失败保留明确错误和打开发布页。网络/解析失败不得伪装已是最新。保留现有自动检查频率；条件请求和成功缓存可后续加强，不是本次去除常规 REST 依赖的前提。[P1][P2][P7]
5. 静态索引含完整说明与摘要/校验文件地址，避免读完又为补字段查 REST。CI 序列化更新，包/校验信息齐备才发布索引；失败保留上次有效索引，不用 latest 代替双通道索引。[A7][A12][P3]
6. 下载继续走 tag 固定资产、既有摘要门禁和手动操作，不引入 OCI/CNB/新签名体系或静默安装。后续错误分类应区分有额度证据的 403 与一般 forbidden，429 尊重重试提示；不将任意 403 等同 primary quota 耗尽。[P1][P3][P4]

**收益/代价：**常规查询移到静态资产分发，复用现有解析/比较/校验，改动面小；仍依赖 GitHub 网络可达性，不提供跨厂商容灾。代价为 CI 多一个一致性步骤、固定资产有陈旧/缓存窗口；摘要仍不是清单签名，不能宣称发布者认证。[A12][P2][P3][P4]

**不以其代替主解：**仅降频不能消除共享出口额度被他用耗尽；仅加 ETag 不能承诺匿名请求不占 primary quota（GitHub 对不计入主配额的条件请求明确要求认证，见 [G1]）。Pages/CNB/OCI 需另测可达性，本轮无需新增托管面；静态托管也不能承诺无限制或绝不限流。以上为方案取舍，不是对未实测后备源的可用性结论。

**未来实施验收：**静态成功零 REST；静态 404/超时/坏 JSON 进入一次 API 后备；两源失败保持 failed；stable/beta（含 beta 选 stable）、同版本不同时间戳、平台资产匹配、无摘要拒绝有离线测试；CI 排除索引自身且最后更新索引；不改变安装责任。本次仅交付研究，不运行这些未来测试。[P2][P3][P5]

## 未证实/不应假设

- 未验证 Android/拟议 PC 静态 URL、CNB、OCI 当前存在、最新、匿名可读或在用户网络可达；未检查私有配置或 token 值。
- 未证明 CDN 时延、缓存行为、镜像 SLA 或用户现场具体响应头；源码 deadline/单测不是网络测量。
- 不为 PC 新增 UI、安装策略、镜像选择作产品决策；新索引将调整 ADR-0015 原先不另维护 latest 清单的取舍，实施时应同步理由，本次不修改 ADR。[P4]

## 来源索引（提交见开头）

- [A1] `app/src/main/java/com/fongmi/android/tv/Updater.java:175-186`
- [A2] `app/src/main/java/com/fongmi/android/tv/utils/Github.java:5-68`
- [A3] `app/src/main/java/com/fongmi/android/tv/Updater.java:106-108,309-319`
- [A4] `app/build.gradle:63-79,150-156`
- [A5] `app/src/main/java/com/fongmi/android/tv/Updater.java:245-250,354-358`; `app/src/main/java/com/fongmi/android/tv/utils/GithubProxy.java:138-143`
- [A6] `app/src/main/java/com/fongmi/android/tv/Updater.java:189-238,63-64`
- [A7] `app/src/main/java/com/fongmi/android/tv/Updater.java:245-295,343-361`
- [A8] `app/src/main/java/com/fongmi/android/tv/Updater.java:61-62,134-171`; `app/src/main/java/com/fongmi/android/tv/update/UpdateHttp.java:14-50`; `app/src/main/java/com/fongmi/android/tv/update/UpdateUrl.java:29-40`
- [A9] `app/src/main/java/com/fongmi/android/tv/bean/Update.java:11-59`
- [A10] `.github/workflows/android-release.yml:428-474`
- [A11] `.github/workflows/android-release.yml:478-496`
- [A12] `.github/workflows/android-release.yml:52-62,499-539`
- [A13] `.github/workflows/android-release.yml:38-42,541-551`; `.github/scripts/sync-cnb-release.sh:10-19,31-40,64-72,81-105,109-139`
- [A14] `.github/workflows/android-release.yml:43-47,372-397`
- [A15] `app/src/main/java/com/fongmi/android/tv/update/UpdateSource.java:5-13`; `app/src/main/java/com/fongmi/android/tv/update/UpdateRoutePlanner.java:13-38`
- [A16] `app/src/main/java/com/fongmi/android/tv/Updater.java:322-332`
- [A17] `app/src/main/java/com/fongmi/android/tv/update/OciRegistryClient.java:26-68,160-184`
- [A18] `app/src/main/java/com/fongmi/android/tv/update/OciRegistryClient.java:85-102,106-136,204-207`
- [A19] `app/src/main/java/com/fongmi/android/tv/Updater.java:453-476`; `app/src/test/java/com/fongmi/android/tv/update/UpdateRoutePlannerTest.java:22-82`
- [A20] `app/src/test/java/com/fongmi/android/tv/UpdateChannelTest.java:14-69`
- [A21] `app/src/main/java/com/fongmi/android/tv/Updater.java:583-636`
- [P1] `apps/desktop-flutter/lib/core/app_update.dart:20-40`; `apps/desktop-flutter/lib/services/app_update_service.dart:192-219,602-609`
- [P2] `apps/desktop-flutter/lib/services/app_update_service.dart:198-257,507-599`
- [P3] `apps/desktop-flutter/lib/services/app_update_service.dart:259-273,316-324,487-504`
- [P4] `docs/adr/0015-app-update.md:23-44,58-60,78-84`
- [P5] `apps/desktop-flutter/lib/core/app_update.dart:9-16,233-281`; `apps/desktop-flutter/lib/services/app_update_service.dart:507-540`
- [P6] `.github/workflows/desktop-release.yml:812-866`
- [P7] `apps/desktop-flutter/lib/core/app_update.dart:25-40`; `docs/adr/0015-app-update.md:33-38`
- [G1] GitHub 官方 [REST API best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)：Avoid polling 节要求 authenticated conditional requests，未变更数据才不计入 primary rate limit。
- [G2] GitHub 官方 [REST API rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)：匿名主额度按出口 IP 为每小时 60；remaining=0 时等待 reset；secondary limit 遵守 Retry-After，不连续重试。
