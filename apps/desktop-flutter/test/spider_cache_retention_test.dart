/// `probe-cache` 限额回收：只清可重建的共享缓存。
///
/// 口径（用户已选定）：默认预算 512 MiB、超额按最近使用（mtime）淘汰；旧口径产物闲置
/// 30 天回收；活动窗口内的条目一律不动；删除失败只跳过，不影响调用方。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/dex_translate.dart';
import 'package:webhtv_pc/services/spider_cache_retention.dart';

void main() {
  late Directory root;
  final now = DateTime(2026, 12, 1, 12);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('webhtv-cache-retention');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  /// 造一份条目；[bytes] 是该条目占用的字节数，[age] 是最后修改时间距今多久。
  File put(String relative, {int bytes = 100, Duration age = Duration.zero}) {
    final file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 7));
    file.setLastModifiedSync(now.subtract(age));
    return file;
  }

  SpiderCachePruneResult prune({
    int budgetBytes = 512 * 1024 * 1024,
    Duration activeWindow = const Duration(minutes: 10),
    Duration staleGenerationAge = const Duration(days: 30),
  }) => SpiderCacheRetention.prune(
    root.path,
    budgetBytes: budgetBytes,
    activeWindow: activeWindow,
    staleGenerationAge: staleGenerationAge,
    now: () => now,
  );

  test('超额时按最久未使用淘汰到预算内', () {
    final old = put('shell/aaa/payload.jar', age: const Duration(days: 3));
    final middle = put('shell/bbb/payload.jar', age: const Duration(days: 2));
    final fresh = put('shell/ccc/payload.jar', age: const Duration(days: 1));

    final result = prune(budgetBytes: 150);

    expect(old.existsSync(), isFalse, reason: '最久未使用的先淘汰');
    expect(middle.existsSync(), isFalse, reason: '仍超额就继续淘汰');
    expect(fresh.existsSync(), isTrue, reason: '删到预算内即停');
    expect(result.deletedBytes, greaterThanOrEqualTo(200));
    expect(result.keptBytes, 100);
  });

  test('活动窗口内的条目即使超额也不动', () {
    final active = put('shell/active/payload.jar', age: const Duration(minutes: 1));
    final idle = put('shell/idle/payload.jar', age: const Duration(days: 9));

    final result = prune(budgetBytes: 150);

    expect(active.existsSync(), isTrue);
    expect(idle.existsSync(), isFalse);
    expect(result.keptBytes, 100);
  });

  test('全部条目都在活动窗口内时什么也不删', () {
    final a = put('shell/a/payload.jar', age: const Duration(minutes: 2));
    final b = put('shell/b/payload.jar', age: const Duration(minutes: 3));

    final result = prune(budgetBytes: 10);

    expect(a.existsSync(), isTrue);
    expect(b.existsSync(), isTrue);
    expect(result.deletedBytes, 0);
    expect(result.skippedActive, 2);
  });

  test('旧口径生成目录闲置超过 30 天就回收，当前口径不动', () {
    final sha = 'a' * 64;
    final current = put(
      'dex/$sha/v${DexTranslate.repairVersion}/classes.jar',
      age: const Duration(days: 60),
    );
    final stale = put('dex/$sha/v5/classes.jar', age: const Duration(days: 60));

    final result = prune();

    expect(stale.existsSync(), isFalse, reason: '旧口径产物闲置 30 天应回收');
    expect(current.existsSync(), isTrue, reason: '当前口径不是「旧口径」');
    expect(result.deletedBytes, 100);
  });

  test('旧口径但还在 30 天内不回收', () {
    final stale = put(
      'dex/${'b' * 64}/v5/classes.jar',
      age: const Duration(days: 5),
    );

    final result = prune();

    expect(stale.existsSync(), isTrue, reason: '版本变化不等于立即删除');
    expect(result.deletedBytes, 0);
  });

  test('回收最后一个生成目录后父目录一并清掉', () {
    final shaDir = Directory(p.join(root.path, 'dex', 'c' * 64));
    put('dex/${'c' * 64}/v5/classes.jar', age: const Duration(days: 60));

    prune();

    expect(shaDir.existsSync(), isFalse, reason: '空壳目录不该留在缓存里');
  });

  test('未知目录按条目整体处理，不拆散内部文件', () {
    put('misc/blob.bin', age: const Duration(days: 5));
    put('misc/nested/other.bin', age: const Duration(days: 5));

    final result = prune(budgetBytes: 10);

    expect(Directory(p.join(root.path, 'misc')).existsSync(), isFalse);
    expect(result.deletedBytes, 200);
  });

  test('缓存目录不存在时返回全零且不抛异常', () {
    final missing = p.join(root.path, 'nope');

    final result = SpiderCacheRetention.prune(missing, now: () => now);

    expect(result.deletedBytes, 0);
    expect(result.keptBytes, 0);
  });

  test('只清 probe-cache 内的东西，同级目录一个字节都不动', () {
    final sibling = File(p.join(root.path, '..', 'keepme', 'x.bin'));
    sibling.parent.createSync(recursive: true);
    sibling.writeAsBytesSync(List<int>.filled(10, 1));
    put('shell/dead/payload.jar', age: const Duration(days: 90));

    prune(budgetBytes: 10);

    expect(sibling.existsSync(), isTrue, reason: '回收边界只到 probe-cache');
  });
}
