# 首页启动稳定推荐位与本地宽图快照

## Before
用户两张截图 before-user-rails-first.png → before-user-late-hero.png，先轨道顶到首屏，再插入整屏hero，导致位置大幅变化。

## After（1280×800深色主题合成夹具）
- cold-first-frame.png：没有缓存的首次打开也固定800px推荐位，不等待网络才加高。
- cold-ready-same-height.png：高清图验证完成，只在同高区域替换内容，轨道坐标不变。
- offline-cached-first-frame.png：新页面实例从磁盘图片恢复，远端检查未完成，真实FileImage→RawImage像素1920×1080已挂载，原始历史进度仍123456。

After是合成图，不是真实影视海报，字体子集中的部分按钮方框不是产品字体行为；与用户Before不是同一影片像素配对。

## 验证
- 27个相关套件294项通过；其中缓存模块22项覆盖PNG/JPEG、离线新实例、3项/18MiB上限、scope/哈希/文件缺失/路径链接、清理与并发提交。
- startup layout4项：首帧同高→就绪轨道坐标不变；磁盘缓存实际解码/绘制；自动页面保存图片字节到index；全不合格也保留同高占位。
- 完整analyze lib test：0issue；Puro webhtv Windowsdebug构建exit0。

缓存位于用户cache目录的home-hero-startup-v1，仅保存前3张已验证宽图与展示文案；按钮始终绑定当前候选的原始历史/来源/分集。配置门控/字段/headers摘要变化使旧快照失效，坏图不会复活，保存的旧异步任务不能覆盖较新3项。缓存可删除，会在成功显示后重新生成。
