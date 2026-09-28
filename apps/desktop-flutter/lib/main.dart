/// WebHTV PC 应用入口（Windows 优先）。
///
/// 具体实现位于 [ui/app.dart]，这里只保留稳定的入口函数，便于测试与其他
/// 入口（如冒烟脚本）复用同一套启动逻辑。
library;

export 'ui/app.dart' show main;
