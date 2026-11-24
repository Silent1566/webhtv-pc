/// 手动网盘账号模型：只接受 JVM 生成的结构化条目标记。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/spider_account.dart';

Vod vodWith(Map<String, Object?> extra) => Vod(
  vodId: 'id',
  vodName: 'name',
  extra: extra,
);

Map<String, Object?> marker({
  Object? version = 1,
  Object? provider = 'quark',
  Object? operation = 'edit',
}) => <String, Object?>{
  'version': version,
  'provider': provider,
  'operation': operation,
};

Vod markedVod(
  String id, {
  Object? version = 1,
  Object? provider = 'quark',
  Object? operation = 'edit',
}) => Vod(
  vodId: id,
  vodName: id == 'quarkmanual' ? '夸克账号' : '百度账号',
  extra: {
    VodAccountActionKey: marker(
      version: version,
      provider: provider,
      operation: operation,
    ),
  },
);

void main() {
  group('SpiderAccountProvider', () {
    test('两个已证明 provider 的标签与偏好键稳定', () {
      expect(SpiderAccountProvider.quark.label, '夸克');
      expect(SpiderAccountProvider.baidu.label, '百度网盘');
      expect(SpiderAccountProvider.quark.preferenceKey, 'Wex_quark_cookie');
      expect(SpiderAccountProvider.baidu.preferenceKey, 'Wex_baidu_cookie');
    });

    test('恰好两个 provider，不提供任意键入口', () {
      expect(SpiderAccountProvider.values, hasLength(2));
    });
  });

  group('SpiderAccountAction.fromVod', () {
    test('四个精确 ID/操作组合可解析', () {
      final quarkEdit = SpiderAccountAction.fromVod(markedVod('quarkmanual'));
      expect(quarkEdit?.provider, SpiderAccountProvider.quark);
      expect(quarkEdit?.operation, SpiderAccountOperation.edit);

      final quarkClear = SpiderAccountAction.fromVod(
        markedVod('quarkclear', operation: 'clear'),
      );
      expect(quarkClear?.provider, SpiderAccountProvider.quark);
      expect(quarkClear?.operation, SpiderAccountOperation.clear);

      final baiduEdit = SpiderAccountAction.fromVod(
        markedVod('baidumanual', provider: 'baidu'),
      );
      expect(baiduEdit?.provider, SpiderAccountProvider.baidu);
      expect(baiduEdit?.operation, SpiderAccountOperation.edit);

      final baiduClear = SpiderAccountAction.fromVod(
        markedVod('baiduclear', provider: 'baidu', operation: 'clear'),
      );
      expect(baiduClear?.provider, SpiderAccountProvider.baidu);
      expect(baiduClear?.operation, SpiderAccountOperation.clear);
    });

    test('无标记的普通媒体返回 null（即使 ID 形如 quarkmanual）', () {
      expect(SpiderAccountAction.fromVod(vodWith(const {})), isNull);
      expect(
        SpiderAccountAction.fromVod(
          Vod(vodId: 'quarkmanual', vodName: '普通影片'),
        ),
        isNull,
      );
    });

    test('未知版本拒绝', () {
      expect(
        SpiderAccountAction.fromVod(markedVod('quarkmanual', version: 2)),
        isNull,
      );
      expect(
        SpiderAccountAction.fromVod(markedVod('quarkmanual', version: '1')),
        isNull,
      );
      expect(
        SpiderAccountAction.fromVod(markedVod('quarkmanual', version: null)),
        isNull,
      );
    });

    test('未知/伪造 provider 与 operation 拒绝', () {
      expect(
        SpiderAccountAction.fromVod(
          markedVod('quarkmanual', provider: 'wex_other'),
        ),
        isNull,
      );
      expect(
        SpiderAccountAction.fromVod(
          markedVod('quarkmanual', operation: 'write'),
        ),
        isNull,
      );
      expect(
        SpiderAccountAction.fromVod(
          markedVod('quarkmanual', operation: null),
        ),
        isNull,
      );
    });

    test('ID 与标记不一致时拒绝（不能借标记写任意键）', () {
      expect(
        SpiderAccountAction.fromVod(
          markedVod('quarkmanual', provider: 'baidu'),
        ),
        isNull,
      );
      expect(
        SpiderAccountAction.fromVod(
          markedVod('baiduclear', operation: 'edit'),
        ),
        isNull,
      );
      expect(
        SpiderAccountAction.fromVod(markedVod('otherid')),
        isNull,
      );
      expect(
        SpiderAccountAction.fromVod(
          markedVod('quark clear', operation: 'clear'),
        ),
        isNull,
      );
    });


    test('扫码/注册条目按同 provider 的 edit 接受并标记 scanOnly', () {
      const scanOnlyIds = <String, SpiderAccountProvider>{
        'quark': SpiderAccountProvider.quark,
        'qkregister': SpiderAccountProvider.quark,
        'baidu': SpiderAccountProvider.baidu,
        'baiduregister': SpiderAccountProvider.baidu,
      };
      for (final entry in scanOnlyIds.entries) {
        final action = SpiderAccountAction.fromVod(
          markedVod(entry.key, provider: entry.value.name),
        );
        expect(action, isNotNull, reason: '${entry.key} 必须被识别');
        expect(action!.provider, entry.value);
        expect(action.operation, SpiderAccountOperation.edit);
        expect(action.scanOnly, isTrue, reason: '${entry.key} 只能手动填写');
      }
      const manualIds = <String, SpiderAccountProvider>{
        'quarkmanual': SpiderAccountProvider.quark,
        'baidumanual': SpiderAccountProvider.baidu,
      };
      for (final entry in manualIds.entries) {
        final action = SpiderAccountAction.fromVod(
          markedVod(entry.key, provider: entry.value.name),
        );
        expect(action?.scanOnly, isFalse, reason: '${entry.key} 不是扫码条目');
      }
      const clearIds = <String, SpiderAccountProvider>{
        'quarkclear': SpiderAccountProvider.quark,
        'baiduclear': SpiderAccountProvider.baidu,
      };
      for (final entry in clearIds.entries) {
        final action = SpiderAccountAction.fromVod(
          markedVod(entry.key, provider: entry.value.name, operation: 'clear'),
        );
        expect(action?.scanOnly, isFalse, reason: '${entry.key} 不是扫码条目');
      }
    });

    test('扫码/注册条目的 provider/operation 不匹配仍拒绝', () {
      const scanOnlyIds = <String>[
        'quark',
        'qkregister',
        'baidu',
        'baiduregister',
      ];
      for (final id in scanOnlyIds) {
        final provider = id.startsWith('quark') || id.startsWith('qk')
            ? SpiderAccountProvider.baidu.name
            : SpiderAccountProvider.quark.name;
        expect(
          SpiderAccountAction.fromVod(markedVod(id, provider: provider)),
          isNull,
          reason: '$id 的伪造 provider 必须拒绝',
        );
        expect(
          SpiderAccountAction.fromVod(markedVod(id, operation: 'clear')),
          isNull,
          reason: '$id 的伪造 operation 必须拒绝',
        );
        expect(
          SpiderAccountAction.fromVod(markedVod(id, operation: 'registration')),
          isNull,
        );
      }
    });
    test('标记不是 map（字符串/列表/数字）一律拒绝', () {
      for (final value in <Object>[
        jsonEncode(marker()),
        <Object?>[1, 'quark', 'edit'],
        7,
      ]) {
        expect(
          SpiderAccountAction.fromVod(
            vodWith({VodAccountActionKey: value}),
          ),
          isNull,
        );
      }
    });

    test('标记中多余字段或多余键不算合法操作', () {
      final extra = marker()..['path'] = 'Wex_other_cookie';
      expect(
        SpiderAccountAction.fromVod(vodWith({VodAccountActionKey: extra})),
        isNull,
      );
    });

    test('Vod.fromJson 保留标记且普通字段不受影响', () {
      final raw = <String, Object?>{
        'vod_id': 'baidumanual',
        'vod_name': '百度账号',
        VodAccountActionKey: marker(provider: 'baidu'),
        'vod_remarks': '备注',
      };
      final vod = Vod.fromJson(raw);
      expect(vod, isNotNull);
      expect(vod!.vodId, 'baidumanual');
      expect(vod.vodRemarks, '备注');
      final action = SpiderAccountAction.fromVod(vod);
      expect(action?.provider, SpiderAccountProvider.baidu);
      expect(action?.operation, SpiderAccountOperation.edit);
      final copied = Vod.fromJson(jsonDecode(jsonEncode(raw)));
      expect(SpiderAccountAction.fromVod(copied!)?.provider, SpiderAccountProvider.baidu);
    });
  });
}
