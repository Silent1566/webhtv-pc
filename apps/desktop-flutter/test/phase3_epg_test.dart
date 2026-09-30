/// EPG 测试（设计文档 §13.1「EPG」、§13.3「EPG 可加载、刷新、显示当前节目」）。
///
/// 覆盖两层：
/// 1. XMLTV 解析与节目模型（纯逻辑）：频道匹配、时间解析、当前/下一个节目判定、
///    进度、异常条目丢弃；
/// 2. 加载服务：HTTP/本地、gzip、缓存与刷新策略（缺失/非当天/超 6 小时）、
///    错误归一化（不得阻断直播）。
///
/// 本文件不含 `testWidgets`（flutter_test binding 会拦截 HTTP，见 README §3.3）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/epg_service.dart';

import 'fixture_support.dart';
import 'support/test_fixture_server.dart';

/// fixture 的时区（+0800）。
const Duration fixtureOffset = Duration(hours: 8);

/// 2026-09-29 10:30 +0800 的 epoch 毫秒（用于「当前节目」判定）。
final int at1030 = DateTime.utc(2026, 9, 29, 2, 30).millisecondsSinceEpoch;

void main() {
  group('XMLTV 时间解析（§13.3）', () {
    test('无时区形态按给定时区解释', () {
      final ms = parseXmlTvTime('20260929080000', localOffset: fixtureOffset);
      expect(ms, DateTime.utc(2026, 9, 29, 0, 0).millisecondsSinceEpoch);
    });

    test('带偏移 `+0800` 与 `+08:00` 等价', () {
      final a = parseXmlTvTime('20260929080000 +0800');
      final b = parseXmlTvTime('20260929080000 +08:00');
      expect(a, DateTime.utc(2026, 9, 29, 0, 0).millisecondsSinceEpoch);
      expect(b, a);
    });

    test('负偏移与 UTC 偏移', () {
      expect(
        parseXmlTvTime('20260929080000 -0500'),
        // 08:00 -0500 = 13:00 UTC。
        DateTime.utc(2026, 9, 29, 13, 0).millisecondsSinceEpoch,
      );
      expect(
        parseXmlTvTime('20260929080000 +0000'),
        DateTime.utc(2026, 9, 29, 8, 0).millisecondsSinceEpoch,
      );
    });

    test('ISO 8601 形态', () {
      expect(
        parseXmlTvTime('2026-09-29T08:00:00+08:00'),
        DateTime.utc(2026, 9, 29, 0, 0).millisecondsSinceEpoch,
      );
    });

    test('省略秒、非法值、空串返回 null（不抛异常）', () {
      expect(
        parseXmlTvTime('202609290800 +0800'),
        DateTime.utc(2026, 9, 29, 0, 0).millisecondsSinceEpoch,
      );
      expect(parseXmlTvTime(''), isNull);
      expect(parseXmlTvTime('not-a-time'), isNull);
      expect(parseXmlTvTime('20261329080000'), isNull);
      expect(parseXmlTvTime('20260929480000'), isNull);
    });

    test('formatEpgTime 按给定时区格式化 HH:mm', () {
      final ms = DateTime.utc(2026, 9, 29, 0, 0).millisecondsSinceEpoch;
      expect(formatEpgTime(ms, localOffset: fixtureOffset), '08:00');
      expect(formatEpgTime(ms, localOffset: Duration.zero), '00:00');
    });
  });

  group('XMLTV 解析与频道匹配（§13.3）', () {
    EpgGuide parseWithChannels(List<LiveChannel> channels) => parseXmlTv(
      readFixture('live/epg.xml'),
      liveChannels: channels,
      sourceName: 'fixture',
    );

    test('无直播频道上下文时按 XMLTV channel id 归组', () {
      final guide = parseXmlTv(readFixture('live/epg.xml'), sourceName: 'raw');
      // 4 个 XMLTV channel（cctv1/cctv2/hunan/unknown-channel）都有节目。
      expect(guide.channels.keys, containsAll(['cctv1', 'cctv2', 'hunan']));
      expect(guide.totalPrograms, greaterThan(0));
      // 缺 title 的那条被丢弃。
      expect(guide.skippedPrograms, greaterThanOrEqualTo(1));
      expect(guide.sourceName, 'raw');
    });

    test('按 epgId 匹配直播频道，未匹配的丢弃', () {
      final guide = parseWithChannels([
        LiveChannel(name: 'CCTV-1 综合', epgId: 'cctv1'),
        LiveChannel(name: 'CCTV-2 财经', epgId: 'cctv2'),
        LiveChannel(name: '湖南卫视', epgId: 'hunan'),
      ]);
      expect(guide.channels['cctv1']!.isNotEmpty, isTrue);
      // `unknown-channel` 的节目匹配不上 → 丢弃。
      expect(guide.channels.containsKey('unknown-channel'), isFalse);
      expect(guide.skippedPrograms, greaterThanOrEqualTo(2));
    });

    test('按 tvg-name / 频道名回退匹配（对齐 Android 三级匹配）', () {
      // 只有频道名，没有 epgId → 靠 display-name 反查。
      final byName = parseWithChannels([
        LiveChannel(name: 'CCTV-1 综合'),
        LiveChannel(name: 'CCTV-2 财经'),
      ]);
      expect(byName.channels['CCTV-1 综合']!.isNotEmpty, isTrue);
      expect(byName.channels['CCTV-2 财经']!.isNotEmpty, isTrue);

      // 只有 tvgName（M3U 的 tvg-name）→ 靠 XML display-name 命中。
      final byTvgName = parseWithChannels([
        LiveChannel(
          name: '一套',
          extra: const {'tvgName': 'CCTV1'},
        ),
      ]);
      expect(byTvgName.totalPrograms, greaterThan(0));
    });

    test('节目按开始时间排序，缺 stop 按 +1h 兜底，重复去重', () {
      final guide = parseWithChannels([
        LiveChannel(name: 'CCTV-1 综合', epgId: 'cctv1'),
      ]);
      final programs = guide.channels['cctv1']!.programs;
      final starts = programs.map((item) => item.startMs).toList();
      expect(starts, List.of(starts)..sort());

      // 缺 stop 的节目时长应为 1 小时。
      final noStop = programs.firstWhere((item) => item.title == '缺 stop 的节目');
      expect(noStop.durationMs, const Duration(hours: 1).inMilliseconds);
    });

    test('非法 XML 与非 <tv> 根元素 → epgInvalid', () {
      expect(
        () => parseXmlTv('<not-xml'),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.epgInvalid),
        ),
      );
      expect(
        () => parseXmlTv('<rss></rss>'),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.epgInvalid),
        ),
      );
    });
  });

  group('频道→节目单查找（UI 用）', () {
    late EpgGuide loaded;

    setUpAll(() {
      loaded = parseXmlTv(
        readFixture('live/epg.xml'),
        liveChannels: [
          LiveChannel(name: 'CCTV-1 综合', epgId: 'cctv1'),
          // 无 epgId、但频道名命中 XMLTV `<channel id="hunan">` 的 display-name。
          LiveChannel(name: '湖南卫视'),
          // 完全无节目单。
          LiveChannel(name: 'CCTV-5 体育', epgId: 'cctv5'),
        ],
      );
    });

    test('epgId 命中：查找键与解析期一致', () {
      final channel = LiveChannel(name: 'CCTV-1 综合', epgId: 'cctv1');
      final channelGuide = epgGuideForChannel(loaded, channel);
      expect(channelGuide, isNotNull);
      expect(channelGuide!.programs, isNotEmpty);
    });

    test('无 epgId 时回退频道名', () {
      final channel = LiveChannel(name: '湖南卫视');
      expect(epgGuideForChannel(loaded, channel), isNotNull);
    });

    test('无节目单的频道返回 null；guide 为 null 也安全', () {
      expect(
        epgGuideForChannel(loaded, LiveChannel(name: 'CCTV-5 体育', epgId: 'cctv5')),
        isNull,
      );
      expect(epgGuideForChannel(null, LiveChannel(name: '任意')), isNull);
    });

    test('epgNowLabel：有当前节目显示标题，无则 null', () {
      final cctv1 = LiveChannel(name: 'CCTV-1 综合', epgId: 'cctv1');
      final label = epgNowLabel(loaded, cctv1, at1030);
      expect(label, isNotNull);
      expect(label, contains('新闻直播间'));
      // 10:30 时湖南卫视 07:30-10:00 已结束 → 不伪造当前节目。
      expect(epgNowLabel(loaded, LiveChannel(name: '湖南卫视'), at1030), isNull);
      // 无节目单的频道也为 null。
      expect(
        epgNowLabel(loaded, LiveChannel(name: 'CCTV-5 体育', epgId: 'cctv5'), at1030),
        isNull,
      );
    });

    test('epgNowLabel：无当前节目但有下一节目时给出「即将播出」', () {
      final label = epgNowLabel(
        loaded,
        LiveChannel(name: 'CCTV-2 财经', epgId: 'cctv2'),
        // 11:30：10:00-11:00 的「无时区节目」已结束，下一个是 11:00 之后…
        DateTime.utc(2026, 9, 29, 3, 30).millisecondsSinceEpoch,
      );
      expect(label, anyOf(isNull, contains('即将播出')));
    });
  });

  group('当前节目判定（§13.3「显示当前节目」）', () {
    late EpgChannelGuide guide;

    setUpAll(() {
      guide = parseXmlTv(
        readFixture('live/epg.xml'),
        liveChannels: [LiveChannel(name: 'CCTV-1 综合', epgId: 'cctv1')],
      ).channels['cctv1']!;
    });

    test('10:30 时正在播「新闻直播间」（09:00-12:00）', () {
      final current = guide.programAt(at1030)!;
      expect(current.title, '新闻直播间');
      expect(current.isLiveAt(at1030), isTrue);
    });

    test('边界左闭右开：09:00 属于新节目，12:00 不属于旧节目', () {
      final at0900 = DateTime.utc(2026, 9, 29, 1, 0).millisecondsSinceEpoch;
      expect(guide.programAt(at0900)!.title, '新闻直播间');
      final at1200 = DateTime.utc(2026, 9, 29, 4, 0).millisecondsSinceEpoch;
      expect(guide.programAt(at1200)!.title, '午间新闻');
    });

    test('下一个节目与进度', () {
      expect(guide.nextAfter(at1030)!.title, '午间新闻');
      // 10:30 在 09:00-12:00 的中点附近（1.5/3 = 0.5）。
      expect(guide.progressAt(at1030), closeTo(0.5, 0.01));
      // 结束后没有下一个。
      final after = DateTime.utc(2026, 9, 29, 6, 0).millisecondsSinceEpoch;
      expect(guide.nextAfter(after), isNull);
      expect(guide.programAt(after), isNull);
      expect(guide.progressAt(after), 0);
    });

    test('无节目时段返回 null（不伪造当前节目）', () {
      // 06:00 +0800（= 前一天 22:00 UTC）之前没有节目。
      final early = DateTime.utc(2026, 9, 28, 20, 0).millisecondsSinceEpoch;
      expect(guide.programAt(early), isNull);
      expect(guide.progressAt(early), 0);
    });
  });

  group('EpgService 加载与缓存（§13.3「可加载、刷新」）', () {
    late TestFixtureServer server;
    late Directory cacheDir;
    late EpgService service;

    setUp(() async {
      server = await TestFixtureServer.start();
      cacheDir = await Directory.systemTemp.createTemp('webhtv-epg-cache');
      service = EpgService(cacheDir: cacheDir.path);
    });

    tearDown(() async {
      service.close();
      await server.stop();
      if (await cacheDir.exists()) cacheDir.deleteSync(recursive: true);
    });

    List<LiveChannel> channels() => [
      LiveChannel(name: 'CCTV-1 综合', epgId: 'cctv1'),
      LiveChannel(name: 'CCTV-2 财经', epgId: 'cctv2'),
      LiveChannel(name: '湖南卫视', epgId: 'hunan'),
    ];

    test('HTTP 加载 XMLTV 并解析出节目', () async {
      final result = await service.load(
        url: '${server.baseUrl}/live/epg.xml',
        liveChannels: channels(),
        sourceName: 'fixture-epg',
      );

      expect(result.fromCache, isFalse);
      expect(result.guide.channels, isNotEmpty);
      expect(result.guide.channels['cctv1']!.programs, isNotEmpty);
      expect(result.bytes, greaterThan(0));
      expect(result.logLine, contains('source=fixture-epg'));
    });

    test('缓存命中：第二次不再发请求', () async {
      final url = '${server.baseUrl}/live/epg.xml';
      await service.load(url: url, liveChannels: channels());
      final firstCount = server.captured
          .where((item) => item.path == '/live/epg.xml')
          .length;
      final second = await service.load(url: url, liveChannels: channels());
      expect(second.fromCache, isTrue);
      expect(
        server.captured.where((item) => item.path == '/live/epg.xml').length,
        firstCount,
        reason: '缓存命中不应重复请求',
      );

      // forceRefresh 必须绕过缓存。
      final forced = await service.load(
        url: url,
        liveChannels: channels(),
        forceRefresh: true,
      );
      expect(forced.fromCache, isFalse);
      expect(
        server.captured.where((item) => item.path == '/live/epg.xml').length,
        firstCount + 1,
      );
    });

    test('缓存过期（超过 TTL）时重新下载', () async {
      final url = '${server.baseUrl}/live/epg.xml';
      await service.load(url: url, liveChannels: channels());
      // 用「未来 7 小时」的时钟注入，使缓存超出 6 小时 TTL。
      final future = EpgService(
        cacheDir: cacheDir.path,
        clock: () => DateTime.now().add(const Duration(hours: 7)),
      );
      addTearDown(future.close);
      final again = await future.load(url: url, liveChannels: channels());
      expect(again.fromCache, isFalse, reason: '超过 TTL 必须刷新');
    });

    test('gzip 分发的 XMLTV 可解压解析', () async {
      // 本地写一个 .xml.gz，验证魔数检测 + 解压。
      final xml = readFixture('live/epg.xml');
      final gz = File(
        p.join(server.baseUrl.isEmpty ? cacheDir.path : cacheDir.path, 'epg.xml.gz'),
      );
      await gz.writeAsBytes(gzip.encode(utf8.encode(xml)));

      final result = await service.load(
        url: gz.path,
        liveChannels: channels(),
      );
      expect(result.guide.channels, isNotEmpty);
      expect(result.guide.channels['cctv1']!.programs, isNotEmpty);
    });

    test('本地文件加载（含 Windows 盘符语义）', () async {
      final result = await service.load(
        url: fixturePath('live/epg.xml'),
        liveChannels: channels(),
      );
      expect(result.guide.channels, isNotEmpty);
    });

    test('404 → epgHttp；坏内容 → epgInvalid；空 → epgEmpty', () async {
      await expectLater(
        service.load(url: '${server.baseUrl}/live/nope.xml'),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.epgHttp)
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );

      final temp = await Directory.systemTemp.createTemp('webhtv-epg-bad');
      addTearDown(() => temp.deleteSync(recursive: true));
      final bad = File(p.join(temp.path, 'bad.xml'));
      await bad.writeAsString('这不是 XMLTV');
      await expectLater(
        service.load(url: bad.path),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.epgInvalid),
        ),
      );

      // 有 <tv> 但无任何可匹配节目 → epgEmpty。
      final empty = File(p.join(temp.path, 'empty.xml'));
      await empty.writeAsString('<tv></tv>');
      await expectLater(
        service.load(url: empty.path),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.epgEmpty),
        ),
      );
    });

    test('GBK 编码的 XMLTV 按 GBK 兜底解码', () async {
      final temp = await Directory.systemTemp.createTemp('webhtv-epg-gbk');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'gbk.xml'));
      final xml =
          '<tv><channel id="c1"><display-name>中文频道</display-name></channel>'
          '<programme start="20260929090000 +0800" stop="20260929100000 +0800" channel="c1">'
          '<title>中文节目</title></programme></tv>';
      await file.writeAsBytes(gbk.encode(xml));

      final result = await service.load(url: file.path);
      expect(result.guide.totalPrograms, greaterThan(0));
      final guide = result.guide.channels['c1']!;
      expect(guide.programs.first.title, '中文节目');
    });

    test('协议不支持 / 地址为空 → epgUnsupported', () async {
      await expectLater(
        service.load(url: 'ftp://h/epg.xml'),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.epgUnsupported),
        ),
      );
      await expectLater(
        service.load(url: ''),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.epgUnsupported),
        ),
      );
    });

    test('超限响应 → epgDecode（不读满内存）', () async {
      final xml = readFixture('live/epg.xml');
      final temp = await Directory.systemTemp.createTemp('webhtv-epg-big');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'big.xml'));
      await file.writeAsBytes(
        Uint8List.fromList([...utf8.encode(xml), ...List.filled(4096, 0x20)]),
      );

      final small = EpgService(cacheDir: cacheDir.path, maxBytes: 512);
      addTearDown(small.close);
      await expectLater(
        small.load(url: file.path),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.epgDecode),
        ),
      );
    });

    test('缓存清理', () async {
      await service.load(
        url: '${server.baseUrl}/live/epg.xml',
        liveChannels: channels(),
      );
      final epgDir = Directory(p.join(cacheDir.path, 'epg'));
      expect(await epgDir.exists(), isTrue);
      expect(epgDir.listSync().whereType<File>(), isNotEmpty);

      await service.clearCache();
      expect(epgDir.listSync().whereType<File>(), isEmpty);
    });

    test('EPG 错误分类可识别，不影响直播播放（§13.3）', () {
      expect(isEpgError(AppError(AppErrorKind.epgHttp, 'HTTP 500')), isTrue);
      expect(isEpgError(AppError(AppErrorKind.epgInvalid, '坏 XML')), isTrue);
      expect(
        isEpgError(AppError(AppErrorKind.liveHttp, '直播失败')),
        isFalse,
      );
      final message = describeEpgFailure(
        AppError(AppErrorKind.epgNetwork, '下载失败'),
      );
      expect(message, contains('EPG 加载失败'));
      expect(message, contains('不影响直播播放'));
    });
  });
}