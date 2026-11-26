/// 站点表缓存：**同一代次复用同一份列表，换代必须重建**。
///
/// 为什么锁这条：`siteItems` 是搜索页/站点选择器每次 build 都读的热点，而
/// `csp_*`（加固壳）站点的可用性判定要读盘——`probeRecord`/`intakeRecord` 各一次
/// 同步读 + `jsonDecode`，再按入口 jar 做静态检测。本机实测 111 个加固壳站点
/// 一遍 **350 ms**，搜索页一次 build 读 2–3 遍（searchScopeGroups、_siteNameOf、
/// 范围按钮），于是每次重建都在主 isolate 上烧 0.7–2.8 s。
/// 缓存必须跟着 SpiderRouter.siteRevision 换代，否则用户装完 jar 仍看到旧结论。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/detail_test_seams.dart';

/// 60 个加固壳站点：数量本身不是断言对象，只是让「不缓存」在时间上可见。
String _shellConfigJson({int sites = 60}) {
  final list = [
    for (var i = 0; i < sites; i++)
      {
        'key': 'csp_S$i',
        'name': '壳站 $i',
        'type': 3,
        'api': 'csp_S$i',
        'searchable': 1,
      },
  ];
  return jsonEncode({'sites': list});
}

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-site-items-cache');
    final root = p.join(tempDir.path, 'webhtv-pc');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': root,
          'data': root,
          'cache': p.join(root, 'cache'),
          'state': p.join(root, 'logs'),
        },
      ),
      log: MemoryOnlyLogService(),
    );
    await bootstrapWithoutExternalMeta(state);
    expect(await state.importConfig(_shellConfigJson()), isTrue);
  });

  tearDown(() async {
    state.dispose();
    await state.pythonEnvironmentIdle;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('同一代次内 siteItems 复用同一份列表', () {
    final first = state.siteItems;
    expect(first, hasLength(60));
    expect(
      identical(state.siteItems, first),
      isTrue,
      reason: '同一代次重复读必须命中缓存，否则搜索页每次 build 都要重判 60 个站点',
    );
  });

  test('写入探测结论后后台重判并通知更新站点可用性文案', () async {
    final first = state.siteItems;
    final refreshed = Completer<void>();
    void onStateChanged() {
      if (!refreshed.isCompleted &&
          (state.siteItems.first.availability.reason ?? '').contains(
            '测试入口不可加载',
          )) {
        refreshed.complete();
      }
    }

    state.addListener(onStateChanged);
    try {
      final binding = CspJvmBinding(
        root: p.join(state.paths.configDir, 'spiders', 'csp'),
      );
      await JarIntake.writeProbe(binding.directoryFor('csp_S0'), {
        'siteKey': 'csp_S0',
        'summary': '测试入口不可加载',
      });
      final checking = state.siteItems;
      expect(identical(checking, first), isFalse);
      await refreshed.future.timeout(const Duration(seconds: 10));

      final second = state.siteItems;
      expect(second.first.availability.reason, contains('测试入口不可加载'));
      expect(
        identical(second, checking),
        isFalse,
        reason: '后台重判完成后必须通知并替换检查中的列表，不能永久停在旧结论',
      );
      expect(identical(state.siteItems, second), isTrue);
      expect(
        second.map((item) => item.site.key).toList(),
        first.map((item) => item.site.key).toList(),
        reason: '重建只换结论，站点顺序不变',
      );
    } finally {
      state.removeListener(onStateChanged);
    }
  });

  test('JarIntake 记录缓存按文件大小/修改时间失效', () async {
    final dir = Directory(p.join(tempDir.path, 'csp', 'recorded'))
      ..createSync(recursive: true);
    await JarIntake.writeProbe(dir.path, {
      'siteKey': 'recorded',
      'summary': 'v1',
    });
    expect(JarIntake.probeRecord(dir.path)?['summary'], 'v1');

    File(p.join(dir.path, 'probe.json')).writeAsStringSync(
      jsonEncode({'siteKey': 'recorded', 'summary': 'v2-longer'}),
      flush: true,
    );
    expect(JarIntake.probeRecord(dir.path)?['summary'], 'v2-longer');

    File(p.join(dir.path, 'intake.json')).writeAsStringSync(
      jsonEncode({'siteKey': 'recorded', 'className': 'A'}),
      flush: true,
    );
    expect(JarIntake.intakeRecord(dir.path)?['className'], 'A');
    File(p.join(dir.path, 'intake.json')).writeAsStringSync(
      jsonEncode({'siteKey': 'recorded', 'className': 'B-longer'}),
      flush: true,
    );
    expect(JarIntake.intakeRecord(dir.path)?['className'], 'B-longer');
  });

  test('同大小的记录修改按 mtime 失效', () {
    final directory = Directory(p.join(tempDir.path, 'record-mtime'))
      ..createSync(recursive: true);
    final file = File(p.join(directory.path, 'probe.json'));
    file.writeAsStringSync(jsonEncode({'summary': 'A'}));
    final before = file.statSync();
    expect(JarIntake.probeRecord(directory.path)?['summary'], 'A');

    file.writeAsStringSync(jsonEncode({'summary': 'B'}));
    file.setLastModifiedSync(before.modified.add(const Duration(seconds: 2)));
    expect(file.lengthSync(), before.size);
    expect(JarIntake.probeRecord(directory.path)?['summary'], 'B');
  });
}
