import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/pan_check.dart';

void main() {
  group('P1-8 分享链接解析（README §4.2）', () {
    test('识别各网盘类型与 shareId', () {
      final cases = {
        'https://pan.baidu.com/s/1AbCdEf': PanDiskType.baidu,
        'https://pan.quark.cn/s/abcdef123': PanDiskType.quark,
        'https://www.aliyundrive.com/s/xyz789': PanDiskType.aliyun,
        'https://drive.uc.cn/s/uc123': PanDiskType.uc,
        'https://www.123pan.com/s/abc-def': PanDiskType.pan123,
        'https://cloud.189.cn/t/tianyi1': PanDiskType.tianyi,
        'https://example.com/file': PanDiskType.unknown,
      };
      for (final entry in cases.entries) {
        expect(
          parsePanShareLink(entry.key).diskType,
          entry.value,
          reason: entry.key,
        );
      }
      expect(
        parsePanShareLink('https://pan.quark.cn/s/abcdef123').shareId,
        'abcdef123',
      );
    });

    test('提取码：文本写法与 query 写法', () {
      final fromText = parsePanShareLink(
        'https://pan.baidu.com/s/1AbCdEf 提取码: qwer',
      );
      expect(fromText.password, 'qwer');

      final fromQuery = parsePanShareLink(
        'https://pan.baidu.com/s/1AbCdEf?pwd=zxcv',
      );
      expect(fromQuery.password, 'zxcv');
    });

    test('归一化：带提取码补 pwd、去 fragment 与噪声参数', () {
      final link = parsePanShareLink(
        'https://pan.baidu.com/s/1AbCdEf?entry=share#frag',
      );
      final withPassword = PanShareLink(
        url: link.url,
        diskType: link.diskType,
        shareId: link.shareId,
        password: 'abcd',
      );
      final normalized = Uri.parse(withPassword.normalizedUrl);
      expect(normalized.fragment, isEmpty);
      expect(normalized.queryParameters['pwd'], 'abcd');
      expect(normalized.queryParameters.containsKey('entry'), isFalse);
    });
  });

  group('P1-8 状态判定（README §4.2）', () {
    test('明确的失效/需提取码/正常', () {
      expect(
        classifyPanCheck(
          diskType: PanDiskType.baidu,
          statusCode: 200,
          body: '分享已失效',
        ),
        PanCheckState.bad,
      );
      expect(
        classifyPanCheck(
          diskType: PanDiskType.quark,
          statusCode: 200,
          body: '请输入提取码',
        ),
        PanCheckState.locked,
      );
      expect(
        classifyPanCheck(
          diskType: PanDiskType.quark,
          statusCode: 200,
          body: '文件名 目录',
        ),
        PanCheckState.ok,
      );
      expect(
        classifyPanCheck(
          diskType: PanDiskType.baidu,
          statusCode: 404,
          body: '',
        ),
        PanCheckState.bad,
      );
    });

    test('页面特征不足时如实给 uncertain，不误报失效', () {
      expect(
        classifyPanCheck(
          diskType: PanDiskType.aliyun,
          statusCode: 200,
          body: '<html>loading</html>',
        ),
        PanCheckState.uncertain,
      );
      expect(
        classifyPanCheck(
          diskType: PanDiskType.unknown,
          statusCode: 200,
          body: 'anything',
        ),
        PanCheckState.unsupported,
      );
      expect(
        classifyPanCheck(
          diskType: PanDiskType.uc,
          statusCode: 500,
          body: '',
        ),
        PanCheckState.uncertain,
      );
    });
  });

  group('P1-8 缓存（README §4.2）', () {
    PanCheckResult result(PanCheckState state, {required int at}) =>
        PanCheckResult(
          url: 'https://pan.baidu.com/s/x',
          normalizedUrl: 'https://pan.baidu.com/s/x',
          diskType: PanDiskType.baidu,
          state: state,
          summary: state.label,
          checkedAt: at,
        );

    test('命中后标记 fromCache；TTL 到期后失效', () {
      final cache = PanCheckCache();
      final at = DateTime(2026, 10, 21, 12).millisecondsSinceEpoch;
      cache.put('k', result(PanCheckState.ok, at: at));

      final hit = cache.get('k', now: DateTime(2026, 10, 21, 12, 30));
      expect(hit, isNotNull);
      expect(hit!.fromCache, isTrue);

      // ok 的 TTL 是 1h。
      expect(cache.get('k', now: DateTime(2026, 10, 21, 13, 30)), isNull);
    });

    test('不同状态 TTL 不同', () {
      expect(PanCheckState.ok.ttl, const Duration(hours: 1));
      expect(PanCheckState.bad.ttl, const Duration(hours: 6));
      expect(PanCheckState.locked.ttl, const Duration(hours: 12));
      expect(PanCheckState.unsupported.ttl, const Duration(hours: 24));
      expect(PanCheckState.uncertain.ttl, const Duration(minutes: 30));
    });

    test('上限淘汰最旧项', () {
      final cache = PanCheckCache(maxEntries: 2);
      final at = DateTime(2026, 10, 21, 12).millisecondsSinceEpoch;
      cache.put('a', result(PanCheckState.ok, at: at));
      cache.put('b', result(PanCheckState.ok, at: at));
      cache.put('c', result(PanCheckState.ok, at: at));
      expect(cache.length, 2);
      expect(cache.get('a', now: DateTime(2026, 10, 21, 12, 1)), isNull);
    });
  });

  group('P1-8 结果序列化', () {
    test('toJson/fromJson 往返', () {
      final result = PanCheckResult(
        url: 'https://pan.quark.cn/s/a',
        normalizedUrl: 'https://pan.quark.cn/s/a',
        diskType: PanDiskType.quark,
        state: PanCheckState.locked,
        summary: '需要提取码或登录',
        checkedAt: 123,
      );
      final restored = PanCheckResult.fromJson(result.toJson());
      expect(restored.diskType, PanDiskType.quark);
      expect(restored.state, PanCheckState.locked);
      expect(restored.checkedAt, 123);
    });

    test('脏数据回落 uncertain/unknown', () {
      final restored = PanCheckResult.fromJson({
        'diskType': 'nope',
        'state': 'nope',
      });
      expect(restored.diskType, PanDiskType.unknown);
      expect(restored.state, PanCheckState.uncertain);
    });
  });
}
