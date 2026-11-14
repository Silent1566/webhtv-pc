# TMDB 内嵌 payload 与配置根 key — 验证证据（2026-11-13）

范围：catalog.md 两项 TMDB 缺口；Android C16 payload 与订阅凭据行为。PC 基线 HEAD 53e0f1e；本轮未提交。

## 实现链路

- core/protocol.dart:1006：Vod.tmdb 类型化 getter，保留 extra/JSON 往返，不改站源播放字段。
- core/tmdb_source_payload.dart:41/169/190：协议/身份/大小/安全图片验证，能力缺口规划与来源优先合并；支持 own-season 顶层 episodes 和嵌套 seasons[]。
- state/tmdb_state.dart:475/937/971/985：可渲染来源内容先发布；无凭据不联网；手动匹配优先，跨作品/季度/配置迟到结果隔离；作品/季度视频分离。
- ui/tmdb_episode_detail.dart：单集/电影弹窗使用 payload，完整组零请求；未完整组定向补齐，跨季及站点规则迟到结果拒绝。
- core/tmdb_credential_ingress.dart:27 → config_parser.dart:49：根 tmdb_api_key 提取与剥离，候选仅经瞬时结果传递；16..256 可见 ASCII、无内部空白，重复根键拒收。
- state/app_state.dart:725/731：tmdbUserConfig 手动设置与 tmdbConfig 有效配置分离；用户 key/token 优先，订阅 key 仅当前配置的进程内存兜底；提交后接收、失败/迟到/删源/换库均隔离。
- core/tmdb_config.dart、services/storage.dart、state/sync_state.dart：copy/sanitize/serialize 保留凭据来源，订阅 key 不进入 settings/普通配置/导出/备份/诊断转换缓存；桥接缓存剥离候选，只当前成功回调接收。

## RED → GREEN 与独立验证

| 验证 | 结果 |
| --- | --- |
| A 协议/规划/合并（含 own-season RED） | 核心42通过；旧协议/模型/状态等191通过 |
| C 首屏、弹窗、手动匹配、跨季、规则迟到、白名单、视频作用域 RED → GREEN | 最终聚焦40通过；18套旧回归353通过 |
| B 根字段、作用域、桥接、剥离、错误分类、凭据来源洗白/空白、换库/诊断缓存 RED → GREEN | 最终聚焦24通过；20套旧回归314通过 |
| 协调者最后独立复跑 | 凭据24/24；合并协议/状态/UI/配置/换源/迟到359/359；此前 A+C 聚焦82/82 |
| 全仓 flutter analyze | 0 error / 0 warning / 95既有info；info导致命令非零，不宣称无issues |
| 基线测试签名闭环 | HEAD已有7文件共8个override缺preferredParseName；仅补可空参数，6单测文件62/62，7文件analyze无issues |

所有结果来自 Flutter 3.47.5 / Dart 3.13.4。测试工作目录 apps/desktop-flutter：

```bash
export FLUTTER_ROOT=/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3/.local/linux-build/flutter
export TMPDIR=/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3/.local/tmdb-source/tmp-accept
export LD_LIBRARY_PATH=/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3/.local/linux-build/sysroot/usr/lib/x86_64-linux-gnu
mkdir -p "$TMPDIR"
"$FLUTTER_ROOT/bin/flutter" test --no-pub test/tmdb_root_key_ingress_test.dart test/tmdb_subscription_scope_test.dart test/tmdb_subscription_settings_test.dart test/tmdb_subscription_bridge_test.dart
"$FLUTTER_ROOT/bin/flutter" test --no-pub test/tmdb_source_payload_test.dart test/tmdb_source_core_test.dart test/tmdb_source_state_test.dart test/tmdb_source_integration_episode.dart test/phase4_tmdb_state_test.dart test/phase4_tmdb_orchestration_test.dart test/phase4_tmdb_service_test.dart test/phase4_tmdb_ui_test.dart test/tmdb_episode_detail_test.dart test/nav_source_detail_ui_test.dart test/config_and_site_test.dart test/config_record_edit_refresh_test.dart test/phase10_last_config_test.dart test/detail_source_swap_test.dart test/phase3_detail_race_test.dart
"$FLUTTER_ROOT/bin/flutter" analyze --no-pub
```

## Before / After

确定性本地字体/图片/HTTP fixture，无第三方 TMDB 联网。Before 在对应生产修改前捕捉；After 最终重采，字节与原After一致。

| 场景 | Before | After | 相同条件/请求数 |
| --- | --- | --- | --- |
| 无凭据首屏 | [before](screenshots/tmdb-source/before.png) | [after](screenshots/tmdb-source/after.png) | 实际TmdbState.loadForVod→既有TmdbDetailView，1280×950 DPR1 dark，API0→0，来源海报/简介/类型可见 |
| 单集弹窗 | [before-modal](screenshots/tmdb-source/before-modal.png) | [after-modal](screenshots/tmdb-source/after-modal.png) | 实际showTmdbEpisodeDetails路由，同卡/作品/季集/fixture，1280×950 DPR1 dark，API1→0 |
| 设置凭据隔离 | [settings-before](screenshots/tmdb-source/task-b-settings-before.png) | [settings-after](screenshots/tmdb-source/task-b-settings-after.png) | 同root fixture，1100×900 DPR1 dark，字节一致；用户key输入为空 |

After SHA256：详情 b587e370ecb6c993840ff3af4e4e40dbe826d72a3ab994a90621336fd68f156a；弹窗 18cd15b46a4c5bc0f8a3f4056c4baeae43ef55221bbd1ba5d9ecd6e96ad1b159；设置 a1e8ae08c3f54b3acbc48e4d03cac6bc52e9d32751dfa5f3f7ae52b76dddfd48。弹窗少数字体占位存在于两张相同测试字体环境，不是新布局回归。

## 追加修复：TMDB 未命中时保留接口简介

实际 DetailPage/AppState/SiteService fixture 复现：列表或搜索结果有 vod_content，但 ids= 详情响应缺失/空白简介；详情响应整体替换列表项，TMDB 未命中后首屏为空。新增 core/detail_source_merge.dart，AppState 发布详情前仅补空的简介/海报/备注/年地区/演职字段；详情非空字段、身份、播放线路、extra/TMDB payload 不变。

新用例 RED 后 GREEN 15/15；协调者独立复跑新用例与源字段/TMDB状态/详情竞争/编排共147/147，相关3文件analyze无issues。实际页面同场景1280×950 DPR1 dark：[Before](screenshots/tmdb-overview/before.png) / [After](screenshots/tmdb-overview/after.png)，接口简介在After可见；未使用最初未能复现的场景作为验收证据。

## 追加修复 2：目录/分享链条目的接口简介

用户复测仍空白后，从真实运行日志（00:19–00:23）定位到第二处丢失：进入 atvp_detail 目录条目后走 SiteService.folderDetail 展开，子详情响应**确实带 vod_content**，但合成最终条目时只用父目录项（无简介），子详情显示字段被丢弃；前一处 AppState 合并无法补救。

修复：folderDetail 展开时收集成功解析的子条目，复用 detail_source_merge.dart 的 mergeFolderDisplay 仅补简介/海报/备注/年地区/演职，保留父条目身份、合成线路与 flags；失败告警/取消/线路逻辑不变。RED 为实际 DetailPage+AppState+folder fixture 断言子简介（Actual null），GREEN 2/2；协调者独立复跑 folder/overview/source-field/TMDB 状态/nav/竞争/folder episodes/history-folder 共 89 个用例通过，相关4文件 analyze 无问题。同场景 1280×950 dark：[folder-before](screenshots/tmdb-overview/folder-before.png) / [folder-after](screenshots/tmdb-overview/folder-after.png)（After 显示分享链返回的简介）。

## 追加展示：TMDB 未匹配时的接口元数据

用户确认目录条目简介已显示，随后要求显示来源年份/演员等。新增 source_detail_meta.dart 将来源 Vod 的 year/type_name或vod_class/area/vod_lang/actor/director 映射到显示模型：复用现有标签行（年份、类型最多3项、地区、语言）和演职人员卡（演员/导演身份，显示-only负id不可点击），不造图片/评分；TMDB 匹配成功路径不变。

实际 DetailPage + TmdbMatchMiss 用例 RED（year finder=0）→ GREEN 5/5；相关旧回归201/201，协调者独立复跑 source-meta/overview/folder/hero/TMDB状态/nav/竞争共98/98，3文件analyze无issues。

角色归属修正（用户反馈）：来源导演不再计入「演职人员」，改为进入「制作团队」并标「导演」；演职人员只保留演员，与 TMDB 区块口径一致。RED 3 项 → GREEN 5/5；协调者独立复跑 83/83，mapper/测试 analyze 无问题。[修正前](screenshots/tmdb-overview/source-people-before.png)（导演混入演职人员）/ [修正后](screenshots/tmdb-overview/source-people-after.png)（演职人员4 演员 + 制作团队2 导演）。[同场景Before](screenshots/tmdb-overview/source-meta-before.png) / [After](screenshots/tmdb-overview/source-meta-after.png)（1280×950 DPR1 dark）；[演职人员After补充图](screenshots/tmdb-overview/source-meta-people-after.png)。已重新构建Linux release成功，需重启应用使用新snapshot。

## 构建产物（2026-11-14）

用户实测截图来自 11-13 12:37 的 release 构建，早于本轮全部 TMDB 修复（简介回退落于 11-13 23:43），因此该次结果不代表当前工作区。已用 `.local/linux-build/environment.sh` + `flutter build linux --release --no-pub --dart-define=APP_VERSION=0.1.0` 重新构建，输出 `Built build/linux/x64/release/bundle/webhtv_pc`。需重启应用后复测；若仍空白，则需该站详情接口原始响应确认是否真的返回了简介。

## 生命周期、裁定与验证边界

- 订阅key不持久化：切换作用域、重启或恢复数据后需重新导入/刷新原配置；剥离后的导出不携带key。设置内的用户凭据行为不变。
- complete遵循安卓现规则：episode/episode_videos空数据声明不额外拒收。畸形JSON仅出现字段名token也可能安全保守清洗，安卓同样如此。
- /tmp为2.2G tmpfs容量不足，改用磁盘TMPDIR；媒体单测使用现有sysroot libmpv，不改生产行为或安装依赖。
- 观察到一次原因未证明的慢解析反馈单测短暂失败：未改断言，最后62全绿，协调者隔离连续3次通过；不宣称已证明非flaky。
- 未跑全仓全部测试、第三方真实源/TMDB联网、Windows构建或设备集成；integration_test签名修复仅analyze，不描述为设备运行验收。
