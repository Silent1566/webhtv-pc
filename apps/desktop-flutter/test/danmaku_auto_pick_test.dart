import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_match.dart';
import 'package:webhtv_pc/services/danmaku_auto_pick.dart';

DanmakuLibraryEntry entry(String id) => DanmakuLibraryEntry(
  providerId: 'relay',
  id: id,
  title: '灵笼',
  episode: '第1集',
  url: 'http://relay.test:9321/api/v2/comment/$id?format=xml',
);

void main() {
  group('自动搜索逐个试载候选（design/02 §2.3）', () {
    test('第一条不可用就用第二条，load 只被调 2 次', () async {
      final calls = <String>[];
      final picked = await autoLoadDanmakuCandidates(
        ranked: [entry('a'), entry('b'), entry('c')],
        load: (item) async {
          calls.add(item.id);
          return item.id == 'b';
        },
      );
      expect(picked?.id, 'b');
      expect(calls, ['a', 'b']);
    });

    test('maxAttempts 限制尝试个数', () async {
      final calls = <String>[];
      final picked = await autoLoadDanmakuCandidates(
        ranked: [entry('a'), entry('b'), entry('c')],
        load: (item) async {
          calls.add(item.id);
          return item.id == 'c';
        },
        maxAttempts: 2,
      );
      expect(picked, isNull);
      expect(calls, ['a', 'b'], reason: '第三条不该被尝试');
    });

    test('maxAttempts <= 0 时一次都不试', () async {
      var called = false;
      final picked = await autoLoadDanmakuCandidates(
        ranked: [entry('a')],
        load: (_) async {
          called = true;
          return true;
        },
        maxAttempts: 0,
      );
      expect(picked, isNull);
      expect(called, isFalse);
    });

    test('全部不可用 → null', () async {
      final picked = await autoLoadDanmakuCandidates(
        ranked: [entry('a'), entry('b')],
        load: (_) async => false,
      );
      expect(picked, isNull);
    });

    test('空列表 → null 且 load 0 次', () async {
      var called = 0;
      final picked = await autoLoadDanmakuCandidates(
        ranked: const <DanmakuLibraryEntry>[],
        load: (_) async {
          called++;
          return true;
        },
      );
      expect(picked, isNull);
      expect(called, 0);
    });

    test('load 抛异常按 false 处理并继续下一个', () async {
      final calls = <String>[];
      final picked = await autoLoadDanmakuCandidates(
        ranked: [entry('a'), entry('b')],
        load: (item) async {
          calls.add(item.id);
          if (item.id == 'a') throw StateError('弹幕文件没有可用条目');
          return true;
        },
      );
      expect(picked?.id, 'b');
      expect(calls, ['a', 'b']);
    });
  });
}
