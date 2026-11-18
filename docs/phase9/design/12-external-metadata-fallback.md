# 外部元数据兜底

## 已定范围

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
