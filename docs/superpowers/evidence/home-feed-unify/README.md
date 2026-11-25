# 首页三处缺陷修复 · 视觉证据（2026-11-25）

同一次运行、同一场景、同一视口（1280×800，devicePixelRatio=1）、同一主题
（`buildAppTheme(Brightness.dark)` + Noto CJK 夹具字体）、同一份合成素材
（1600×900 的 16:9 背景 + 400×600 的 2:3 海报）。

| 文件 | 场景 |
|---|---|
| `before/before-with-backdrop.png` / `after/after-with-backdrop.png` | hero 有一张 16:9 背景图（「大海报」那一档） |
| `before/before-poster-only.png` / `after/after-poster-only.png` | hero 只有一张 2:3 竖版海报（TMDB 没匹配上、站源也只给竖图） |

**Before 的那两张从 HEAD 的独立 worktree 里跑出来**（`git worktree add --detach <temp> HEAD`），
测试文件只在那一份里把 `height: homeHeroHeight(800)` 改回 `height: 800`——因为 HEAD 上
`homeHeroHeight` 还是两档签名。除这一行外，测试源码与 After 完全相同。

## 看得见的差别

- 海报那一档：海报高度 320 → 496（hero 高 800）。旧口径是 hero 自身只占内容区 62%、
  海报再取其中的 52%（夹 160–320），小窗口下就会定格成一张缩略图 + 半屏空。
  新版 hero 恒占内容区，海报取 62%（夹 240–560）。
- 两档同高：没有 16:9 背景图时不再把整条 hero 压到 62%。

## 这两张图**不能**证明的事

- 海报素材在这两次运行里都渲染成占位块（`PosterImage` 的 cacheWidth 变体没有被测试
  预热的 ImageProvider 命中）——它诚实反映「图还没到」的状态，版式与尺寸是真的，
  像素内容不是。
- CJK 夹具字体是子集，个别汉字渲染成方框。字体可用性由 `loadFixtureFonts` 保证，
  与产品字体链无关。

用例：`apps/desktop-flutter/test/home_hero_poster_capture_test.dart`
（`HOME_UNIFY_STAGE=before|after` 决定落盘目录；同时是门禁：海报块高度必须是
`(heroHeight × 0.62).clamp(240, 560)`）。
