# 外部元数据兜底

## 当前资源爬虫源（2026-11-20）

本节优先于下面早期兜底方案中的「来源标题不改」与「仅 TMDB 不可用」限制；播放身份和线路约束继续保持。

- 新来源 `source`（显示「爬虫源」）仅读取当前资源原始 `Vod` 已有字段，不新增爬虫或网络请求，没有外部作品/人物身份。
- 十个作品字段支持它：标题、简介、海报、背景图、演职人员、制作团队、类型、地区、语言、首播/上映。默认末位兜底，支持勾选和拖动；评分、剧照、评论、人物简介、人物照片不列它。
- 字段顺序决定实际显示，包括标题及已匹配 TMDB 的页面。优先模式取首个非空值；聚合模式中列表按顺序合并去重，单值仍取首个非空。
- 禁用爬虫源后不得再由详情页无条件回填；爬虫源数据不得使用 TMDB enrich 后的数据冒充。外部来源关闭仅停止外部请求，不关闭已有 TMDB/当前资源数据。
- 旧规则一次追加爬虫源到末尾并记录版本；保留已有外部来源的排序/启停。启动迁移仅原地修改元数据规则及版本，保留未知 UI/规则字段；写失败保留原文件、下次启动重试。用户之后停用爬虫源并重启不会重新启用。
- 剧照和评论独立于十个作品字段：只用爬虫字段时仍按各自规则加载剧照/评论。评论使用真实豆瓣身份与独立请求代际，普通字段重排及手动匹配不取消加载中的评论；评论规则变更、禁用、刷新及换页仍隔离旧结果。
- 展示标题可以改变，原始 Vod 标题、资源 ID、播放线路、可播剧集与 TMDB/人物身份不改；不虚构评分或缺失信息。
- 实施任务和验收记录见 [当前资源爬虫元数据来源实施计划](../../superpowers/plans/2026-11-20-crawler-metadata-source.md)。

## 早期方案已定范围

- 豆瓣优先；查不到、歧义或接口失败后再试 Bangumi。
- 仅在 TMDB 未配置、关闭、未匹配或请求失败时使用；正常匹配页维持原行为。
- 默认开启，可在 TMDB 设置中独立关闭，开关持久化到 settings.json 的 ui 段。
- 缺少简介、海报或人员字段时继续使用站源已有数据，不造占位资料。
- 人物页显示基本信息、可取得的简介和作品列表；不为补简介绕过登录或验证码。

## 接缝与数据约束

1. ExternalMetaService.detail(MetaQuery) / person(MetaPersonRef) 隐藏网络、匹配与适配复杂性。
2. MetaIdentity 与 MetaPersonRef 带来源，外部作品没有 TmdbIdentity；播放器、季集归属和追番身份不改。
3. 外部详情适配为 TmdbDetailData，但评分与来源链接显式使用豆瓣/Bangumi 品牌。人物作品没有 TMDB 身份时按标题搜索站源。
4. 页面只接受当前作品/请求代际的结果；正在匹配 TMDB 时先等匹配结束。关闭开关或成功匹配 TMDB 后不显示迟到的外部结果。
5. 来源题名和播放线路不改。元数据只丰富显示，缺失字段回退站源；外部集数不增删可播剧集。

## 实施与验收计划

拓扑：Lead-Core 接页面、配置和共享模型；既有 Bangumi 子任务独立验收，run cap 3。

- 匹配及适配：标题清洗、年份/季号冲突拒绝、电影/剧集类型、重名歧义；外部人员与作品身份隔离。持久化测试覆盖真实载荷的封面、日期、演职员身份、简介和作品筛选。
- 客户端：Bangumi 查询动画/三次元，所有尝试串行限速且有限超时；豆瓣复用既有队列/缓存/风控冷却。辅助演职员请求失败不丢掉已取得的详情。
- 设置：ui.externalMetaEnabled 缺席为 true，写入 false 后重启可读，关闭时中止后续外部补全，开关不依赖 TMDB enabled。
- 页面：无 TMDB 的详情保留来源信息，补入来源标签/评分/人员；人员可点、作品可按标题搜索。正常 TMDB 页不发外部补全请求。
- 验证：Flutter 模型、客户端、偏好与 widget 测试；同场景暗色 1280×950 的 Before/After capture（无可靠 Before 时仅 After 并说明）；最终 diff 无无关格式变化。

## 数据源与退化

Bangumi 官方文档：<https://github.com/bangumi/api>、<https://bangumi.github.io/api/>。v0 search/subjects（POST，类型 2/6）、subjects、persons、person subjects；infobox 值有字符串和列表两种形状。

豆瓣公开页面：<https://movie.douban.com/tv/>。当前可用的 subject_suggest、rexxar tv/movie detail/credits、celebrity/works 不是稳定公开合同；不携带用户 Cookie，不绕过 sec.douban.com 验证。返回风控时沿用冷却并回退缓存或来源字段。

豆瓣 celebrity 当前载荷没有 biography，不能承诺每个人都有简介；Bangumi person summary 有则显示。此轮不额外引入未经验证的第三方人物站，缺失保留已有内容。

## 验证命令

在 apps/desktop-flutter 运行：

```bash
export FLUTTER_ROOT=/home/maple/tools/webhtv-linux-sdk/flutter-3.47.5
export FLUTTER_ALREADY_LOCKED=true
"$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot" --no-version-check test --no-pub test/external_metadata_model_test.dart --reporter expanded
```
