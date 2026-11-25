# 启动日志归因与范围记录（2026-11-25，dev2）

## 范围
用户要求：同步先忽略；与本轮首页修改有关的问题修复，无关问题记录。基线为 dev2 HEAD `ec498cf`（下文代码行号以本次检查时为准）。本记录不授权修改账号数据、Python环境或安卓同步配置。

## 已修复：本轮首页功能缺少诊断事件
本轮新增高清筛选及前三张启动快照，但 HomePage/probe/cache 没有输出命中数、候选检查耗时或保存结果，无法从用户原始日志判定新链路状态。补充 scope=home 的计数型事件：
- cache_restore：usable、hit/no_usable_snapshot、页面生命周期累计elapsedMs；no_usable_snapshot同时涵盖未生成、scope改变、损坏、缺文件，不错误地断言具体原因。
- scan_start / scan_complete：generation、候选/待检/已检查/接纳数量、该轮elapsedMs；每轮边界输出，不逐图刷屏。
- first_available：本页面第一次形成非空可展示hero的来源(local_cache/verified_image)、条数和elapsedMs。此事件表示内容已选定，并不是GPU呈现或第一帧RawImage上屏的精确计时。
- cache_save：requested/encoded/readable及ready/no_usable_snapshot/no_encoded_image/write_failed；错误不打印exception全文。
日志不包含片名、路径、源站地址、图片URL、headers、cookie、API key或播放入口。缓存与筛选本身行为不变。

对应真实页面测试：home_hero_startup_layout_test.dart。先加断言时3项红（Expected日志事件1/true，Actual0/false）；补日志后4项通过，覆盖冷启动、离线快照、自动图片落盘与事件不重复/敏感字段不输出。

## 无关问题：仅记录，不在dev2顺手修改
### U1 accounts.json被误当manifest（既有缺陷）
- 日志：manifest校验失败，缺少key/name/entry；账号配置文件不是Spider manifest。
- 基线证据：HEAD spider_registry.dart:98-105 已扫描根部所有.json，:157-165按manifest解析；:197同模块把accounts.json专用于JVM账号。spider_account_store.dart:1-10明确是应用级手动网盘账号JSON。
- 归因：本轮没有修改spider_registry.dart/spider_router.dart；shared app_state.dart差异不涉及registry.scan/账号存储。不是本轮引入。
- 影响：错误级别噪声；本日志found=4，不能据此说账号损坏，也不能据此保证所有账号业务可用。
- 后续：根级扫描排除应用保留文件，保留真正manifest验证。不要删除账号文件或补manifest字段。
- 已有实现位置：只读确认dev1 spider_registry.dart:110已有accounts.json排除。MNEMON项目记录 b0334120-3d36-468c-9d5c-95dffd6311a2 描述该修复仍属于其他工作树；本次不复制/合并它。

### U2 Python准备中被报告为运行时缺失（既有时序/日志缺陷）
- 用户时间线：17:32:06.964等4条warning → 17:32:10.070运行时就绪 → 17:32:12.856瓜子影视Python Spider启动成功。
- 基线证据：HEAD app_state.dart:2620在status为空时preferPythonExecutable(null,verified:true)，:4709后台prepare；HEAD spider_registry.dart:477已有缺依赖warning。spider_router.dart:512/563的可用性分类也会调用resolve(log:log)，并非每条warning都代表真正启动失败。
- 归因：本轮未改这些运行时准备/可用性路径；本段可确认最终准备及该站点启动成功。新增候选取数是否放大可用性检查频次未独立测量，不据此声称完全无性能影响。
- 影响：约3秒暂态未就绪，重复误导日志。运行时就绪后若仍持续报warning才另查真实环境；本段没有。
- 后续：显式preparing/ready/failed状态及warning去重，真实失败保留，不抹掉故障日志。

### U3 上次未正常退出（既有提示；尚无产品缺陷结论）
- 基线证据：HEAD app_state.dart:3721以旧session marker且PID不同提示；正常清理方法HEAD:2842已存在。本轮player_page只有isLive进度护栏，未改应用退出/恢复路径。
- 日志本身无异常堆栈，无法区分强制停止flutter/结束进程和真实崩溃。不得把该提示写成已证实崩溃。
- 后续验证：正常点击窗口关闭→重启是否仍出现；如正常退出也稳定复现，再追endSessionCleanly调用与关窗生命周期。目前仅待核实，不删session标记掩盖。

## 明确不处理
- Realtime serviceStopped / 127.0.0.1:19978连接：按用户要求忽略，本次不探测或更改同步。
- site首页list=0转电影分类list=30：正常站点数据回退，与顶部hero不是同一路。
- 已有CMake CMP0175 developer warning：不归本轮首页逻辑，本次构建仍需实测。

## 本轮验收（非同步）

- 实际受影响功能代码仅HomePage诊断事件，不修改spider_registry、spider_router、PythonEnvironment、SessionRecovery或同步模块。shared AppState的既有本轮diff仍只涉及直播关键词与历史TMDB归属，未更改这三条告警路径。
- 首页诊断回归先红3项，补事件后startup4项绿；27个相关套件294项全绿。验证无URL/路径/片名/播放入口等敏感内容进入home诊断。
- puro webhtv flutter analyze --no-pub lib test：exit0、No issues found。
- puro webhtv flutter build windows --debug：exit0，kernel_blob.bin已更新；原有CMP0175开发者警告保留。
- 未修改用户账号/配置，未清除退出标记，未探测或改动同步服务。
