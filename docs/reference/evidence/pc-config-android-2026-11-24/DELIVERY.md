# 原 PC 配置在安卓执行 — 可用 Linux 测试版

## 功能与身份保证
在「管理 / 配置导入与管理」原配置的 ⋯ 中选「在安卓环境运行此配置」，再选择已保存安卓环境。PC发布原始JSON快照，安卓创建/复用非激活副本，PC内存生成T4执行视图；原PC记录id/JSON/sourceKey/历史/收藏不改。Android使用interfaceKey，不是数字cid；不切换活动配置、不删除用户配置、不上传任意本地JAR。
「连接并导入」只连接环境和导入安卓已有配置，不会自动改变某份PC配置的运行方式。切回桌面由配置行的「切回桌面运行」完成。重启复用token/guestPort/interfaceKey，不反复创建副本。

## 启动最终新构建
先退出旧PC窗口，再执行：

```bash
cd /home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3
source .local/linux-build/environment.sh
./apps/desktop-flutter/build/android_execution_final/linux/x64/release/bundle/webhtv_pc
```

然后「管理」→「混淆订阅测试」⋯→「在安卓环境运行此配置」→HUAWEI LIO-AN00（192.168.50.3:5555）。正常用户HOME/XDG资料目录不变。无需sudo；使用已有用户级pkg-config/GTK/libmpv环境。需保留整个bundle，不要只复制小启动器。
独立构建没有覆盖旧build/linux目录或替换运行中的进程。libapp.so SHA256：
`87eed71ef172bcd0327990227f3be1636d468d2a7d9ed5df32a3bccbd3ed21e3`

## Lead最终验收（2026-11-25）
- 721项触达回归通过，1项默认门控跳过；flutter analyze无问题，git diff --check通过；Linux release构建成功。
- PNG/媒体安全相关242项独立测试通过；专项审查3项风险修复，复审9个原失败断言全部通过。
- 真实SDK/HTTP/AppState：93/93站点、78CSP保留，JSON/sourceKey不变。实际用户记录25的HTTP元数据仍text/html；该误标导致菜单隐藏的问题已修复。
- 代表性影视源A6分类、12条目、3线路；488个HLS媒体URI全部代理化，0原始地址残留。
- 实际代理去掉已证明的69字节PNG包装，返回200video/mp2t、登记.ts URI、采样65536字节从TS包开始。
- 实际代理分片的HLS入口识别H2641920x818/AAC；FFmpeg真实首帧解码1帧、exit0，无预裁剪/强制demux/关闭格式检查。
- AppState/SDK关闭重建后同token/guestPort/interfaceKey，原记录不变，恢复T4视图。
- 安卓活动204站点摘要相同（aa4e383a…），默认ADB服务器没有留下本次转发/反向转发。

安全回执：[real-appstate-final.json](real-appstate-final.json)，详细证据：[real-appstate-final.md](real-appstate-final.md)。没有源URL/JAR/ext/snapshotToken/媒体地址。

## 修复范围与未承诺项
- HTML传输MIME误标不再拒绝已解析JSON；真正HTML/本地bundle仍拒绝。
- 安卓来源与ADB映射分开；公网HLS也嗅探/重写。全局主机/IP/DNS/redirect、跨域Cookie/Auth过滤不放宽；派生主机不意外收紧空主机列表。
- PNG包装只有在来源、PNG/IEND/3个TS同步头、登记媒体角色都确认时才归一化。真正PNG/MP4、KEY/MAP/BYTERANGE/variant/未知角色/容量溢出和错误响应保留原样；格式URI提示不授予目标权限。
- 归一化完整200；可选探测失败保留原206，token/权限/配额/目标失败仍拒绝；无全媒体缓冲或手写socket协议。
- 上游部分分片返回404/NoSuchKey仍可能造成影片失败，不伪装200。本次证明一个有效分片首帧，不是整部连续播放/源内每个分片都无错误。
- 不宣称全部78CSP、所有混淆/nativeJAR、Windows、AVD实际启动均兼容。此版只使用已有安卓环境，不安装任意runtime。
- 已登记普通HLS .png媒体角色支持包装兼容；KEY/MAP/BYTERANGE/加密/混合或未支持角色不擅自转换。
- DartHttpServer完全停滞时不能立即观察peer关闭，默认30s idle有界清理；token撤销立即取消，健康长流重置idle计时。
- 安卓副本非激活但共享主应用账号/运行时，不是独立worker/account沙箱。副本与真实用户的旧测试配置不自动删除。

## 工程记录
规格/计划：docs/superpowers/{specs,plans}/2026-11-24-pc-config-android-execution.md。Android已提交安装25541eda（非激活导入）、d7d4c79（cache失效）、21c925bb（直接cache测试）。PC改动在当前worktree，未代用户commit/push。
子任务显式路由deepseek-official/deepseek-v4.1-flash；本会话未记录子模型allowlist。全部结果由Lead独立验收，ready不是交付结论。
