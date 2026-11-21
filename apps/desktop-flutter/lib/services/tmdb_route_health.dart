/// 图片线路失败的回报口（自动线路的「失败切换」入口）。
///
/// 为什么是顶层槽位而不是构造函数注入：渲染 TMDB 图片的地方有 31 处
/// （`PosterImage` 18 个文件），逐处注入会把一个线路问题扩散到所有调用方。
/// 这里只留一个由 `AppState` 在启动时接上的回调，图片位出错时回报 URL，
/// 由 AppState 决定「这是单张坏图还是整条线路坏了」。
///
/// 关闭（`null`）时行为与改造前完全一致：图片位只画占位，不做任何线路动作。
library;

/// 图片加载失败的回调集合。
abstract final class TmdbImageHealth {
  /// 某一图片 URL 加载失败。实现方只应把它当作线索：单张 404 不代表线路坏。
  static void Function(String url)? onFailure;
}
