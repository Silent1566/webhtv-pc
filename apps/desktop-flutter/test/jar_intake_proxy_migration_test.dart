/// jvm 站源的「本机代理」授权迁移（对齐安卓：所有已加载站源都能用 /proxy?do=…）。
///
/// 为什么要有迁移：权限写在每个站点的 manifest.json 里，改默认值只影响新装站点。
/// 存量 manifest 不迁移的话，用户必须逐个删目录重导才用得上。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/jar_intake.dart';

Map<String, Object?> jvmManifest() => {
  'abi': 'webhtv-ipc-v1',
  'key': 'k',
  'runtime': 'jvm',
  'entry': 'index.jar',
  'capabilities': ['home', 'category', 'detail', 'search', 'play'],
  'permissions': {
    'network': true,
    'localProxy': false,
    'ui': false,
    'storage': 'cache-only',
  },
};

void main() {
  test('jvm 站源缺授权时补上 localProxy 与 proxy 能力', () {
    final manifest = jvmManifest();
    expect(JarIntake.upgradeJvmProxyAuthorization(manifest), isTrue);
    expect((manifest['permissions'] as Map)['localProxy'], isTrue);
    expect(manifest['capabilities'], contains('proxy'));
    expect((manifest['permissions'] as Map)['network'], isTrue);
    expect((manifest['permissions'] as Map)['storage'], 'cache-only');
    expect(manifest['capabilities'], contains('home'));
  });

  test('已经授权的 manifest 原样返回（幂等，不重写文件）', () {
    final manifest = jvmManifest();
    JarIntake.upgradeJvmProxyAuthorization(manifest);
    expect(JarIntake.upgradeJvmProxyAuthorization(manifest), isFalse);
  });

  test('非 jvm 运行时（python/js 站源）一律不动', () {
    final manifest = jvmManifest();
    manifest['runtime'] = 'python-catvod';
    expect(JarIntake.upgradeJvmProxyAuthorization(manifest), isFalse);
    expect((manifest['permissions'] as Map)['localProxy'], isFalse);
    expect(manifest['capabilities'], isNot(contains('proxy')));
  });

  test('缺 permissions / capabilities 的脏 manifest 也能补齐且不抛异常', () {
    final manifest = <String, Object?>{'runtime': 'jvm'};
    expect(JarIntake.upgradeJvmProxyAuthorization(manifest), isTrue);
    expect((manifest['permissions'] as Map)['localProxy'], isTrue);
    expect(manifest['capabilities'], ['proxy']);
  });
}
