/// 可 push 的「全部设置」页。
///
/// 为什么要它：设置首页是外壳里的一个标签页，`Navigator.push` 不到；而播放器
/// 右键菜单的「完整设置页…」需要一条从**播放画面**摸到所有设置的路。它原来指向
/// 「高级设置」中枢，那个中枢只覆盖四个分类里的长尾部分。
///
/// 本页复用设置首页的分类中枢本体（[SettingsCategoriesBody]）：同一分类模型、
/// 同一组 `settings-category-*` key、同一套滚动位置行为，两处不会分叉。
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'diagnostics_pages.dart';
import 'settings_layout.dart';

class SettingsOverviewPage extends StatelessWidget {
  const SettingsOverviewPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => SettingsRouteScaffold(
    title: const Text('全部设置'),
    frameBody: false,
    wallpaperUrl: state.config?.wallpaper,
    // 本页由 `Navigator.push` 打开，是独立路由；外壳的监听管不到它，所以必须
    // 自己听 `AppState`。不包这一层，拨动开关后整页停在进页那一刻的旧快照
    // （与明细页同一个根因）。标题在 AppBar，正文不再重复页标题。
    body: ListenableBuilder(
      listenable: state,
      builder: (context, _) =>
          SettingsCategoriesBody(state: state, showHeader: false),
    ),
  );
}
