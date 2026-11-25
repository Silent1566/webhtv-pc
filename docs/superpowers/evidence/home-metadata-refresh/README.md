# 首页/详情元数据一致性（2026-11-25）

Before为用户本轮原始截图，未改图片，不是同构自动化截图配对。

真实TMDB336223没有backdrop，有一张1696×2528 poster；当前背景顺序tmdb→douban→bangumi→wikidata→source，无pin。详情模型将poster填入背景字段；首页旧选择器排除poster。豆瓣4张横向照片只并入photo/still，不说明背景来源。修复复用详情背景字段结果，不伪造横版图片。

验证文件：home_resume_metadata_test.dart（同一HomePage身份改变/字段停用）、home_history_metadata_pipeline_test.dart（真实poster-only字段、source-first、TMDB关闭后豆瓣兜底）。真实详情返回测试由独立子代理实现，Lead独立验收。

本轮不改布局参数，改图片/字段选择及刷新逻辑。