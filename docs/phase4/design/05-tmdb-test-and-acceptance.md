# 05 · TMDB 测试与验收设计

- 状态：设计指导，**已实施**（门禁见 `docs/phase4/README.md` §3，证据见 `docs/phase4/evidence/windows-acceptance.txt`）
- 日期：2026-10-06
- 上游参考：Phase 1/2/3 的门禁与证据机制（`docs/phase1/README.md` §7、`docs/phase2/README.md` §3、`docs/phase3/README.md` §3）
- PC 端落点：`apps/desktop-flutter/test/phase4_*.dart`、`apps/desktop-flutter/integration_test/tmdb_*_flow_test.dart`、`packages/test-fixtures/tmdb/**`、`tools/phase4/**`
- 关联：`00`–`04`

---

## 1. 测试分层

沿用 Phase 3 的三层结构，不引入新机制：

| 层 | 位置 | 是否需要真实网络 | 是否需要真实窗口 | 运行命令 |
| --- | --- | --- | --- | --- |
| L1 纯逻辑单测 | `test/phase4_tmdb_*.dart` | ❌（全内存） | ❌ | `flutter test` |
| L2 契约与 fixture | `tests/test_contracts.py`、`test/phase4_tmdb_service_test.dart` | ❌（进程内 fake HTTP） | ❌ | `flutter test` + `py -3 -m unittest` |
| L3 集成 | `integration_test/tmdb_*_flow_test.dart` | ✅（本地 fixture 服务） | ✅（`-d windows`） | `flutter test integration_test/... -d windows` |

**分层原则**（对齐 Phase 3）：

- L1 必须能在**无网络、无窗口**环境下全绿，覆盖全部算法与边界；
- L2 用**请求捕获**断言请求形态（URL、query、Header），不只断言最终解析结果；
- L3 只验证"真实窗口 + 真实播放器 + 真实 HTTP"的端到端串联，**不重复 L1/L2 的边界用例**。

---

## 2. fixture 设计

### 2.1 目录

```text
packages/test-fixtures/tmdb/
├── configuration.json              # /configuration 响应
├── search-multi.json               # /search/multi?query=…（含 movie + tv + person）
├── search-empty.json               # 空结果
├── search-split-season.json        # 含"分季"变体的结果
├── detail-tv.json                  # /tv/{id}（含 seasons[]、credits、recommendations、similar）
├── detail-tv-next-air.json         # 含 next_episode_to_air（验证动态 TTL）
├── detail-movie.json               # /movie/{id}
├── season-1.json                   # 12 集
├── season-2.json                   # 10 集
├── season-0.json                   # 特别篇 3 集
├── season-empty.json               # episodes 为空
├── episode-s1e1.json
├── person.json                     # combined_credits + images
├── videos-tv.json                  # 含合法 key、非法 key、多语言、多 type
├── recommendations-page1.json
├── recommendations-page2.json
├── recommendations-empty.json
├── error-401.json                  # 鉴权失败
├── error-500.json
├── malformed.json                  # 非法 JSON
└── config/
    ├── tmdb-config-full.json       # 全字段
    ├── tmdb-config-alias.json      # 别名键（apikey/api_key/token/…）
    └── tmdb-config-invalid.json    # 非法值（含 JWT 判定边界）
```

### 2.2 fixture 服务路由

在既有 `tools/fixture_server/server.py` 增加 `/tmdb/...` 路由，**复用同一进程与端口**（18080）：

| 路由 | 行为 |
| --- | --- |
| `GET /tmdb/configuration` | 返回 `configuration.json` |
| `GET /tmdb/3/search/multi?query=X` | 按 query 选择 fixture；`query=empty` → `search-empty.json` |
| `GET /tmdb/3/tv/{id}` | `detail-tv.json`（`id=2` 时返回 `detail-tv-next-air.json`） |
| `GET /tmdb/3/movie/{id}` | `detail-movie.json` |
| `GET /tmdb/3/tv/{id}/season/{n}` | `season-{n}.json`；`n=9` → `season-empty.json` |
| `GET /tmdb/3/tv/{id}/season/{n}/episode/{e}` | `episode-s1e1.json` |
| `GET /tmdb/3/person/{id}` | `person.json` |
| `GET /tmdb/3/{type}/{id}/videos` | `videos-tv.json` |
| `GET /tmdb/3/{type}/{id}/recommendations?page=N` | `recommendations-page{N}.json`；`page=9` → 空 |
| `GET /tmdb/3/{type}/{id}/similar?page=N` | 同 recommendations |
| `GET /tmdb/auth-fail` | 401（验证熔断） |
| `GET /tmdb/server-error` | 500 |
| `GET /tmdb/malformed` | 返回非法 JSON |

**断言支持**：路由必须把收到的 `api_key` / `Authorization` / `language` / `include_image_language`
写入**响应头**（例如 `X-Fixture-Seen-Query`），供请求捕获测试断言，而不用抓包。

### 2.3 请求计数器

fixture 服务提供 `GET /tmdb/__stats` 返回各路由命中次数（JSON）。
L2 用它断言"未配置 / 站点禁用时零请求"（`01` §12 第 9 项）。

---

## 3. L1 纯逻辑单测清单

### 3.1 `test/phase4_tmdb_title_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 标题清洗 13 步 | 每组至少 1 例；步骤顺序敏感（先剥扩展名再剥括号） |
| 2 | `《书名》` 提取 | `《庆余年》 第1季` → 提取 `庆余年`，不是丢弃 |
| 3 | 中文数字季度 | `第二季` / `第十二季` / `第〇季` → 2 / 12 / 0 |
| 4 | 清洗兜底 | 全噪声输入 → 返回原始输入（非空） |
| 5 | 年份提取 | `2024` / `20240115` / `(2024)` / `20240`（不匹配） |
| 6 | 季度信号 | `S01E02` / `Season 3` / `第2部` / 无信号 → -1 |
| 7 | 排序键顺序 | 相似度 > 年份距离 > 语言偏好 > 评分 |
| 8 | 相似度公式 | 相等 1000；包含 800+200*min/max；编辑距离边界 |
| 9 | 语言偏好 | zh-CN 对 CN/HK/TW/MO/SG 各 +25；ja/JP；ko/KR |

### 3.2 `test/phase4_tmdb_match_policy_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 分季变体四档 | `+140` / `0` / `+160` / `-240` 精确值 |
| 2 | 显式季度正则 | `第1季`/`season 2`/`s01e02` 命中；`第一`/`s01` 边界 |
| 3 | `isUnwantedSplitSeasonVariant` | 含分季 + 源不允许 → `true` |
| 4 | 推送守卫 | URL / 通用标题 / 无中文 / 纯数字 → `false`；正常标题 → `true` |
| 5 | 归一化 | `[\s·•:：\-_/\\\|()（）\[\]【】]+` 全被剥离 |

### 3.3 `test/phase4_tmdb_site_policy_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 判定顺序 7 条 | 逐条独立用例；黑名单精确 > 白名单精确 > 启用精确 > 黑名单子串 > 空启用 → true > 启用子串 > false |
| 2 | 括号归一 | `「音」` 被 `[音]` 命中；`【设】配置` 被 `配置` 命中 |
| 3 | 不可互换 | `[书]` **不**命中 `[小说]xxx`；`[漫]` **不**命中 `[漫画]xxx` |
| 4 | 默认规则 | 未配置时启用 11 条默认规则 |
| 5 | `excludeKeywordsConfigured` | 显式 true/false 语义 |
| 6 | 站点解析 | 传入 key 找不到站点时按传入值判定 |

### 3.4 `test/phase4_tmdb_cache_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 三层键读取顺序 | 手动条目级 → 条目+标题 → 条目级（需兼容）→ 标题域（需兼容） |
| 2 | 同 `vodId` 多作品 | 条目级锚点只在标题指向同一作品时生效 |
| 3 | 手动不被覆盖 | `put` 在手动条目存在时**不写** |
| 4 | 标题域冲突 | 手动 vs 手动且身份不同 → `TmdbMatchConflict` |
| 5 | 标题域覆盖 | 手动 vs 自动 → 手动保留；同身份 → 覆盖 |
| 6 | 富集后读回 | `vodName` 被改写成 TMDB 标题后仍能读回手动结论 |
| 7 | 空标题兼容 | 源标题为空 → 直接读条目级键 |
| 8 | 归一化键 | 不同标点/空格写法映射到同一键 |

### 3.5 `test/phase4_tmdb_season_resolver_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 判定顺序 15 步 | 每步 ≥ 1 用例，断言 `status` + `source` + `reason` 三元组 |
| 2 | 后级不覆盖前级 | 构造"请求季度 + 手动绑定冲突"→ 取请求季度 |
| 3 | `requestSeason` 不在 TMDB | `ambiguous(requested_season_missing_from_tmdb)` |
| 4 | `manualMultiSlice` 分段失效 | → 重算；重算也失败 → `manual_multi_slice_stale` |
| 5 | 多显式季度冲突 | 含标题季度冲突 / 含非 TMDB 季度 → `multiple_explicit_seasons` |
| 6 | 单显式季度 + 标题冲突 | `title_and_source_season_conflict` |
| 7 | 单普通季度 | `allowHeuristicGuessing=true` → resolved；`false` → `heuristic_guessing_disabled` |
| 8 | 仅特别篇 | `tmdbSeasons == [0]` → resolved(0, `specials_only`) |
| 9 | 精确集数唯一/重复 | 唯一 → resolved；重复 → `duplicate_episode_counts` |
| 10 | 全季切片 | `canSliceBySeasonCounts` 为真 → `all_season_counts` |
| 11 | 扁平集号 | 多季映射 → `flat_episode_keys` |
| 12 | 证据不足 | → `insufficient_season_evidence` |
| 13 | `ambiguous` 不落盘 | 用 fake store 断言**零写入** |
| 14 | 不覆盖旧绑定 | 已有高置信绑定 + 新 `ambiguous` → 旧绑定不变 |

### 3.6 `test/phase4_tmdb_available_seasons_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | A1 完整显式映射 | 返回 TMDB 顺序的季度子集 |
| 2 | A2 部分映射唯一季度 | → 单季 |
| 3 | A2 部分映射多季度 | → 空（扁平） |
| 4 | A2 含非 TMDB 季度 | → 空 |
| 5 | B 标题季度 | 含于 TMDB → 单季；不含 → 空 |
| 6 | C 单一 TMDB 季度 | → 单季 |
| 7 | D 精确切片 | → sliceable seasons |
| 8 | E 扁平集号多季 | → 该集合 |
| 9 | F 单季兼容 | `firstSeasonCount >= sourceEpisodeCount` 且不可切片 |
| 10 | G 其他 | → 空 |
| 11 | UI 矩阵 7 行 | 每行断言 `availableSeasons` + `episodesToRender.length` |
| 12 | 不补集 | 线路 `E01,E02,E04` → 渲染 3 项，**不含** `E03` |
| 13 | 不丢集 | 部分集有季度 → 全部渲染 |

### 3.7 `test/phase4_tmdb_segment_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 分段有效性 8 条 | 每条独立用例（含"不连续"与"未完整覆盖"两个关键反例） |
| 2 | `flatSeasonSegments` | 连续且完整 → 分段；出现回头季 → 空；集号跳跃 → 空 |
| 3 | 段长越界 | `tmdbEpisodeStartNumber + len - 1 > count` → 无效 |
| 4 | 单段 | `segments.size() < 2` → 视为无效 |

### 3.8 `test/phase4_tmdb_progress_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 写入规则 | `KnownSeason` 写；`MultiSeason` 写对应段季；`UnknownSeason` **不写**；电影不写 |
| 2 | 不覆盖 | 播放 S2 后 S1 快照不变 |
| 3 | 读取顺序 | 季度进度 → 来源历史 → 同季度候选 → 不跨季 |
| 4 | 历史投影键 | 三种键形态；同节目多季生成多卡片 |
| 5 | 来源聚合 | 按线路去重取最新；排除 `currentRoute` |
| 6 | 换源兼容 5 条 | accepts/rejects 逐条 |
| 7 | 删除语义 4 条 | 含"多季度线路删 S1 不动 S2" |
| 8 | 指纹 | 稳定指纹不含 URL；结构指纹含季度映射 |
| 9 | 迁移 | `seasonNumber = 0` 无特别篇证据 → `UnknownSeason` |

### 3.9 `test/phase4_tmdb_config_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | `sanitize()` 13 条 | 逐条断言归一化结果 |
| 2 | 别名键 | `apikey` / `api_key` / `tmdbApiKey` / `key` 均生效 |
| 3 | JWT 判定 | `a.b.c` 形态保留 `accessToken`；与 `apiKey` 相同的非 JWT 被清空 |
| 4 | `imageBase` 归一 | `stripImageSize` 反复剥离；补 `/t/p/w342` |
| 5 | `backdropBase` 推导 | 为空且 imageBase 是图片主机 → 推导 w780 |
| 6 | `isReady` | 仅 Key / 仅 Token / 都空 / `enabled=false` |
| 7 | 往返 | `toJson` → `objectFrom` 幂等 |

### 3.10 `test/phase4_tmdb_image_selector_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 排序键 4 条 | sourceRank > 像素面积 > vote_average > vote_count |
| 2 | 方向回退 | 首选为空 → 另一方向 |
| 3 | 去重 | 同 URL 只出现一次 |
| 4 | `limit` | `<= 0` 不限；`> 0` 截断 |
| 5 | URL 拼接 | 空 base/path → `""`；已是 http(s) → 原样；末尾斜杠去重 |

### 3.11 `test/phase4_tmdb_episode_metadata_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 未知季度**不应用** | `episodeMetadataSeasonCandidates(-1)` → `[]`（反向：若改回 `[1,0]` 则失败） |
| 2 | 已知季度 | → `[n]` |
| 3 | 集号对齐 | 重复/缺失/越界 → 按位；否则按号 |
| 4 | 迟到响应丢弃 | 代数不匹配 → 不应用 |
| 5 | 季集数变化 | `hasEpisodeMetadataChanged` → 放弃应用 |
| 6 | 多线路隔离 | `KnownSeason` 只作用于对应线路 |
| 7 | 分段应用 | `MultiSeason` 每段只应用本段集数 |
| 8 | 保留原始名 | 无法识别季度 → 来源集名不变 |

---

## 4. L2 契约与服务测试

### 4.1 `test/phase4_tmdb_service_test.dart`（进程内 fake HTTP）

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 鉴权形态 | 有 Token → `Authorization: Bearer …` 且**无** `api_key`；无 Token → `api_key` query |
| 2 | 语言参数 | `language` 与 `include_image_language` 正确拼接 |
| 3 | TTL 新鲜命中 | age < ttl → 不发请求（fake client 计数为 0） |
| 4 | TTL 过期 | age > ttl → 发请求并覆盖缓存 |
| 5 | 陈旧兜底 | 网络失败 + 陈旧缓存存在 → 返回陈旧且 `source=stale-cache` |
| 6 | 陈旧兜底缺失 | 网络失败 + 无缓存 → 抛原始错误 |
| 7 | `refresh` | 跳过新鲜命中；仍保留陈旧兜底 |
| 8 | 动态详情 TTL | `next_episode_to_air` 非空 → 用短 TTL |
| 9 | 视频缓存分档 | 空结果 30 分钟；非空 6 小时 |
| 10 | 熔断开启 | 401 → 后续请求**零网络**（fake client 计数不变） |
| 11 | 熔断恢复 | 推进时钟 5 分钟 → 恢复请求 |
| 12 | 熔断按凭据隔离 | 换 Key → 立即可用 |
| 13 | 取消 | 取消时不写缓存、不落盘 |
| 14 | 错误映射 | 401/403→`tmdbAuth`；网络→`tmdbNetwork`；500→`tmdbHttp`；非法 JSON→`tmdbDecode`；空字段→`tmdbEmpty` |
| 15 | 未配置 | 抛 `tmdbNotConfigured` 且**零请求** |
| 16 | 详情回退键 | `includeRelated=false` 可命中 `true` 的缓存 |
| 17 | 缓存不可写 | 目录只读 → 降级为不缓存，返回值正常 |
| 18 | 单文件上限 | 响应 > 8 MiB → 不写缓存并记日志 |

### 4.2 `test/phase4_tmdb_storage_test.dart`

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 建表 | `schemaVersion = 2`；四张新表存在 |
| 2 | 迁移幂等 | 旧库（version 1）打开两次 → 新表存在且旧数据不变 |
| 3 | 匹配往返 | 写入 → 读取字段全等 |
| 4 | 绑定往返 | 三种 `mode` 各自往返；`segments` JSON 往返 |
| 5 | 线路绑定上限 | 513 条 → 淘汰最旧至 512 |
| 6 | 进度主键 | 同 `(configId, mediaType, tmdbId, seasonNumber)` 覆盖而非新增 |
| 7 | 清理边界 | 重置缓存不动 SQLite；清空历史清 `tmdb_season_progress` 但保留 `tmdb_matches`/`tmdb_season_bindings` |
| 8 | 写失败隔离 | 注入异常 → 匹配/播放结果不受影响 |

### 4.3 `tests/test_contracts.py` 新增用例

| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | `tmdb-config-full.json` 通过 `packages/protocol/schema/tmdb-config.schema.json` | 合法 |
| 2 | `tmdb-config-alias.json` 通过 | 合法（别名键不被 schema 拒绝） |
| 3 | `tmdb-config-invalid.json` **不通过** | 校验失败（反向验证） |
| 4 | 未知字段保留 | fixture 内的 `futureField` 原样存在 |
| 5 | fixture 目录完整性 | `packages/test-fixtures/tmdb/` 下 §2.1 列出的文件全部存在 |

### 4.4 `test/phase4_tmdb_ui_test.dart`（widget）

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 状态条 6 态 | 每种状态渲染对应控件；未配置 → 渲染「未配置 TMDB」+「去设置」；站点禁用 → 区块**不渲染** |
| 2 | 头部补位 | 来源字段非空 → **不变**（8 个字段逐条） |
| 3 | 骨架屏尺寸 | 骨架与最终内容高度差 ≤ 1 px |
| 4 | 季度选择器 | 单季不显示切换；多季显示分段；`UnknownSeason` 显示"选择季度" |
| 5 | 选集数量 | `episodesToRender.length == 该季线路剧集数` |
| 6 | 切换季度 | 旧剧集被清空；续播位置同步 |
| 7 | 手动匹配弹窗 | 打开即搜索；`tmdb:` 直达；结果排序 |
| 8 | 季度绑定弹窗 | 候选集数/年份；切片失败禁用 + 原因；风险提示阈值 |
| 9 | 相关视频 | 非法 key 被过滤；打开失败 → 复制链接兜底 |
| 10 | 键盘 | `Tab`/`Esc`/方向键/`Enter` 全流程 |
| 11 | 失败隔离 | `tmdb*` 错误只影响 TMDB 区块；文案含"不影响站源浏览与播放" |
| 12 | 设置页 | Key 掩码与显示切换；测试连接；重置默认规则二次确认 |

### 4.5 `test/phase4_tmdb_detail_model_test.dart`（纯逻辑）

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 头部字段 | 海报/原名/标语/评分/年份/时长/季集数/类型/地区逐项断言 |
| 2 | 导演来源 | `credits.crew` 的 `Director` 优先；无 crew 时回退 `created_by` |
| 3 | 剧照语义 | `photoUrls` 取 `images.stills`；无剧照时回退背景图；`stillUrls` 不回退 |
| 4 | 背景图 | `images.backdrops` 优先、按面积降序、再回退根级；无背景图时回退海报 |
| 5 | 轮播策略 | 单张不轮播；环形推进；下标夹取；节奏 5 秒 |
| 6 | 剧集卡片 | 按集号对齐；不补集（TMDB 10 集 / 线路 8 集 → 8 张）；不丢集（无元数据仍出卡片）；集号不可靠按位对齐 |
| 7 | 剧照回退 | 该集无剧照时按序取回退池 |
| 8 | 查看器 | 定位到被点击那张；首尾环绕；单张不可翻页；空列表安全 |
| 9 | 人物作品 | `combined_credits` cast/crew 解析 + 按身份去重 + 非法条目过滤 |

### 4.6 `test/phase4_tmdb_detail_view_test.dart`（widget，视觉回归）

| # | 用例组 | 关键断言 |
| --- | --- | --- |
| 1 | 动态背景 | 渲染第一张；假时钟推进 5 秒后换第二张；再推进环形回第一张；单张不轮播；无背景图回退海报 |
| 2 | 头部 | 海报 `Image.network` URL 正确；标题/导演/评分/年份/时长/季集数/类型均出现 |
| 3 | 剧集卡片 | 每张卡片的剧照 URL 正确；集号徽标 `S1E1`；标题与日期；点击回调携带渲染下标 |
| 4 | 单集弹窗 | 剧照/标题/简介渲染；动作按钮触发回调 |
| 5 | 剧照墙 | 点第 N 张 → 查看器定位第 N 张；翻页环绕；关闭 |
| 6 | 演职人员 | 点击回调携带该人物 |
| 7 | 相关推荐 | 点击回调携带该作品 |
| 8 | 纯 TMDB 约束 | 动作文案为「搜索站源」，无「播放」 |
| 9 | 键盘 | 查看器 `←/→` 翻页、`Esc` 关闭 |
| 10 | 布局 | 900 px 宽不溢出；1600×2600 整页渲染关键区块齐全且无溢出 |
| 11 | 失败隔离 | 空数据时四个区块整块不渲染 |

---

## 5. L3 集成测试

### 5.1 `integration_test/tmdb_detail_flow_test.dart`

```text
前置：fixture 服务（含 /tmdb 路由）+ 一份指向 fixture 站点的配置
步骤：
  1. 打开 fixture 站点详情页
  2. 断言 TMDB 状态条从"匹配中"变为"已匹配"
  3. 断言头部增强字段已应用（简介/海报补位）
  4. 断言季度选择器显示"第 1 季"
  5. 断言选集区 12 项，标题为 TMDB 剧集标题
  6. 切换到"第 2 季"，断言选集变为 10 项且标题已更新
  7. 断言"TMDB 有 S2E10 但线路 S2 只有 8 集"时不出现第 9/10 项
```

### 5.2 `integration_test/tmdb_playback_flow_test.dart`

```text
步骤：
  1. 从详情页点击 S1E2
  2. 断言播放页收到 seasonNumber=1, episodeNumber=2, episodeUrl=<来源 URL>
  3. 断言真实出画（对齐 Phase 1 的首帧检测方式）
  4. 退出播放页，断言写入季度进度（season=1, episode=2）
  5. 进入详情页，断言续播位置恢复
  6. 切换到同一季度的另一线路，断言仍恢复 S1E2（换源续播）
```

### 5.3 `integration_test/tmdb_manual_match_flow_test.dart`

```text
步骤：
  1. 打开一个匹配失败的 fixture 详情页
  2. 点击"匹配 TMDB"→ 搜索 → 选定作品
  3. 进入季度绑定 → 选定"第 1 季"
  4. 断言详情页状态显示"手动：第 1 季"
  5. 返回列表再进入同一详情 → 断言手动结论仍生效（持久化）
  6. 点击"仅选季度"→ 改选"第 2 季"→ 断言选集与季度进度同步切换
  7. 点击"自动（清除手动绑定）"→ 断言回到自动解析结果
```

### 5.4 `integration_test/tmdb_failure_isolation_flow_test.dart`

```text
步骤：
  1. 让 fixture 的 /tmdb/auth-fail 成为唯一响应（模拟 401）
  2. 打开详情页
  3. 断言 TMDB 区块显示鉴权错误文案
  4. 断言线路选择与选集**照常可用**
  5. 断言能成功播放（TMDB 失败不阻塞播放）
  6. 断言熔断生效：再次进入详情页时 /tmdb/__stats 计数不增加
```

### 5.5 `integration_test/tmdb_tmdb_only_detail_flow_test.dart`

```text
步骤：
  1. 通过 TMDB 搜索进入纯 TMDB 详情页
  2. 断言季度选择器显示 TMDB 全部季度（含不可播放季度）
  3. 断言剧集卡片**没有**播放按钮
  4. 点击剧集卡片 → 跳转到搜索页并带入标题
  5. 断言搜索结果中出现 fixture 站点条目
```

### 5.6 `integration_test/tmdb_detail_visual_flow_test.dart`

```text
前置：fixture 服务（含 /tmdb 与 /tmdb-img 路由）+ 指向 fixture 站点的配置
步骤：
  1. 进入站点详情页，等待 TMDB 匹配 + 详情 + 剧集元数据
  2. 断言动态背景有多张图，且全部来自 TMDB 图片主机
  3. **真实解码**两张背景图（NetworkImage → 完成回调）证明图片真能加载
  4. 断言当前线路的剧集卡片带 TMDB 剧照（key 含线路标识），并真实解码一张剧照
  5. 断言头部有海报 / 导演 / 评分 / 时长 / 季集数
  6. 点剧照第 2 张 → 查看器打开且定位到第 2 张 → Esc 关闭
  7. 点演职人员 → 人物页（简介 / 作品列表）
  8. 点相关推荐 → 进入该作品的 TMDB 详情页（同样有动态背景）
  9. 断言相关视频区块存在
  10. 每步落盘真实光栅化截图（docs/phase4/evidence/tmdb-*.png）
```

为什么必须真实解码图片：`PosterImage` 加载失败时显示占位图标，只断言
widget 存在无法区分「图片真的加载了」与「全是占位」——而那正是用户反馈的
「没有海报」。截图落盘进一步让「用户看到的样子」可直接人工复核。

---

## 6. 门禁（Phase 4 完成判据）

> 门禁表同时落在 `docs/phase4/README.md` §3；此处列出与测试文件的映射。

| 门禁 | 判据 | 覆盖位置 | 关键断言 |
| --- | --- | --- | --- |
| 标题清洗与信号 | 13 步清洗、年份、季度信号 | `phase4_tmdb_title_test.dart` | 步骤顺序敏感；兜底返回原输入；`-1` 而非 `0` |
| 匹配评分 | 三级选择 + 相似度 + 语言偏好 | `phase4_tmdb_title_test.dart`、`phase4_tmdb_match_policy_test.dart` | 相似度 1000/800+/700- 精确值；分季四档 |
| 分季变体防护 | 四档得分 + 直接丢弃 | `phase4_tmdb_match_policy_test.dart` | `-240` 候选被丢弃而非降分 |
| 站点策略 | 7 条判定顺序 + 括号归一 | `phase4_tmdb_site_policy_test.dart` | `[书]` 不命中 `[小说]`；猫源全角括号可命中 |
| 匹配缓存 | 三层键 + 手动排他 | `phase4_tmdb_cache_test.dart` | 同 `vodId` 多作品；富集后可读回；冲突显式化 |
| 季度解析 | 15 步顺序 + 不落盘 | `phase4_tmdb_season_resolver_test.dart` | 三元组断言；`ambiguous` 零写入；不覆盖旧绑定 |
| 可播放季度 | 6 级顺序 + UI 矩阵 | `phase4_tmdb_available_seasons_test.dart` | 不补集、不丢集；"TMDB 有 9 集线路 8 集"不生成第 9 项 |
| 分段校验 | 8 条有效性 | `phase4_tmdb_segment_test.dart` | 不连续 / 未完整覆盖 → 无效 |
| 季度进度 | 写入/读取/投影/换源/删除 | `phase4_tmdb_progress_test.dart` | `UnknownSeason` 不写；多季不互相覆盖；换源 5 条 |
| 剧集元数据 | 未知季度不应用 + 代数校验 | `phase4_tmdb_episode_metadata_test.dart` | 反向验证：改回 `[1,0]` 则失败 |
| 配置归一化 | 13 条 + 别名 + JWT | `phase4_tmdb_config_test.dart` | `toJson`/`objectFrom` 幂等 |
| 图片选择 | 4 条排序 + 方向回退 | `phase4_tmdb_image_selector_test.dart` | 去重；`limit <= 0` 不限 |
| 服务可靠性 | 鉴权/TTL/兜底/熔断/取消 | `phase4_tmdb_service_test.dart` | 熔断期**零请求**；陈旧兜底；取消不落盘 |
| 存储与迁移 | 建表/幂等/往返/上限/清理 | `phase4_tmdb_storage_test.dart` | 旧库打开后新表存在且旧数据不变 |
| 契约 | Schema 校验 + fixture 完整 | `tests/test_contracts.py` | `invalid` fixture 必须校验失败（反向验证） |
| UI 渲染 | 6 态 + 补位 + 骨架 + 键盘 | `phase4_tmdb_ui_test.dart` | 来源非空字段**不变**；失败隔离文案 |
| 详情展示模型 | 头部字段 + 剧集卡片 + 查看器 + 轮播策略 | `phase4_tmdb_detail_model_test.dart` | 不补集/不丢集；导演回退；查看器定位被点击那张 |
| 详情视觉回归 | 动态背景轮播 + 海报卡片 + 三处点击 + 键盘 + 布局 | `phase4_tmdb_detail_view_test.dart` | 5 秒换图；900 px 不溢出；空数据整块隐藏 |
| 详情可视化集成 | 真实图片解码 + 截图证据 | `integration_test/tmdb_detail_visual_flow_test.dart` | 背景/剧照**真实解码成功**；剧照→查看器、人员→人物页、推荐→作品详情 |
| 详情集成 | 真实窗口 + 真实 HTTP | `integration_test/tmdb_detail_flow_test.dart` | 季度切换后选集数量正确 |
| 播放集成 | 真实播放器 + 季度身份透传 + 续播 | `integration_test/tmdb_playback_flow_test.dart` | `episodeUrl` 优先级；换源续播 |
| 手动匹配集成 | 持久化 + 仅选季度 + 清除 | `integration_test/tmdb_manual_match_flow_test.dart` | 重进详情页结论仍生效 |
| 失败隔离集成 | 401 不阻塞播放 + 熔断 | `integration_test/tmdb_failure_isolation_flow_test.dart` | 计数不增加 |
| 纯 TMDB 详情页 | 无播放按钮 + 跳搜索 | `integration_test/tmdb_tmdb_only_detail_flow_test.dart` | 卡片不可播 |
| 无回归 | 全量单测 + 静态检查 | `flutter test` + `dart analyze` | 用例全绿；analyze 无问题 |
| 凭据不泄露 | 日志与诊断导出脱敏 | `phase4_tmdb_config_test.dart` + `tools/phase4/verify_tmdb_redaction.py` | `apiKey`/`accessToken` 不出现在日志与诊断包 |

---

## 7. 证据与一键验收

### 7.1 证据文件

视觉证据（由 `tmdb_detail_visual_flow_test.dart` 真实光栅化落盘，可直接人工复核）：

| 文件 | 证明 |
| --- | --- |
| `docs/phase4/evidence/tmdb-detail-header.png` | 动态背景（剧照/海报）+ 头部海报/导演/评分/时长/季集数 + 每集海报卡片 |
| `docs/phase4/evidence/tmdb-photo-viewer.png` | 点击剧照真的打开大图查看器并定位到被点击那张 |
| `docs/phase4/evidence/tmdb-person-page.png` | 点击演职人员真的打开人物页（简介/照片/作品） |
| `docs/phase4/evidence/tmdb-recommendation-detail.png` | 点击相关推荐真的进入该作品详情（季度卡片 + 全部剧集） |

```text
docs/phase4/evidence/windows-acceptance.txt
```

格式与 Phase 3 一致：每个门禁一行 `PHASE4-ACCEPT <门禁> <结论>` + 可复查事实。

### 7.2 一键验收脚本

```text
tools/phase4/run_windows_acceptance.ps1
```

步骤（对齐 `tools/phase3/run_windows_acceptance.ps1` 的结构与失败处理原则）：

```text
0. TMDB fixture 预检（路由可达、__stats 可用）
1. 契约与 fixture（py -3 -m unittest tests.test_contracts）+ Schema 校验
2. 静态检查（dart analyze）
3. 单元测试（flutter test，含 phase4_tmdb_* 套件）
4. Windows 集成测试（-d windows，五个 tmdb_*_flow_test.dart）
5. 凭据脱敏校验（tools/phase4/verify_tmdb_redaction.py）
6. 汇总输出 PHASE4-ACCEPT 事实行并写入证据文件
```

**设计原则（沿用 Phase 3）**：

- 失败不静默：每步独立捕获退出码，失败记入 `$script:Failures`；
- 原生命令 stderr 不作为失败判据（关闭 `PSNativeCommandUseErrorActionPreference`）；
- 所有事实行写入证据文件，可复查；
- 支持 `-SkipIntegrationTests` 快速回归。

### 7.3 凭据脱敏校验脚本

```text
tools/phase4/verify_tmdb_redaction.py
```

行为：

1. 读取 `tools/phase4/fixtures/tmdb-credentials.sample.json`（示例凭据，如 `sk-test-1234567890`）；
2. 用示例凭据跑一遍 `phase4_tmdb_service_test.dart` 的日志路径（或直接扫描测试产出的日志文件）；
3. 断言日志与诊断导出中**不出现**示例凭据原文，只出现 `****7890` 形态；
4. 断言请求日志中不出现 `api_key=` 原文。

失败即视为**发布门禁不通过**（对齐主设计文档 §22.5 第 3 项）。

---

## 8. 非目标（本阶段不测）

| 项 | 原因 |
| --- | --- |
| 真实 TMDB 生产接口的端到端调用 | 需要用户凭据与配额；L3 只用本地 fixture |
| AI 刮削 / 个人推荐 | `00` §4.3，本阶段不实现 |
| 豆瓣评分富集 | 同上 |
| 跨设备同步 TMDB 绑定 | Phase 5（同步）范畴 |
| 多套 TMDB 配置轮换 | `03` §10 Q5 明确不支持 |
| 相关视频的应用内播放 | `04` §7.2 明确不做 |
| macOS/Linux 的 TMDB 验证 | 平台范围与 Phase 3 一致，只交付 Windows |

---

## 9. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| fixture 与真实 TMDB 响应形态偏差 | 上线后发现解析失败 | fixture 必须来自真实响应脱敏快照；保留 `malformed.json` 与 `error-*.json` |
| 季度解析分支过多导致测试维护成本高 | 回归变慢 | 三元组（status/source/reason）断言统一化；用例表驱动 |
| widget 测试与真实布局偏差 | 骨架屏尺寸断言脆弱 | 尺寸断言容差 1 px；主验证放在 L3 集成 |
| 熔断时间依赖真实时钟 | 测试不稳定 | `clock` 注入（`03` §3.4） |
| 集成测试依赖 fixture 端口 18080 | 端口冲突 | 脚本复用 Phase 3 的端口探测与启动逻辑 |
| `url_launcher` 在 CI 无浏览器 | 集成测试失败 | 相关视频打开改为可注入的 opener；CI 用假 opener |

---

## 10. 验收要点自查清单

实施完成后，必须能对以下每一项给出**权威证据**（命令输出或文件）：

- [ ] `flutter test` 全绿，且 `phase4_tmdb_*` 套件数量与 §3 清单一致
- [ ] `dart analyze` 无问题
- [ ] `py -3 -m unittest tests.test_contracts` 通过，含 4 个新增用例
- [ ] 五个 `integration_test/tmdb_*_flow_test.dart` 在 `-d windows` 全绿
- [ ] `tools/phase4/run_windows_acceptance.ps1` 输出 `PHASE4-ACCEPT` 全绿事实行
- [ ] `docs/phase4/evidence/windows-acceptance.txt` 已生成且可复查
- [ ] `verify_tmdb_redaction.py` 通过
- [ ] 反向验证：把 `episodeMetadataSeasonCandidates` 改回 `[1, 0]` → 对应测试失败
- [ ] 反向验证：把分季惩罚改为 `0` → 分季用例失败
- [ ] 反向验证：去掉括号归一 → 猫源站点策略用例失败
