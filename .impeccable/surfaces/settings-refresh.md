# 设置区 UI 与交互优化

模式：Operate。平台：Flutter 桌面，Windows 优先、键鼠操作。

## 已确认需求
保留现有深靛/琥珀视觉系统，优化设置主页及子页面布局与交互。所有功能、配置字段、默认值、保存时机、校验与危险操作确认不变。不改首页、播放器和业务服务。

## Direction contract
THESIS：设置是可扫描的偏好与工具入口，不再是一条等权重的冗长表单。
OWN-WORLD：沿用 DESIGN.md 与 theme/tokens 的中文字体、深靛表面、发丝边、琥珀选中态；无阴影、无新字体与依赖。
STORY：先定位偏好类别与当前状态，再进入工具或编辑设置；返回后状态真实更新。工具仍使用现有服务和处理流程。
FIRST VIEWPORT：主页面先给设置标题与简明说明，优先呈现外观/历史/搜索及播放相关设置；连接与增强入口紧凑分组；运行信息和合规说明靠后。子页面统一限宽、标题说明、分组、可换行操作区，保持原生 AppBar 返回。
FORM：用户选择保留应用风格并重做布局和交互；本次是既有设置表面的延展，不重选世界，不运行视觉方向骰子。
FINISH：unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance.

## 验收
主页面与所有设置子页面功能入口可达；键鼠与窄桌面窗口布局正常；字段、默认值、保存和校验不变；相关 Flutter 测试与静态检查通过；暗/亮主题与桌面尺寸真实渲染截图。没有新增交付图片资产，仅截图证据。DESIGN.md 保持原有世界，不修复预先存在的文档漂移。

## 决策与假设
已确认：范围包含 TMDB、安卓接入、AI 设置、高级设置、字幕源、按钮排版、AI 辅助、备份恢复、网盘检测、站点注入、站点健康。
排除：新功能、网络协议、业务服务重构和应用全局主题改造。
假设：既有精确文案/key/widget 类型保留；确因布局移动需调整测试时，只增加滚动定位，不删业务断言。
工具事实：C:/dev/flutter/bin/flutter.bat 可用（Flutter 3.47.5、Dart 3.13.4）；设计工具误判 desktop 为 web，按 Flutter 真实平台执行，跳过 HTML/CSS 检测器。
