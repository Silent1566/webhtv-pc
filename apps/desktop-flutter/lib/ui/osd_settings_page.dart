/// 屏显（OSD）明细页（`docs/phase8/design/02` §5）。
///
/// 7 个开关原来就地摊在设置首页的「播放」分类里：与同屏其他行节奏不一致，
/// 而且同屏还有一行说明被换行挤成两行（用户反馈「屏显和其他设置不一样」）。
/// 挪进独立页后，分类页只留一行入口 + `已开 N/7` 摘要，开关归本页。
library;

import 'package:flutter/material.dart';

import '../core/osd_config.dart';
import '../state/app_state.dart';
import 'settings_layout.dart';

class OsdSettingsPage extends StatelessWidget {
  const OsdSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => SettingsDetailScaffold(
      title: '屏显（OSD）',
      description: '播放画面上叠加的信息角标；全部关闭时整层隐藏，不再刷新。',
      children: [
        Column(
          key: const ValueKey('settings-osd'),
          children: [
            for (final id in OsdFlag.values)
              SwitchListTile(
                key: ValueKey('settings-osd-$id'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(osdFlagLabel(id)),
                subtitle: id == OsdFlag.traffic
                    ? const Text('取自播放引擎的网络输入速率；取不到时显示 —')
                    : null,
                value: state.osdFlags[id] ?? false,
                onChanged: (value) => state.setOsdFlag(id, value),
              ),
          ],
        ),
      ],
    ),
  );
}

/// 一行摘要：`已开 3/7`。关闭全部开关时也给同一个形状，便于扫读。
String osdSummary(AppState state) {
  final enabled = OsdFlag.values
      .where((id) => state.osdFlags[id] ?? false)
      .length;
  return '已开 $enabled/${OsdFlag.values.length}';
}

/// 屏显开关的中文名（`docs/phase8/design/02` §5.1）。
///
/// 与 [OsdFlag] 的 id 一一对应；未知 id 回落成 id 本身（不抛异常，
/// 与 `normalizeOsdFlags` 的「只接受合法值」同一口径）。
String osdFlagLabel(String id) {
  switch (id) {
    case OsdFlag.title:
      return '标题';
    case OsdFlag.size:
      return '分辨率';
    case OsdFlag.time:
      return '时钟';
    case OsdFlag.progress:
      return '播放进度';
    case OsdFlag.traffic:
      return '网速';
    case OsdFlag.mini:
      return '迷你进度条';
    case OsdFlag.diagnostics:
      return '诊断面板';
    default:
      return id;
  }
}
