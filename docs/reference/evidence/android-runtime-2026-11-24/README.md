# Android 运行环境实测：Lead 验收结论

- 日期：2026-11-24；目标：用户指定的192.168.50.3:5555模拟器。
- 执行计划：[验证计划](../../../superpowers/plans/2026-11-24-android-runtime-validation.md)。
- **任务1证据验收通过；严格同输入的本地爬虫/native兼容增量仍为conditional。** 没有开发或安装新的运行时/MVP。

## 已证实

1. 模拟器Android9/API28，已装WebHTV5.6.0，报告x86/ARM32/ARM64与libnb.so。ABI/bridge广告不是native执行证明。
2. 直连局域网9978超时，但ADB转发可访问现有T4网关，204个有效站点。连接已有环境这条路径成立。
3. 播放地址存在独立的guest回环域：Media/Bili返回guest127.0.0.1:5000，网关9978的转发不覆盖它。正确转发5000后，Media可获取MP4范围字节。
4. Lead独立复测Media：首页29类/4条，96.6ms；两个64KiB样本均HTTP206，分别为0–65535及1048576–1114111，首块具有MP4 ftyp；资源总长度2861233241B。请求只取样，不下载完整视频。
5. Lead独立复测Bili：DASH清单200/20724B/15个representation，但实际视频请求403/HTML/552B。清单可达不是可播放；没有猜测签名或鉴权原因。
6. Lead独立复跑现有JarIntake.install：native goproxy、native libjsc、直接wex壳三项均拒绝，目标目录未创建。没有绕过classifier、native限制或加固壳payload链。

## 样本判定

| 样本 | Android现有配置 | 桌面现有宿主、复制输入 | 验收解释 |
|---|---|---|---|
| AList | 浏览/详情/搜索有数据，所选项是folder | 同类方法有数据 | 没有有效播放leaf样本，不算源播放失败 |
| Media | 浏览/详情/搜索有数据，MP4范围可达 | 当前JAR在类链接时缺android/widget/LinearLayout，exit3 | 有条件的适配器/UI覆盖机会；并非原始爬虫或完整播放证明 |
| BiliBili | 浏览/详情/搜索有数据，MPD可达但音视频403 | 方法有数据，未验证桌面播放 | 403保留为媒体访问失败，不以200清单掩盖 |
| native Danmaku | 设置菜单，未执行action | 含ARM goproxy被现有Intake拒绝 | packaged native与菜单响应不足以证明native执行 |
| WvSpider/libjsc | 绑定/DEX引用已查；未执行UI业务 | 含native被拒绝 | 在无UI交互边界下未测，不等于不兼容 |

## 为什么不判定全部兼容或严格uplift

- 当前普通fae799 JAR为远程转发封套。业务返回不证明原始上游爬虫或native逻辑在guest内运行。
- 复制到桌面测试的JAR字节来自Android，SHA256已一致；但PC旧普通缓存与当前Android普通缓存不同。
- 重新获取原配置有生成uid差异，安装中的精确ext不可直接证明。JAR相同、key相同、业务条数接近都不能代替同输入证明。
- native Danmaku没有观察到libgoproxy加载/执行；已有libjsc进程映射无法归因到一个新Wv业务调用。
- 没有验证解码/渲染、连续播放、冷启动/恢复、长期吞吐、取消重连或并发配置隔离。

## 独立保全与成本记录

- Lead复核23份PC配置全部列值不变、25个PC缓存JAR哈希不变、4个Android缓存JAR哈希不变。
- Android worker核对所有持久化偏好及有效配置before/after不变；Lead再次确认有效配置对象一致，key digest与预检一致。
- compact、sort_keys、ensure_ascii=true的有效配置SHA256为be516671b2a94450f2d18bfca9fa653007c663314f822d35657b7088d9bb11d0。ensure_ascii=false得到另一哈希，但解析对象相同，不是配置变化。
- Android进程原本已运行：RSS374796→375136KiB（约366MiB），只有warm快照，不是冷启动预算或长期内存结论。
- Worker媒体/错误body153452B；Lead额外媒体验证152348B。均为有界取样，没有GB下载。
- 报告已脱敏；原JAR、ext、UID、完整URL、偏好、原始日志及可复跑脚本仅在本计划git-ignored工作区，目录权限700。没有提交第三方二进制或用户凭据。
- 未更改APK、用户配置、账号、UI或生产源码；未使用共享ADB5037。
- 本轮临时端口35829/35413不是产品配置；验证结束清理自有forward与自建ADB5038，不停止用户模拟器/APK。

## 下一阶段的范围分岔

- **已有环境接入MVP**：基于已证实的ADB→T4/媒体转发，用户显式选择已有设备/AVD并使用其中已配置的站点；不承诺PC直接导入任意JAR或全native兼容。
- **继续严格JAR/native验证**：需要非转发样本、明确同一jar/api/ext及可归因的native调用；可能需要独立宿主或扩展临时验证边界，不能用当前封套冒充通过。

## 证据与任务书

- [Android实测报告](android-probe.md) / [结构化记录](android-probe.json)：run1/3，Lead接受证据及其conditional结论。
- [桌面对照报告](desktop-probe.md) / [结构化记录](desktop-probe.json)：run1/3，Lead独立复跑3项拒绝后接受。
- Lead复测/保全记录：本计划私有lead/r6-checks.json、lead/preservation-checks.json；不包含公开的原始URL或凭据。
- 待验证风险已路由：回环不可达→仅验证中建立5000转发并复测；Bili403→保留失败、不猜鉴权；folder/menu→不当播放样本；ext/native归因不足→严格uplift不通过；下阶段范围→先明确目标再开发。
