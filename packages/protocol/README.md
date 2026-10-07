# WebHTV PC Protocol

该目录保存与 UI 和具体运行时无关的配置、站点、Result/Vod 协议，以及可重复执行的契约测试 fixture。

## 目录

- `schema/`：JSON Schema。
  - `config.schema.json`：WebHTV/TVBox/猫源配置。
  - `tmdb-config.schema.json`：TMDB 元数据增强配置（`docs/phase4/design/03` §5）。
- `fixtures/config/`：配置导入样本。
- `fixtures/http/`：HTTP API 固定响应样本。

TMDB 相关 fixture 位于 `packages/test-fixtures/tmdb/`（含 `config/` 子目录），
由 `tools/phase4/generate_tmdb_fixtures.py` 生成，清单见
`docs/phase4/design/05-tmdb-test-and-acceptance.md` §2.1。

## Phase 0 范围

Phase 0 仅冻结最小配置和 HTTP API 数据契约。未知字段必须保留，不能因当前版本不识别而丢失。

## Phase 4 补充（TMDB）

`tmdb-config.schema.json` 冻结 TMDB 配置的字段、类型与兼容别名键。它与
`config.schema.json` 是两个独立契约：TMDB 配置存放在应用设置
（`<configDir>/settings.json` 的 `tmdb` 段），**不进入站源配置 JSON**。
