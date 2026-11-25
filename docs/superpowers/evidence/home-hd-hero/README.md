# 首页高清轮播规则证据

Before：用户本轮截图 before-user-broken-background.png。
真实源图片检查：百草追凶历史图 HTTP200、JPEG241×330、21481字节，不满足高清横图条件。能取得URL与图片能成为背景是两件事。

目标：仅hero要求实际解码width≥1280、height≥720、width>height；失败/超时/竖图/低清排除，以后续候选补位。下方轨道和播放入口保留。HD检查与PosterImage同provider/cache/headers。

自动验证：test/home_hero_image_probe_test.dart真实PNG尺寸/错误/超时/监听清理；test/home_hd_hero_backfill_test.dart第13项补位、轨道保留、全失败折叠、字段关闭、乱序完成、渲染失败后补位；test/home_hero_candidates_test.dart120池上限与顺序。

After将由同主题1280×800合成夹具截图验证；它不是真实影视素材，不能冒充真实站点响应。

## 最终验收

- 28个相关套件273项全绿（元数据/路由/续播/HD探针/补位/直播过滤）。其中25项独立探针测试默认路径真实PNG解码，不以注入结果代替生产检查。
- 新5项page回归：第13候选补位、轨道保留/全失败折叠、并行完成顺序、实际绘制失败回调后补位、背景字段关闭。
- puro webhtv analyze lib test：0issue。Windowsdebug构建exit0，kernel_blob.bin本轮已更新。
- After为1280×800深色主题的合成高清夹具（渐变/几何建筑，不是真实影视素材）；Before是用户截图，无法与After作为同一影片像素对照。夹具字体只覆盖部分文本，按钮中的方框不代表产品字体链。
- 下方轨道在no-art截图中保留，即使它们的低清/坏图不合格，条目及续播入口仍在。
