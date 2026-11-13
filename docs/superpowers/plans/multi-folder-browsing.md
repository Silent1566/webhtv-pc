# 多层文件夹兼容实施计划

目标：安卓兼容目录逐层浏览、分页和返回；文件进入现有详情，保留已知桥接分享链聚合。用户确认方案1；不改安卓，不增加直接播放、多条详情转目录或按源名猜测。

架构：单个实现任务负责紧密耦合的模型、目录状态和UI，目录使用SiteService.category，vod_id原样传递。页级导航保留父层状态。已知atvp_detail桥接协议仍走原folderDetail。
参考：安卓Vod.java:304、mobile TypeFragment.java:216、FolderFragment.java:93；PC protocol.dart:949、site_service.dart:151、browse_pages.dart:1014/1245、app_state.dart:5276。
环境：dev1分支、初始工作树干净；SDK /tmp/webhtv-linux-sdk/flutter-3.47.5。

## 任务1（run 2，完成）：实现与自检
- [x] 新增失败测试，覆盖folder/cate、桥接保留、父子层、请求参数、分页。
- [x] 改UI前捕获旧代码固定mock场景（1280×900、暗色），修改后用相同场景捕获。
- [x] 目录层保存页码/列表/筛选/滚动，处理加载、空目录、失败重试和作废请求。
- [x] 共用详情入口支持目录，保留来源配置/站点上下文，不改变顶栏选择。
- [x] 新测试、bridge/history/detail相关回归、修改文件静态分析。

## 任务2（review run 3，完成）：独立验收
- [x] 审查关键diff和全部需求。
- [x] 独立测试并核对同场景前后截图。
- [x] 问题交回原实现者；最多三次执行，未处理缺陷不验收。

不提交、不发布、不升级依赖或改锁文件；真实AList需要可用源，先用确定性fixture验收协议及UI。
