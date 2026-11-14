/// Phase 5 · 安卓历史/设置同步纯逻辑（`docs/phase5/design/02`）。
///
/// 对应门禁：`docs/phase5/design/03` §3.2「key 切分 / 单位直传 / 哨兵值 /
/// 反向映射 / 合并五种裁决 / 删除标记 / 统计明细 / SyncOptions 子集 / 脱敏」。
///
/// 其中三组断言是**反向验证的靶子**（`design/03` §4.3）：
/// - 单位直传（#2 破坏点：加 `/1000` 换算）；
/// - 旧不覆盖新（#3 破坏点：远端总是胜）；
/// - 哨兵值过滤（#4 破坏点：不过滤）；
/// - 删除标记（#5 破坏点：移除检查）；
/// - `settings` 默认关闭（#6 破坏点：默认改 `true`）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';

import 'fixture_support.dart';

/// 安卓 `C.TIME_UNSET`（`Long.MIN_VALUE`）。
const int androidTimeUnset = -9223372036854775808;

/// fixture 里的真实 `History` 形态（含哨兵 `opening`/`ending`）。
List<Object?> androidHistoryFixture() =>
    jsonDecode(readFixture('android/history-android.json')) as List<Object?>;

Object? androidBackupFixture() =>
    jsonDecode(readFixture('android/backup-android.json'));

Object? androidSyncOptionsFixture() =>
    jsonDecode(readFixture('android/sync-options.json'));

/// 造一条最小可用的安卓 `History` JSON。
Map<String, Object?> androidHistoryJson({
  String key = 'csp_Media@@@demo-001@@@1',
  String vodName = '示例剧集',
  String vodPic = '',
  String vodFlag = '线路一',
  String vodRemarks = '第2集',
  String episodeUrl = 'http://h/ep.m3u8',
  Object? position = 123456,
  Object? duration = 2700000,
  Object? createTime = 1791450000000,
  Object? opening,
  Object? ending,
}) => {
  'key': key,
  'vodName': vodName,
  'vodPic': vodPic,
  'vodFlag': vodFlag,
  'vodRemarks': vodRemarks,
  'episodeUrl': episodeUrl,
  'position': position,
  'duration': duration,
  'createTime': createTime,
  'opening': ?opening,
  'ending': ?ending,
};

/// 从 JSON 解析一条记录，解析失败即测试失败。
SyncHistoryItem itemFrom(Map<String, Object?> json) {
  final item = SyncHistoryItem.tryFromJson(json);
  expect(item, isNotNull, reason: '期望可解析：$json');
  return item!;
}

SyncHistoryItem localItem({
  String siteKey = 'csp_Media',
  String vodId = 'demo-001',
  String flag = '线路一',
  String episodeId = 'http://h/ep.m3u8',
  int positionMs = 100000,
  int durationMs = 2700000,
  int updatedAt = 1791450000000,
}) => SyncHistoryItem.fromLocal(
  siteKey: siteKey,
  vodId: vodId,
  vodName: '示例剧集',
  flag: flag,
  episodeName: '第2集',
  episodeId: episodeId,
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAt: updatedAt,
);

void main() {
  group('历史键切分（design/02 §3.4）', () {
    test('1 · 三段 key 切出 siteKey/vodId/cid', () {
      const text = 'a@@@b@@@7';
      final key = AndroidHistoryKey.tryParse(text);
      expect(key, isNotNull, reason: '记录 #1：key 切分');
      expect(key!.siteKey, 'a');
      expect(key.vodId, 'b');
      expect(key.cid, 7);
      // 往返回原（反向映射要能重建同一形态）。
      expect(key.toString(), text);
    });

    test('2 · 缺段 key：两段 cid=0；单段非法被跳过', () {
      // 记录 #2：`a@@@b` → cid=0。
      final two = AndroidHistoryKey.tryParse('a@@@b');
      expect(two, isNotNull);
      expect(two!.cid, 0);
      expect(two.siteKey, 'a');
      expect(two.vodId, 'b');

      // `a` → 非法，整条被跳过（不得猜造 vodId）。
      expect(AndroidHistoryKey.tryParse('a'), isNull);
      expect(AndroidHistoryKey.tryParse(''), isNull);
      expect(AndroidHistoryKey.tryParse('@@@b'), isNull, reason: 'siteKey 为空');
      expect(AndroidHistoryKey.tryParse('a@@@'), isNull, reason: 'vodId 为空');

      // 非法条目在列表解析里必须计入失败明细，而不是静默丢弃（P5）。
      final parsed = SyncHistoryParseResult.parse([
        androidHistoryJson(key: 'csp_Media@@@demo-001@@@1'),
        androidHistoryJson(key: 'invalid-no-separator'),
      ]);
      expect(parsed.items, hasLength(1));
      expect(parsed.failures, hasLength(1));
      expect(parsed.failures.first.index, 1);
      expect(parsed.total, 2);
    });

    test('fixture 中的两段键记录被解析为 cid=0', () {
      final parsed = SyncHistoryParseResult.parse(androidHistoryFixture());
      expect(parsed.failures, isEmpty);
      final twoSegment = parsed.items.firstWhere(
        (item) => item.vodId == 'demo-003',
      );
      expect(twoSegment.cid, 0);
    });
  });

  group('字段映射与单位（design/02 §3.4）', () {
    test('3 · position/duration/createTime 毫秒直传，无任何换算', () {
      // 记录 #3：单位用例。反向验证 #2 会在这里加 `/1000`，必须失败。
      final item = itemFrom(
        androidHistoryJson(
          position: 123456,
          duration: 654321,
          createTime: 1791450000000,
        ),
      );
      expect(item.positionMs, 123456, reason: '毫秒直传，禁止秒换算');
      expect(item.durationMs, 654321);
      expect(item.updatedAt, 1791450000000);

      // 反向映射同样直传（同一次往返不能改变进度）。
      final back = item.toAndroidJson();
      expect(back['position'], 123456);
      expect(back['duration'], 654321);
      expect(back['createTime'], 1791450000000);
    });

    test('4 · opening/ending 哨兵值 Long.MIN_VALUE → null，不溢出', () {
      // 记录 #4：反向验证 #4 的靶子。
      final item = itemFrom(
        androidHistoryJson(opening: androidTimeUnset, ending: androidTimeUnset),
      );
      expect(item.openingMs, isNull, reason: 'Long.MIN_VALUE 必须被过滤');
      expect(item.endingMs, isNull);
      expect(isAndroidSentinel(androidTimeUnset), isTrue);

      // 从 fixture 读到的真实记录也必须被过滤（形态不能被伪造掩盖）。
      final parsed = SyncHistoryParseResult.parse(androidHistoryFixture());
      final first = parsed.items.first;
      expect(first.openingMs, isNull);
      expect(first.endingMs, isNull);

      // 防御：任何非正数都视为"没有值"，不能落库成 0。
      expect(normalizeAndroidMs(0), isNull);
      expect(normalizeAndroidMs(-1), isNull);
      expect(normalizeAndroidMs('not-a-number'), isNull);
    });

    test('5 · opening 正常值保留', () {
      // 记录 #5。
      final item = itemFrom(
        androidHistoryJson(opening: 60000, ending: 2600000),
      );
      expect(item.openingMs, 60000);
      expect(item.endingMs, 2600000);
    });

    test('6 · vodPic 空串 → null；非空原样保留', () {
      // 记录 #6。
      expect(itemFrom(androidHistoryJson(vodPic: '')).vodPic, isNull);
      expect(
        itemFrom(androidHistoryJson(vodPic: ' http://h/p.jpg ')).vodPic,
        ' http://h/p.jpg ',
      );
    });

    test('7 · vodRemarks/vodFlag 空串保留为空串（不折叠成 null）', () {
      // 记录 #7：空串与缺失语义不同，直传。
      final item = itemFrom(
        androidHistoryJson(vodRemarks: '', vodFlag: ''),
      );
      expect(item.episodeName, '');
      expect(item.flag, '');
      expect(item.episodeId, isNotEmpty, reason: 'episodeUrl 直传');
    });

    test('8 · TMDB 字段保留在 raw', () {
      // 记录 #8：Phase 5 不参与 PC 的 TMDB 逻辑，但往返不得丢信息。
      final item = itemFrom(androidHistoryFixture().first as Map<String, Object?>);
      expect(item.raw['tmdbId'], 1399);
      expect(item.raw['mediaType'], 'tv');
      expect(item.raw['tmdbSeasonNumber'], 2);
      expect(item.raw['tmdbEpisodeNumber'], 5);
      expect(item.raw['sourceBindingKey'], '线路一#0');
      expect(item.raw['cid'], 1, reason: 'cid 保留在 raw');
    });

    test('缺少 vodName 的记录被判为非法而不是空串填充', () {
      final parsed = SyncHistoryParseResult.parse([
        {'key': 'a@@@b@@@1'},
      ]);
      expect(parsed.items, isEmpty);
      expect(parsed.failures, hasLength(1));
    });
  });

  group('反向映射（design/02 §3.5）', () {
    test('9 · key 以 @@@0 结尾（cid 由安卓重映射）', () {
      // 记录 #9。
      final item = localItem(siteKey: 'csp_Media', vodId: 'demo-001');
      final json = item.toAndroidJson();
      expect(json['key'], 'csp_Media@@@demo-001@@@0');
      expect((json['key'] as String).endsWith('@@@0'), isTrue);
    });

    test('10 · 省略 opening/ending，让安卓用自身哨兵默认值', () {
      // 记录 #10。
      final json = localItem().toAndroidJson();
      expect(json.containsKey('opening'), isFalse);
      expect(json.containsKey('ending'), isFalse);
    });

    test('11 · speed 固定 1.0', () {
      // 记录 #11。
      expect(localItem().toAndroidJson()['speed'], 1.0);
    });

    test('反向映射保留 PC 侧字段语义（vodName/flag/remarkers/episodeUrl）', () {
      final json = localItem().toAndroidJson();
      expect(json['vodName'], '示例剧集');
      expect(json['vodFlag'], '线路一');
      expect(json['vodRemarks'], '第2集');
      expect(json['episodeUrl'], 'http://h/ep.m3u8');
      expect(json['vodPic'], '', reason: 'null → 空串');
    });

    test('completed 按 position >= duration - 5000 重算（design/02 §8 Q7）', () {
      expect(localItem(positionMs: 2700000, durationMs: 2700000).completed, isTrue);
      expect(localItem(positionMs: 2695000, durationMs: 2700000).completed, isTrue);
      expect(localItem(positionMs: 2694000, durationMs: 2700000).completed, isFalse);
      // duration 未知时不得判为"看完"。
      expect(localItem(positionMs: 1000, durationMs: 0).completed, isFalse);
    });
  });

  group('合并裁决（design/02 §4.4）', () {
    /// 与 [localItem] 同匹配键（siteKey/vodId/flag/episodeId 相同）。
    SyncHistoryItem incomingAt(int updatedAt, {int positionMs = 200000}) =>
      itemFrom(
        androidHistoryJson(
          position: positionMs,
          createTime: updatedAt,
          episodeUrl: 'http://h/ep.m3u8',
        ),
      );

    test('12 · 本地无该条 → insert', () {
      // 记录 #12。
      final decision = decideHistoryMerge(
        incoming: incomingAt(1791450000000),
        local: null,
      );
      expect(decision.action, SyncMergeAction.insert);
      expect(decision.isApplied, isTrue);
    });

    test('13 · 远端更新 → upsert', () {
      // 记录 #13。
      final decision = decideHistoryMerge(
        incoming: incomingAt(1791460000000),
        local: localItem(updatedAt: 1791450000000),
      );
      expect(decision.action, SyncMergeAction.upsert);
      expect(decision.isApplied, isTrue);
    });

    test('14 · 时间戳相等 → skip（幂等）', () {
      // 记录 #14。
      final decision = decideHistoryMerge(
        incoming: incomingAt(1791450000000),
        local: localItem(updatedAt: 1791450000000),
      );
      expect(decision.action, SyncMergeAction.skip);
      expect(decision.reason, contains('幂等'));
    });

    test('15 · 远端更旧 → skip（旧不覆盖新）', () {
      // 记录 #15：反向验证 #3 的靶子（改成"远端总是胜"必须让它失败）。
      final decision = decideHistoryMerge(
        incoming: incomingAt(1791400000000, positionMs: 5000),
        local: localItem(updatedAt: 1791450000000, positionMs: 800000),
      );
      expect(decision.action, SyncMergeAction.skip);
      expect(decision.isApplied, isFalse);
      expect(decision.reason, contains('旧不覆盖新'));
    });

    test('匹配键不含 cid（安卓 cid 会随配置重映射）', () {
      // 同一集即使 cid 不同也必须匹配上，否则每次同步都会插重复行。
      final a = itemFrom(androidHistoryJson(key: 'csp_Media@@@demo-001@@@1'));
      final b = itemFrom(androidHistoryJson(key: 'csp_Media@@@demo-001@@@9'));
      expect(a.matchKey, b.matchKey);

      // 集不同则必须不匹配。
      final other = itemFrom(
        androidHistoryJson(
          key: 'csp_Media@@@demo-001@@@1',
          episodeUrl: 'http://h/ep-2.m3u8',
        ),
      );
      expect(a.matchKey, isNot(other.matchKey));
    });

    test('线路不同不匹配（同一剧不同线路是不同记录）', () {
      final a = itemFrom(androidHistoryJson(vodFlag: '线路一'));
      final b = itemFrom(androidHistoryJson(vodFlag: '线路二'));
      expect(a.matchKey, isNot(b.matchKey));
    });

    test('合并计划逐条裁决，且 skipped 不产生任何删除动作', () {
      final local = localItem(updatedAt: 1791450000000);
      final plan = buildHistoryMergePlan(
        parsed: SyncHistoryParseResult.parse([
          // 同一条、更新的 → upsert
          androidHistoryJson(createTime: 1791460000000, episodeUrl: 'http://h/ep.m3u8'),
          // 同一条、更旧的 → skip
          androidHistoryJson(createTime: 1791400000000, episodeUrl: 'http://h/ep.m3u8'),
          // 同一条、相同 → skip
          androidHistoryJson(createTime: 1791450000000, episodeUrl: 'http://h/ep.m3u8'),
          // 另一条本地没有 → insert
          androidHistoryJson(
            key: 'csp_Other@@@demo-999@@@1',
            episodeUrl: 'http://h/ep-999.m3u8',
          ),
        ]),
        localByMatchKey: {local.matchKey: local},
      );
      expect(plan.upserts, hasLength(1));
      expect(plan.inserts, hasLength(1));
      expect(plan.skipped, 2);
      expect(plan.failures, isEmpty);
      expect(plan.total, 4);
    });

    test('解析失败条目计入 failed，且 applied+skipped+failed == total', () {
      final plan = buildHistoryMergePlan(
        parsed: SyncHistoryParseResult.parse([
          {'key': 'broken'},
          androidHistoryJson(key: 'csp_Media@@@demo-001@@@1'),
        ]),
        localByMatchKey: const {},
      );
      expect(plan.failures, hasLength(1));
      expect(plan.inserts, hasLength(1));
      expect(plan.stats.failed, 1);
      expect(plan.stats.total, 2);
      expect(plan.stats.applied, 1);
    });
  });

  group('删除标记（design/02 §4.5）', () {
    /// 与 [localItem] 同匹配键的远端记录。
    SyncHistoryItem incomingAt(int updatedAt) =>
      itemFrom(androidHistoryJson(createTime: updatedAt));

    test('16 · 远端旧于删除时间 → skip，不复活', () {
      // 记录 #16：反向验证 #5 的靶子。
      const deletedAt = 1791455000000;
      final decision = decideHistoryMerge(
        incoming: incomingAt(1791450000000),
        local: null,
        localDeletedAt: deletedAt,
      );
      expect(decision.action, SyncMergeAction.skip);
      expect(decision.isApplied, isFalse);
      expect(decision.reason, contains('不复活'));
    });

    test('17 · 远端新于删除时间 → insert（用户重新观看后应恢复）', () {
      // 记录 #17。
      const deletedAt = 1791455000000;
      final decision = decideHistoryMerge(
        incoming: incomingAt(1791460000000),
        local: null,
        localDeletedAt: deletedAt,
      );
      expect(decision.action, SyncMergeAction.insert);
    });

    test('删除时间与远端时间相等视为复活后的新记录', () {
      const deletedAt = 1791455000000;
      final decision = decideHistoryMerge(
        incoming: incomingAt(deletedAt),
        local: null,
        localDeletedAt: deletedAt,
      );
      expect(decision.action, SyncMergeAction.insert);
    });

    test('本地仍有记录时删除标记不再拦截（用户后来又看了）', () {
      final decision = decideHistoryMerge(
        incoming: incomingAt(1791400000000),
        local: localItem(updatedAt: 1791450000000),
        localDeletedAt: 1791455000000,
      );
      // 结论仍是 skip，但理由必须是"旧不覆盖新"，而不是删除标记。
      expect(decision.action, SyncMergeAction.skip);
      expect(decision.reason, contains('旧不覆盖新'));
    });

    test('计划层面：删除标记拦截的条目计入 skipped 而非 applied', () {
      const deletedAt = 1791455000000;
      final item = incomingAt(1791450000000);
      final plan = buildHistoryMergePlan(
        parsed: SyncHistoryParseResult(items: [item], failures: const []),
        localByMatchKey: const {},
        deletedAtByMatchKey: {item.matchKey: deletedAt},
      );
      expect(plan.inserts, isEmpty);
      expect(plan.skipped, 1);
      expect(plan.stats.applied, 0);
    });
  });

  group('统计明细（design/02 §4.3 / §6）', () {
    test('18 · applied+skipped+failed == total', () {
      // 记录 #18。
      const stats = SyncMergeStats(
        applied: 3,
        skipped: 2,
        failed: 1,
        total: 6,
      );
      expect(stats.isConsistent, isTrue);
      expect(stats.describe(), contains('applied=3'));
      expect(stats.describe(), contains('skipped=2'));
      expect(stats.describe(), contains('failed=1'));
      expect(stats.describe(), contains('total=6'));
      expect(stats.describe(), contains('consistent=true'));
      expect(stats.toJson()['total'], 6);

      // 明细未闭合必须被识别出来（服务端据此拒绝回报"成功"）。
      const broken = SyncMergeStats(
        applied: 1,
        skipped: 0,
        failed: 0,
        total: 2,
      );
      expect(broken.isConsistent, isFalse);

      expect(const SyncMergeStats.empty().isConsistent, isTrue);
      expect(const SyncMergeStats.empty().total, 0);
    });
  });

  group('SyncOptions 子集（design/02 §3.6）', () {
    test('19 · 默认子集 history=true, keep=true，其余 false', () {
      // 记录 #19：对端 fixture 的 config/spider/webHome 都是 true，
      // PC 必须全部收敛为 false（否则会误以为要同步站点配置）。
      final options = SyncOptions.fromJson(androidSyncOptionsFixture());
      expect(options.history, isTrue);
      expect(options.keep, isTrue);
      expect(options.config, isFalse, reason: 'P1：桥接不复制站点配置');
      expect(options.spider, isFalse);
      expect(options.search, isFalse);
      expect(options.follow, isFalse);
      expect(options.webHome, isFalse);
      expect(options.loginState, isFalse);
      expect(options.remoteRelay, isFalse);
      expect(options.mpvConfig, isFalse);
      expect(options.paths, '');
      expect(SyncOptions.pcDefault.history, isTrue);
      expect(SyncOptions.pcDefault.keep, isTrue);
    });

    test('20 · settings 默认关闭', () {
      // 记录 #20：反向验证 #6 的靶子。
      final options = SyncOptions.fromJson(androidSyncOptionsFixture());
      expect(options.settings, isFalse, reason: '含凭据项默认不同步（P3）');

      // fixture 的 settings 本身就是 false，因此还要显式验证
      // "对端说 true 也不接受"。
      final forced = SyncOptions.fromJson({'settings': true, 'history': true});
      expect(forced.settings, isFalse);
      expect(
        SyncOptions.fromJson({'settings': true}, allowSettings: true).settings,
        isTrue,
        reason: '用户显式确认后才接受',
      );

      // 序列化必须写全字段（省略键会让安卓回落到它自己的默认值）。
      final json = SyncOptions.pcDefault.toJson();
      expect(json, hasLength(12));
      for (final key in const [
        'config',
        'spider',
        'search',
        'follow',
        'webHome',
        'settings',
        'loginState',
        'remoteRelay',
        'mpvConfig',
      ]) {
        expect(json[key], isFalse, reason: '$key 必须显式写 false');
      }
      expect(json['history'], isTrue);
      expect(json['keep'], isTrue);
      expect(json['paths'], '');
    });

    test('21 · Backup.prefers 只取白名单键，凭据默认排除', () {
      // 记录 #21。
      final backup = androidBackupFixture();
      final safe = SyncSettings.fromBackup(backup);
      expect(safe.sensitiveIncluded, isFalse);
      expect(safe.values.containsKey('tmdb_config'), isFalse, reason: '含凭据默认不同步');
      expect(safe.describe(), isNot(contains('tmdb_config')));

      final withSensitive = SyncSettings.fromBackup(
        backup,
        allowSensitive: true,
      );
      expect(
        withSensitive.values.containsKey('tmdb_config') ||
            withSensitive.values.containsKey('tmdb_enabled'),
        isTrue,
        reason: '白名单内的键应被取出',
      );
      expect(withSensitive.skippedKeys, isNot(contains('tmdb_enabled')));

      // 白名单外（安卓专有）键一律丢弃并记录，便于向用户披露。
      final inline = SyncSettings.fromBackup({
        'prefers': {
          'tmdb_enabled': true,
          'tmdb_model': 'gpt-x',
          'viewing_record_sync_enabled': true,
          'ai_config': '{"key":"secret"}',
        },
      });
      expect(inline.values.containsKey('tmdb_enabled'), isTrue);
      expect(inline.values.containsKey('tmdb_model'), isFalse);
      expect(inline.values.containsKey('viewing_record_sync_enabled'), isFalse);
      expect(inline.values.containsKey('ai_config'), isFalse);
      expect(inline.skippedKeys, contains('ai_config'));
    });
  });

  group('脱敏（design/02 §7）', () {
    test('22 · 片名/图片/播放地址不出现在任何描述输出中', () {
      // 记录 #22。
      final item = itemFrom(
        androidHistoryJson(
          vodName: '示例剧集·机密片名',
          vodPic: 'http://h/secret-poster.jpg',
          episodeUrl: 'http://h/secret-ep.m3u8',
        ),
      );
      final text = item.describe();
      expect(text, isNot(contains('机密片名')));
      expect(text, isNot(contains('secret-poster')));
      expect(text, isNot(contains('secret-ep')));
      // 非敏感信息保留，便于排障。
      expect(text, contains('csp_Media'));
      expect(text, contains('123456'));

      // SyncSettings 只报键名，永不输出值。
      final settings = SyncSettings.fromBackup({
        'prefers': {'tmdb_config': '{"apiKey":"secret-key"}'},
      }, allowSensitive: true);
      expect(settings.describe(), isNot(contains('secret-key')));
      expect(settings.toJson().toString(), contains('secret-key'),
          reason: '数据本身要保留（要同步），只是不能进日志');
    });

    test('合并裁决理由不含片名', () {
      final plan = buildHistoryMergePlan(
        parsed: SyncHistoryParseResult.parse([
          androidHistoryJson(vodName: '示例剧集·机密片名'),
        ]),
        localByMatchKey: const {},
      );
      expect(plan.describe(), isNot(contains('机密片名')));
    });
  });

  group('/action 请求校验与路径构造（design/02 §3.3 / §3.2）', () {
    const enabled = true;
    const authorized = true;

    SyncRequestCheck check(
      Map<String, String> params,
      Map<String, String> form, {
      bool syncEnabled = enabled,
      bool peerOk = authorized,
    }) => validateSyncAction(
      params: params,
      form: form,
      enabled: syncEnabled,
      peerAuthorized: peerOk,
    );

    test('缺 type / 未知 type → 400 且 message 明确', () {
      expect(check(const {'mode': '1'}, const {}).status, 400);
      expect(
        check(const {'mode': '1', 'type': 'unknown'}, const {}).message,
        contains('type'),
      );
    });

    test('mode 非法 → 400', () {
      final result = check(const {'mode': '9', 'type': 'history'}, const {});
      expect(result.status, 400);
      expect(result.message, contains('mode'));
    });

    test('type=history 缺 config → 400 config 不能为空', () {
      // 安卓侧缺 config 是 500 NPE；PC 必须给出可行动的 400。
      final result = check(
        const {'mode': '1', 'type': 'history'},
        const {'targets': '[]'},
      );
      expect(result.status, 400);
      expect(result.message, 'config 不能为空');
    });

    test('type=history config 非法 JSON → 400', () {
      final result = check(
        const {'mode': '1', 'type': 'history'},
        const {'config': '{not json', 'targets': '[]'},
      );
      expect(result.status, 400);
      expect(result.message, contains('JSON'));
    });

    test('type=history 缺 targets / 非数组 → 400', () {
      expect(
        check(
          const {'mode': '1', 'type': 'history'},
          const {'config': '{}'},
        ).message,
        'targets 必须是 JSON 数组',
      );
      expect(
        check(
          const {'mode': '1', 'type': 'history'},
          const {'config': '{}', 'targets': '{}'},
        ).message,
        'targets 必须是 JSON 数组',
      );
    });

    test('空数组 targets 是合法请求（total=0，不是错误）', () {
      final result = check(
        const {'mode': '1', 'type': 'history'},
        const {'config': '{}', 'targets': '[]'},
      );
      expect(result.isOk, isTrue);
      expect(result.status, 200);
    });

    test('同步未开启 → 403；对端未授权 → 403', () {
      final disabled = check(
        const {'mode': '1', 'type': 'history'},
        const {'config': '{}', 'targets': '[]'},
        syncEnabled: false,
      );
      expect(disabled.status, 403);
      expect(disabled.message, contains('同步未开启'));

      final unauthorized = check(
        const {'mode': '1', 'type': 'history'},
        const {'config': '{}', 'targets': '[]'},
        peerOk: false,
      );
      expect(unauthorized.status, 403);
      expect(unauthorized.message, contains('未授权'));
    });

    test('keep 与 backup 的载荷校验', () {
      expect(
        check(
          const {'mode': '1', 'type': 'keep'},
          const {'targets': '[]', 'configs': '[]'},
        ).isOk,
        isTrue,
      );
      expect(
        check(const {'mode': '1', 'type': 'keep'}, const {}).status,
        400,
      );
      expect(
        check(
          const {'mode': '1', 'type': 'backup'},
          const {'options': '{}', 'backup': '{}'},
        ).isOk,
        isTrue,
      );
      expect(
        check(
          const {'mode': '1', 'type': 'backup'},
          const {'options': '{}', 'backup': '[]'},
        ).status,
        400,
      );
    });

    test('路径构造：mode 语义锁定在"被请求方视角"', () {
      // 推送给安卓 = mode 1（请接收）。
      expect(
        buildSyncActionPath(mode: '1', type: 'history'),
        '/action?do=sync&mode=1&type=history',
      );
      // 请求安卓主动推给 PC = mode 0（请发送）。
      expect(
        buildSyncActionPath(mode: '0', type: 'history', deviceJson: '{}'),
        contains('mode=0'),
      );
      expect(
        buildSyncActionPath(mode: '2', type: 'keep', force: true),
        contains('force=true'),
      );
      expect(
        () => buildSyncActionPath(mode: '9', type: 'history'),
        throwsArgumentError,
      );
      expect(
        () => buildSyncActionPath(mode: '1', type: 'nope'),
        throwsArgumentError,
      );
    });
  });
}
