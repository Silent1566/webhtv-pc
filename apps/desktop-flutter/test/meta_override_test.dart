import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_override.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';

MetaIdentity id(MetaSourceKind kind, int number) =>
    MetaIdentity.of(kind, TmdbMediaType.tv, number)!;

void main() {
  test('钉住与取消钉住，空 vodId 与非法身份都不写入', () {
    final store = MetaOverrideStore();
    expect(store.pin('  ', id(MetaSourceKind.douban, 1)), isFalse);
    expect(store.pin('v1', id(MetaSourceKind.douban, 35588177)), isTrue);
    expect(store.of('v1')?.key, 'douban:tv:35588177');
    expect(store.unpin('v1'), isTrue);
    expect(store.unpin('v1'), isFalse);
    expect(store.isEmpty, isTrue);
  });

  test('持久化往返：未知与非法条目被忽略，TMDB 归 TmdbMatchRecord 不进这张表', () {
    final store = MetaOverrideStore.fromJson({
      'v1': 'douban:tv:35588177',
      'v2': 'bangumi:tv:431299',
      'v3': 'mdblist:tv:9',
      'v4': 'douban:tv:0',
      'v5': 'tmdb:tv:1399',
      '': 'douban:tv:1',
    });
    expect(store.entries.keys.toSet(), {'v1', 'v2'});
    final restored = MetaOverrideStore.fromJson(store.toJson());
    expect(restored.of('v2')?.key, 'bangumi:tv:431299');
    expect(MetaOverrideStore.fromJson(null).isEmpty, isTrue);
  });
}