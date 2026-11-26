# Windows 外链与 IMDb 评分元数据源实施记录

**Tier:** L2-Governed，访谈已收敛；**Topology:** Hybrid（共享解析/接线由 Lead，外链/来源模型/HTTP 客户端/迁移独立执行）。
**Goal:** Windows 外链交给默认浏览器；无 OMDb Key 仍能获取 IMDb 分，作为仅评分/人数的元数据来源。
**Settled:** 用户选择 IMDb 仅评分与人数、默认启用并在评分字段末位；不做标题搜索、不扩展简介海报。
**Constraints:** HTTP(S) URL 校验不放宽；Linux/macOS 行为不变；无新增依赖；不提交/推送；不更改真实 AppData 设置。

## Task book
- A win-browser-open run 1/3：ExternalUrl + windows_shell_open + external_url_test；已交 33 pass/1 skip，Lead 真机系统交接探针成功。
- B1 imdb-meta-source run 3/3：core 来源/管线/MetaQuery、ExternalMetaService、设置页过滤、3测试；85 pass，含 Bangumi score/value 归一修复。
- B2 imdb-rating-fetch run 3/3：HTTP service + DetailRatingService 与2测试；GraphQL 主/HTML 兜底、共享成功缓存与在途去重、启停与借用生命周期，40 pass。
- C imdb-preferences-migration run 2/3：ui_preferences_store + 新迁移测试 + crawler/phase2；独立 imdbRatingVersion=1 一次迁移，保留扩展字段。
- D imdb-integration-check run 1/3：仅新建 DetailPage widget 测试；确认单标签、设置开关、晚到 ID。
- Lead core：纯解析/接线/显示去重/配置失效/文档，独立 analyze、串行测试、最终 diff 验收。

## 决策与事实更正
- 最初 HKCR 读取未获得命令被误报为空；子代理复核命令存在。撤回 AppX/DelegateExecute 根因归因；只保留已观察到的用户故障与标准 ShellExecuteW 修复。
- 原检查误称没有 ui.metaPipeline；ConvertFrom-Json 证实存在 rating=[tmdb,douban,bangumi]。按用户默认启用选择新增独立一次迁移，不要求用户手动勾选。
- 标题页 202 WAF 挑战不含评分；同机 GraphQL POST 200 获 7.6 / 1234，采用 GraphQL 主 + HTML 单次兜底。非稳定公开接口，失败降级。
- 集成发现重复请求/重复 chip 及停用不生效：服务共享实例/缓存/在途去重，管线分原位替换，启停回调与页面失效一起落实。
- B1 发现 Bangumi rating.score 与 value-only 解析不匹配：最小兼容修复并补真实形态回归，未丢弃该缺陷。
- Lead HTML 解析探针证明数字前缀和 null 属性会误取评分：改为严格对象属性/JSON 数字解析，新增两条边界回归。

## 审查闭环
- 独立只读审查指出 active IMDb 身份跨作品泄漏、来源快照不响应异步失效、rating 最后一个来源取消后复活；全部退回 B1 run3，不以已有绿测豁免。
- B2 第3轮后 Lead 探针复现 OMDb-only 缓存开关与请求中停用泄漏；按 R8 任务级回退小修并加2条 regression，纯 Dart 探针已红绿。
- rating 允许显式空 order，与已有 title 空语义一致；C run2 同步空规则迁移测试，缺失/非法规则仍按默认回退。

## 验收
- 所有最终新建/修改代码读 diff，确认字段支持/身份安全/配置保留/启停/同页去重/失败隔离。
- Dart analyze lib 与修改测试无 issue，git diff --check 干净；Flutter 仅一执行者串行使用共享 native_assets 输出。
- Lead 重跑评分/外链/元数据/迁移/页面相关测试；真实 GraphQL 服务探针确认请求计数，成功不硬编码评分。
- 此次逻辑修复与现有设置列表新增行不改布局样式，无视觉回归重设计。
- 交付留工作区 diff；未重新发布打包应用，不能声称用户当前运行二进制已更新。

## 最终 Lead 验收（已通过）
- 最终 24 文件串行 suite：297 passed / 1 skipped / 0 failed，exit 0（build/imdb-lead-acceptance.log）；跳过项为 Windows 不适用的既有 POSIX 实进程测试。首次全组发现旧布局夹具关闭元数据却要求 IMDb 可见，改为本布局场景启用开关并注入无网络客户端服务，原断言未减；该文件与 UI/policy 先复验 21 passed，再全组重跑。
- dart analyze lib + IMDb/布局新回归文件：No issues found，exit 0（build/imdb-lead-final-analyze.log）。
- Lead 真实服务：tt34852924 GraphQL 200，7.6 / 1,234；同ID两次并发与一次顺序查询仅1次网络，返回对象共享（build/imdb-lead-live.log）。
- 独立复审 run2：Spec PASS / Quality PASS，原 active ID 串作品、异步规则失效、最后来源复活均 ADDRESSED，未发现修复新增缺陷；Lead 已读最终生产 diff 与回归断言。
- 风险闭环：WAF 页面不可解析→GraphQL主/一次HTML兜底并真实网络验证；重复请求/标签→共享实例和去重；禁用与旧缓存→状态分键/在途滤分；旧设置→独立一次迁移/显式空保留；跨作品→query绑定与代数失效。未留下已知未修复阻塞缺陷。
- 残余外部限制：IMDb GraphQL 不是稳定公开 API，评分/投票数会变化；不可达时仅隐藏该评分，OMDb 配置仍可作为来源。不包含重新打包/替换安装二进制。未提交/未推送。
- 路由记录：本 Session 未记录子代理路由 allowlist；显式使用可列举的 deepseek-official/deepseek-v4.1-flash，未宣称路由已被授权强制。
