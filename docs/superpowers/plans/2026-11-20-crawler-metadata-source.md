# 当前资源爬虫元数据来源实施计划

**Goal:** 将当前资源自身数据作为可排序、可停用的元数据来源，默认最低优先级兜底。
**Tier / Topology:** L2-Clear / Hybrid：Lead 已冻结来源模型与默认规则；单一执行者完成紧耦合的服务、持久化和页面接入，Lead 独立验收。
**Basis:** 本次用户逐项选择；现有设计 docs/phase9/design/12-external-metadata-fallback.md。

## 已定范围
- source / 爬虫源 = 当前 Vod 自身，非新增爬虫、不联网、不具备外部作品/人物身份。
- 支持标题、简介、海报、背景图、演职人员、制作团队、类型、地区、语言、上映日期十字段；其余五字段不列出它。
- 默认排每字段最后；启停和拖动必须影响实际显示，含标题。priority 首个非空；aggregate 列表依序去重合并，标量取首个非空。
- 原始 Vod、可播线路、TMDB/人物身份与季集归属不改变；字段缺失不造占位。
- 旧配置一次追加末位爬虫源，用户之后明确停用后重启不复活。关闭外部元数据时仅停止外部来源，保留 TMDB/爬虫字段规则。

## Task 1 — Lead 模型接缝（run 1，完成）
- core/meta_source.dart: MetaSourceKind.source，key source / label 爬虫源。
- core/external_meta.dart: 爬虫源不得构造外部 MetaIdentity；人物引用同样禁止。
- core/meta_pipeline.dart: 十字段默认追加 source；supportsSource / withSourceFallbackAdded。
- test/crawler_meta_pipeline_test.dart、test/meta_pipeline_test.dart：先红后绿，11 tests passed。

## Task 2 — 集成执行（run 3/3，已通过 Lead 验收）
- 读取核心接口后，先写失败测试，再实现实际逐字段解析：不得由单一主来源标签掩盖字段真实来源，爬虫源可以位于任意外部来源前后。
- 仅读取传入的当前 Vod 构建 sourceDetailMeta，取数时不得再用 enrich 后的 Vod 假充爬虫源。
- 设置页沿用列表组件：十字段中显示可勾选/排序爬虫源；保持其它选项及模式；修复规则捕获过期导致设置不刷新的问题。
- 持久化规则迁移需要版本标识，允许未知旧字段，保留已有外部顺序；显式停用往返持久化不复活。
- ExternalMetaService 的 switch 补 source，禁止外部 source 候选/身份检索；现有评分/评论/照片聚合保留。
- 详情 hero 的标题、简介、背景、人员/类型等必须实际消费解析后的字段，不得残留无条件站源 fallback；保留非配置字段、networks、tmdbId 等。
- 增加规则重排/停用、默认末位补空、外部失败、TMDB 已匹配且缺字段、标题优先级、旧设置迁移与重启、设置 widget 实际交互测试。

## Task 3 — Lead 验收（run 3，已通过）
- 读 final diff；相关模型/服务/页面/持久化测试；dart analyze lib（基线 No issues found）。
- 核对无越界身份、无旧资源串页、无无条件站源兜底、无丢失 TMDB 非配置字段、无禁用后复活。
- UI 仅添加现有列表行/文案，无样式布局重设计；若发生回归风险样式改动，要求同场景截图证据。
- 更新既有设计文档；不提交、不推送，保留工作区 diff 交付。

## 工具链
在 apps/desktop-flutter：FLUTTER_ROOT=/home/maple/tools/webhtv-linux-sdk/flutter-3.47.5 FLUTTER_ALREADY_LOCKED=true；使用 bin/cache/dart-sdk/bin/dart 执行 bin/cache/flutter_tools.snapshot --no-version-check test --no-pub --reporter expanded；dart analyze lib。

## 审查记录
- Lead 基线：meta_pipeline + source_detail_meta 13 tests passed；analyze lib No issues found。
- 模型新增测试见 /tmp/crawler-model-red.log（断言失败），最终 core /tmp/crawler-core-green.log（11 passed）。
- 子任务报告 Lead 身份 guard 的 multiline if 缺大括号 lint；已修正。单文件 analyze No issues found，crawler_meta_pipeline 3 tests passed（/tmp/crawler-core-lint-regression.log）。
- Lead 首次独立回归：91 tests passed，analyze lib No issues found（/tmp/crawler-lead-acceptance.log、/tmp/crawler-lead-analyze.log）。
- 未通过边界探针：十字段 source-first 且资源齐全时 primary 为 null，已启用 photos 聚合被跳过。/tmp/crawler_lead_photo_probe_test.dart 失败证据 /tmp/crawler-lead-photo-probe.log；退回原执行者 run 2/3 修复。
- 独立审查另确认 load 自动迁移调用全量 _persist，启动时删除未知 ui/rule 字段；同一 run 2 要求用共享 writer 原地迁移并增加嵌套未知字段保留测试。
- 独立审查确认 work-field 配置变更清空评论，但独立 commentsKey 未失效；一并修复评论生命周期并防止把 TMDB/Bangumi 数字身份发给豆瓣，补存量评论与分页不受十字段排序影响的测试。
- 补充独立回归：其余元数据 65 passed，设置 shared-writer/atomicity/retry/preferences 37 passed（/tmp/crawler-lead-additional.log、/tmp/crawler-lead-settings.log）。
- 第二轮独立全部回归 202 passed（含 Lead 剧照探针），analyze clean（/tmp/crawler-lead-run2-all.log）。
- 第二轮 scoped review：F1 剧照、F3 迁移、E1 命名空间已通过；F2 尚有 setMetaPipeline 全局 clearCache 使加载中独立评论变为空、页内代数未变化的问题。最后 run 3 要求协调失效，保持已完成评论，覆盖 in-flight 首页/分页及 comments rule/禁用/换页失效。
- 执行者第 3 轮：gated HTTP 首页与分页先红后绿，comments 独立 epoch；205 tests passed，analyze clean。
- Lead 最终新鲜验证：27 个仓库测试文件加独立剧照探针共 220 tests passed，dart analyze lib No issues found，git diff --check clean（/tmp/crawler-lead-run3-all.log、/tmp/crawler-lead-run3-analyze.log）。使用串行与磁盘 TMPDIR 避免 tmpfs ENOSPC；测试后已验证绝对路径并移除空临时目录。最后 scoped review（/tmp/crawler-review-run3-report.md）Spec PASS / Quality PASS，R2-F1/F2 已关闭，F1/F3/E1 保持已修复，未发现新的修复波次缺陷。Lead 已读最终生产代码差异及新增异步测试并接受；未提交/推送。
