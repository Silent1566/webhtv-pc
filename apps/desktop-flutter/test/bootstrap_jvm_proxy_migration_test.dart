/// 启动装配里的迁移接线：manifest 必须在 `bootstrap()` 之后被改写。
///
/// 上一版把迁移挂在后台「加固壳探测」里，而那次探测根本没跑（实测日志里没有），
/// 于是权限永远补不上。这条用例锁的就是「bootstrap 一定会迁移」。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  test('bootstrap 之后 jvm 站源的 manifest 已获得 localProxy', () async {
    final temp = Directory.systemTemp.createTempSync('bootstrap-proxy-migrate');
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    final site = Directory(p.join(paths.configDir, 'spiders', 'csp', 's1'))
      ..createSync(recursive: true);
    final manifest = File(p.join(site.path, 'manifest.json'));
    manifest.writeAsStringSync(
      jsonEncode({
        'abi': 'webhtv-ipc-v1',
        'key': 's1',
        'runtime': 'jvm',
        'entry': 'index.jar',
        'capabilities': ['home', 'play'],
        'permissions': {'network': true, 'localProxy': false},
      }),
    );

    final state = AppState(paths: paths, log: LogService());
    try {
      await state.bootstrap();
      final migrated = jsonDecode(manifest.readAsStringSync()) as Map;
      expect(
        (migrated['permissions'] as Map)['localProxy'],
        isTrue,
        reason: 'bootstrap 必须执行 jvm 授权迁移，否则该站源永远没有代理会话',
      );
      expect(migrated['capabilities'], contains('proxy'));
    } finally {
      state.dispose();
      temp.deleteSync(recursive: true);
    }
  });
}
