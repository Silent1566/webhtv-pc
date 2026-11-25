# 原 PC 配置在安卓环境执行：最终验收记录

## 实际验证（不是仅“能连上”）
- 通过真机192.168.50.3:5555、真实SDK/HTTP调用，复制原PC记录25的93站点JSON到隔离测试资料目录；没有编辑实际用户数据库。
- 原配置93站点/78个CSP保留，内存执行视图93/93全部T4。原JSON/sourceKey不变；实际记录HTTP元数据仍为text/html。
- 代表性影视源A：6分类、12条目、3线路。影片样本0清单488个媒体URI全部代理化，0原始地址残留。
- 有效源分片经实际LocalProxyServer返回200video/mp2t；69字节PNG包装被有界证明后移除，采样65536字节从TS同步头开始，登记.ts别名不改变实际目标/授权。
- 由真实代理分片构造单分片HLS测试入口（没有预先裁剪、没有强制输入格式或放松扩展检查）：ffprobe识别H2641920x818/AAC；ffmpeg实际解码1帧，exit0。
- 关闭/重建整个AppState/SDK后，同token/guestPort/interfaceKey复用；原记录不变，恢复执行视图仍T4。
- 安卓活动配置204站点摘要保持aa4e383ae4ebf5055882ae83ff04eb2e7c5578537872e325dbacb3a1a8fe7a06。

完整安全回执见real-appstate-final.json。它只包含计数/类型/状态/编解码器，未收录配置地址、JAR/ext、snapshotToken或媒体URL。

## 修复与审查结论
- 误标HTML传输MIME导致菜单隐藏：已解析JSON可执行，本地bundle/非配置HTML仍拒绝。
- Android来源与ADB目标映射分离：公网媒体也按内容识别清单；普通PC流不改变。
- 302派生主机不会把原本无限制公网主机范围意外收紧；显式主机限制、IP/DNS/redirect与SensitiveHeaders不放宽。
- PNG包装TS：16KiB探测，PNG结构IEND+188间隔3同步头；只有已登记合法媒体角色归一化。普通PNG/MP4、key/map/variant/byterange/未知角色、容量溢出和错误响应保持原样。
- 归一化完整200，有限无Range重取重新授权/计费/检查token；未知格式的可选探测超时保留原206，真正权限/配额/目标失效仍拒绝。
- 专项复审F1/F2（压力下角色/容量fail-open）、F3（探测失败误丢206）均已关闭：独立9个复现实验通过；现有56个PNG测试通过。根据private png-ts-review/review.md，当前修正无新增具体风险。

## 明确未证明或不属于此次修复
- 部分源分片由上游返回404/NoSuchKey；没有把它们变成200，也没有修复源站失效资源。
- 本次证明一个有效分片的解码首帧，不是该影片每个分片或整部连续播放都无错误。
- 不是全部78个CSP、所有混淆/native JAR、Windows、AVD启动的普适兼容证明。
- 正常PNG包装兼容仅适用于已登记普通HLS.png媒体角色；KEY/MAP/BYTERANGE/加密/混合角色不擅自改写。
- DartHttpServer完全停滞时无法立即观察远端断开；显式token撤销立即取消，停滞连接按30s默认idle timeout有界清理（正常数据到来重置，不截断长影片）。
- 安卓副本非激活，使用主应用现有账号/运行时；不是独立私有worker/account沙箱。不上传本地任意JAR，不切换/删除安卓配置。
