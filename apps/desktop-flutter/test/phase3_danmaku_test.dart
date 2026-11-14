/// 弹幕测试（设计文档 §21 Phase 3「字幕/弹幕可开启和关闭」、§8.3 Result 协议）。
///
/// 覆盖五层：
/// 1. 模型：`Result.danmaku` → `DanmakuSource` 的宽松解析（字符串/对象/信封/内嵌 JSON）；
/// 2. 解析：Bilibili XML 与行式文本，逐条对齐 media3 `TxtParser`/`BiliParser`；
/// 3. 加载服务：HTTP（带 Header）/本地/GBK 兜底/大小上限/各类错误归一化；
/// 4. 渲染布局：轨道分配与可见性（纯逻辑，确定性可测）；
/// 5. 开关与失败隔离：关闭时不产出任何可见弹幕；失败不得升级为播放失败。
library;

import 'dart:io';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/danmaku.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/danmaku_service.dart';

import 'fixture_support.dart';
import 'support/test_fixture_server.dart';

SiteResult parsePlayResult(String fixture) => HttpApiResponseParser.parse(
  readFixture(fixture),
  siteKey: 'fixture-type1',
);

void main() {
  group('弹幕源模型（§8.3、Phase 3）', () {
    test('从播放结果解析 danmaku：字符串/对象混合，缺 url 丢弃', () {
      final result = parsePlayResult('http/play-with-danmaku.json');

      expect(result.danmaku, hasLength(4));
      expect(result.danmaku.first.name, 'Bilibili XML 弹幕');
      expect(result.danmaku.first.source, 'sample');
      expect(result.danmaku.first.url, endsWith('/danmaku/sample.xml'));
      // 第二条没有 source 标记。
      expect(result.danmaku[1].name, '文本弹幕');
      expect(result.danmaku[1].source, isEmpty);
      // wss 源被识别为直播弹幕（本阶段不支持）。
      expect(result.danmaku[2].isLive, isTrue);
      expect(result.danmaku[3].isLive, isFalse);
    });

    test('展示名回退：name → source → 地址末段', () {
      expect(
        const DanmakuSource(url: 'http://h/a.xml', name: '名字').displayName,
        '名字',
      );
      expect(
        const DanmakuSource(url: 'http://h/a.xml', source: '来源').displayName,
        '来源',
      );
      expect(
        const DanmakuSource(url: 'http://h/a.xml').displayName,
        'a.xml',
      );
    });

    test('源类型判定与 Android DanmakuUrlPolicy 语义一致', () {
      expect(
        const DanmakuSource(url: 'http://h/a.xml').classify(),
        DanmakuSourceKind.staticFile,
      );
      expect(
        const DanmakuSource(url: 'https://h/a.xml').classify(),
        DanmakuSourceKind.staticFile,
      );
      expect(
        const DanmakuSource(url: 'file:///c:/a.xml').classify(),
        DanmakuSourceKind.staticFile,
      );
      expect(
        const DanmakuSource(url: r'D:\subs\a.xml').classify(),
        DanmakuSourceKind.staticFile,
      );
      expect(
        const DanmakuSource(url: 'wss://h/room').classify(),
        DanmakuSourceKind.live,
      );
      expect(
        const DanmakuSource(url: 'ws://h/room').classify(),
        DanmakuSourceKind.live,
      );
      expect(
        const DanmakuSource(url: 'ftp://h/a.xml').classify(),
        DanmakuSourceKind.unsupported,
      );
      expect(
        const DanmakuSource(url: 'http://').classify(),
        DanmakuSourceKind.unsupported,
      );
      expect(
        const DanmakuSource(url: '').classify(),
        DanmakuSourceKind.unsupported,
      );
    });

    test('宽松解析：字符串、信封、内嵌 JSON、去重、防深嵌套', () {
      // 纯字符串数组。
      final fromStrings = danmakuSourcesFromJson([
        'http://h/a.xml',
        'http://h/b.txt',
      ]);
      expect(fromStrings.map((s) => s.url), ['http://h/a.xml', 'http://h/b.txt']);

      // 信封形态（Android 的下钻键）。
      final fromEnvelope = danmakuSourcesFromJson({
        'data': {
          'list': [
            {'name': 'A', 'url': 'http://h/a.xml'},
          ],
        },
      });
      expect(fromEnvelope, hasLength(1));
      expect(fromEnvelope.first.name, 'A');

      // 内嵌 JSON 字符串。
      final fromEmbedded = danmakuSourcesFromJson(
        '[{"name":"内嵌","url":"http://h/e.xml"}]',
      );
      expect(fromEmbedded, hasLength(1));
      expect(fromEmbedded.first.name, '内嵌');

      // 按 url 去重且保序。
      final deduped = danmakuSourcesFromJson([
        'http://h/a.xml',
        {'name': '重复', 'url': 'http://h/a.xml'},
        'http://h/b.xml',
      ]);
      expect(deduped.map((s) => s.url), ['http://h/a.xml', 'http://h/b.xml']);
      expect(deduped.first.name, 'http://h/a.xml');

      // 缺 url / 非法输入的条目被丢弃，不抛异常。
      expect(danmakuSourcesFromJson([{'name': '无地址'}, 42, null]), isEmpty);
      expect(danmakuSourcesFromJson(null), isEmpty);
      // 畸形内嵌 JSON 不得炸掉整份结果。
      expect(danmakuSourcesFromJson('[not-json'), isEmpty);
      // 过深嵌套在 3 层后停止（不递归到栈溢出）。
      expect(
        danmakuSourcesFromJson({
          'data': {
            'data': {
              'data': {
                'data': {
                  'list': ['http://h/deep.xml'],
                },
              },
            },
          },
        }),
        isEmpty,
      );
    });

    test('格式嗅探：XML / 文本 / 无法识别', () {
      expect(sniffDanmakuFormat(readFixture('danmaku/sample.xml')), DanmakuFormat.xml);
      expect(sniffDanmakuFormat(readFixture('danmaku/sample.txt')), DanmakuFormat.text);
      expect(sniffDanmakuFormat('随便一段文字\n没有任何弹幕结构'), isNull);
      expect(sniffDanmakuFormat(''), isNull);
      // XML 声明行要被跳过，不能误判。
      expect(
        sniffDanmakuFormat('<?xml version="1.0"?>\n<i><d p="1,1,25,16777215">a</d></i>'),
        DanmakuFormat.xml,
      );
    });
  });

  group('Bilibili XML 解析（对齐 media3 BiliParser）', () {
    late DanmakuParseResult parsed;

    setUpAll(() {
      parsed = parseDanmakuContent(readFixture('danmaku/sample.xml'));
    });

    test('识别为 xml 并按时间排序', () {
      expect(parsed.format, 'xml');
      expect(parsed.items, hasLength(8));
      // 丢弃：mode=7 高级弹幕、参数不足、非法时间 → 3 条。
      expect(parsed.skipped, 3);
      final times = parsed.items.map((item) => item.timeMs).toList();
      expect(times, List.of(times)..sort());
    });

    test('类型映射与 media3 mapBiliMode 一致（1/2/3→滚动, 4→底部, 5→顶部, 6→反向）', () {
      final byText = {for (final item in parsed.items) item.text: item};
      expect(byText, hasLength(8));
      expect(byText['第一条滚动弹幕']!.type, DanmakuType.scroll);
      expect(byText['底部固定弹幕']!.type, DanmakuType.bottom);
      expect(byText['顶部固定弹幕']!.type, DanmakuType.top);
      expect(byText['反向滚动弹幕']!.type, DanmakuType.reverse);
      // mode=7 高级弹幕按 media3 语义丢弃。
      expect(byText.containsKey('高级弹幕应被丢弃'), isFalse);
    });

    test('字号档位与 media3 mapBiliTextSize 一致（<=18→12, >=36→18, 其余→默认）', () {
      final byText = {for (final item in parsed.items) item.text: item};
      expect(byText['小字号弹幕']!.textSizeSp, DanmakuItem.smallTextSizeSp);
      expect(byText['大字号弹幕']!.textSizeSp, DanmakuItem.largeTextSizeSp);
      expect(byText['第一条滚动弹幕']!.textSizeSp, DanmakuItem.defaultTextSizeSp);
    });

    test('时间秒→毫秒、颜色十进制、XML 实体解码', () {
      final byText = {for (final item in parsed.items) item.text: item};
      expect(byText['第一条滚动弹幕']!.timeMs, 500);
      expect(byText['红色滚动弹幕']!.timeMs, 1000);
      // 16711680 = 0xFF0000（红）。
      expect(byText['红色滚动弹幕']!.color, 0xFFFF0000);
      expect(byText['第一条滚动弹幕']!.color, 0xFFFFFFFF);
      // `&amp;`/`&lt;`/`&gt;` 必须被还原。
      expect(byText.containsKey('转义 & 实体 <测试>'), isTrue);
    });

    test('非法条目分别计数，不影响合法条目', () {
      expect(parsed.items.any((item) => item.text == '参数不足应被丢弃'), isFalse);
      expect(parsed.items.any((item) => item.text == '非法时间应被丢弃'), isFalse);
    });
  });

  group('行式文本解析（对齐 media3 TxtParser）', () {
    late DanmakuParseResult parsed;

    setUpAll(() {
      parsed = parseDanmakuContent(readFixture('danmaku/sample.txt'));
    });

    test('识别为 text，参数位置为 时间,模式,字号,颜色', () {
      expect(parsed.format, 'text');
      expect(parsed.items, hasLength(8));
      expect(parsed.skipped, 3);
      final byText = {for (final item in parsed.items) item.text: item};
      expect(byText['文本弹幕第一条']!.timeMs, 500);
      expect(byText['文本弹幕第一条']!.type, DanmakuType.scroll);
      expect(byText['底部文本弹幕']!.type, DanmakuType.bottom);
      expect(byText['顶部文本弹幕']!.type, DanmakuType.top);
      expect(byText['反向文本弹幕']!.type, DanmakuType.reverse);
      expect(byText['红色文本弹幕']!.color, 0xFFFF0000);
      expect(byText['小字号文本弹幕']!.textSizeSp, DanmakuItem.smallTextSizeSp);
      expect(byText['大字号文本弹幕']!.textSizeSp, DanmakuItem.largeTextSizeSp);
    });

    test('行正则与 media3 一致：参数不足/非法/无方括号均丢弃', () {
      expect(parseDanmakuTextLine('[1,1,25]参数不足'), isNull);
      expect(parseDanmakuTextLine('[x,1,25,16777215]非法时间'), isNull);
      expect(parseDanmakuTextLine('没有方括号'), isNull);
      expect(parseDanmakuTextLine('[1,7,25,16777215]高级弹幕'), isNull);
      expect(parseDanmakuTextLine('[1,1,25,16777215]'), isNull);
      // 合法行。
      final ok = parseDanmakuTextLine('[1.5,5,25,16711680]合法');
      expect(ok, isNotNull);
      expect(ok!.timeMs, 1500);
      expect(ok.type, DanmakuType.top);
      // 文本里的方括号不影响参数解析（正则只取第一段参数）。
      final nested = parseDanmakuTextLine('[1,1,25,16777215]带[方括号]的文本');
      expect(nested!.text, '带[方括号]的文本');
    });
  });

  group('DanmakuService 加载（Phase 3）', () {
    late TestFixtureServer server;
    late DanmakuService service;

    setUp(() async {
      server = await TestFixtureServer.start();
      service = DanmakuService();
    });

    tearDown(() async {
      service.close();
      await server.stop();
    });

    test('HTTP 拉取带 Header 的 XML 弹幕并解析', () async {
      final document = await service.load(
        DanmakuSource(url: '${server.baseUrl}/danmaku/sample.xml', name: '样例'),
        headers: fixtureMediaHeaders,
      );

      expect(document.format, 'xml');
      expect(document.items, hasLength(8));
      expect(document.skipped, 3);
      expect(document.byteLength, greaterThan(0));
      final request = server.captured.lastWhere(
        (item) => item.path.endsWith('sample.xml'),
      );
      expect(request.headers['referer'], 'http://127.0.0.1:18080/');
    });

    test('本地文件加载（含 Windows 盘符路径语义）', () async {
      final document = await service.load(
        DanmakuSource(url: fixturePath('danmaku/sample.txt')),
      );
      expect(document.format, 'text');
      expect(document.items, hasLength(8));
    });

    test('缺 Header 时上游 403 → danmakuHttp', () async {
      await expectLater(
        service.load(DanmakuSource(url: '${server.baseUrl}/danmaku/sample.xml')),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuHttp)
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });

    test('404 → danmakuHttp；缺失样本可定位', () async {
      await expectLater(
        service.load(
          DanmakuSource(url: '${server.baseUrl}/danmaku/nope.xml'),
          headers: fixtureMediaHeaders,
        ),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuHttp)
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('直播弹幕 ws/wss 明确不支持，不静默返回空列表', () async {
      await expectLater(
        service.load(const DanmakuSource(url: 'wss://h/room')),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuUnsupported),
        ),
      );
      await expectLater(
        service.load(const DanmakuSource(url: 'ws://h/room')),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuUnsupported),
        ),
      );
    });

    test('无法识别的内容 → danmakuInvalid（不空列表化）', () async {
      final temp = await Directory.systemTemp.createTemp('webhtv-danmaku-bad');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'bad.xml'));
      await file.writeAsString('这是一段既不是 XML 也不是行式的文本');

      await expectLater(
        service.load(DanmakuSource(url: file.path)),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuInvalid),
        ),
      );
    });

    test('能识别格式但无可用条目 → danmakuEmpty', () async {
      final temp = await Directory.systemTemp.createTemp('webhtv-danmaku-empty');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'only-bad.xml'));
      // 全是 mode=7（不支持）。
      await file.writeAsString(
        '<i><d p="1,7,25,16777215">高级</d><d p="2,7,25,16777215">高级2</d></i>',
      );

      await expectLater(
        service.load(DanmakuSource(url: file.path)),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuEmpty),
        ),
      );
    });

    test('空文件 → danmakuEmpty', () async {
      final temp = await Directory.systemTemp.createTemp('webhtv-danmaku-blank');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'blank.xml'));
      await file.writeAsBytes(const []);

      await expectLater(
        service.load(DanmakuSource(url: file.path)),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuEmpty),
        ),
      );
    });

    test('GBK 弹幕按 GBK 兜底解码，中文不乱码', () async {
      final gbkBytes = gbk.encode('[1,1,25,16777215]中文字幕弹幕测试');
      final temp = await Directory.systemTemp.createTemp('webhtv-danmaku-gbk');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'gbk.txt'));
      await file.writeAsBytes(gbkBytes);

      final document = await service.load(DanmakuSource(url: file.path));
      expect(document.items.single.text, '中文字幕弹幕测试');
      expect(document.encoding, 'gbk');
    });

    test('超过大小上限 → danmakuTooLarge', () async {
      final temp = await Directory.systemTemp.createTemp('webhtv-danmaku-big');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'big.txt'));
      await file.writeAsBytes(List<int>.filled(4096, 0x41));

      final small = DanmakuService(maxBytes: 1024);
      addTearDown(small.close);
      await expectLater(
        small.load(DanmakuSource(url: file.path)),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuTooLarge),
        ),
      );
    });

    test('文件不存在 → danmakuNetwork；协议不支持 → danmakuUnsupported', () async {
      await expectLater(
        service.load(
          DanmakuSource(
            url: p.join(
              Directory.systemTemp.path,
              'nope-${DateTime.now().microsecondsSinceEpoch}.xml',
            ),
          ),
        ),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuNetwork),
        ),
      );
      await expectLater(
        service.load(const DanmakuSource(url: 'ftp://h/a.xml')),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.danmakuUnsupported),
        ),
      );
    });

    test('缓存命中：同地址第二次不重复请求', () async {
      final source = DanmakuSource(url: '${server.baseUrl}/danmaku/sample.txt');
      await service.load(source, headers: fixtureMediaHeaders);
      final afterFirst = server.captured
          .where((item) => item.path.endsWith('sample.txt'))
          .length;
      await service.load(source, headers: fixtureMediaHeaders);
      final afterSecond = server.captured
          .where((item) => item.path.endsWith('sample.txt'))
          .length;
      expect(afterSecond, afterFirst, reason: '缓存命中不应再次发请求');

      // useCache=false 必须绕过缓存。
      await service.load(source, headers: fixtureMediaHeaders, useCache: false);
      expect(
        server.captured.where((item) => item.path.endsWith('sample.txt')).length,
        afterSecond + 1,
      );
    });
  });

  group('弹幕轨道布局（Phase 3 渲染）', () {
    DanmakuItem item(
      int ms,
      String text, {
      DanmakuType type = DanmakuType.scroll,
    }) => DanmakuItem(timeMs: ms, text: text, type: type);

    test('可见性窗口：滚动 8s、固定 4s，区间外不可见', () {
      final scroll = item(1000, '滚动');
      expect(
        DanmakuTrackAllocator.visibilityAt(item: scroll, positionMs: 500).visible,
        isFalse,
      );
      expect(
        DanmakuTrackAllocator.visibilityAt(item: scroll, positionMs: 1000).visible,
        isTrue,
      );
      expect(
        DanmakuTrackAllocator.visibilityAt(item: scroll, positionMs: 9000).visible,
        isTrue,
      );
      expect(
        DanmakuTrackAllocator.visibilityAt(item: scroll, positionMs: 9001).visible,
        isFalse,
      );

      final top = item(1000, '顶部', type: DanmakuType.top);
      expect(
        DanmakuTrackAllocator.visibilityAt(item: top, positionMs: 5001).visible,
        isFalse,
      );
      expect(
        DanmakuTrackAllocator.visibilityAt(item: top, positionMs: 5000).visible,
        isTrue,
      );
    });

    test('关闭弹幕时可见集合为空（这就是“可开启和关闭”）', () {
      final items = [item(0, '弹幕A'), item(500, '弹幕B')];
      expect(
        DanmakuTrackAllocator.visibleAt(
          items: items,
          positionMs: 1000,
          enabled: false,
        ),
        isEmpty,
      );
      expect(
        DanmakuTrackAllocator.visibleAt(
          items: items,
          positionMs: 1000,
          enabled: true,
        ),
        isNotEmpty,
      );
    });

    test('轨道分配：滚动弹幕不超出上限轨道，且同一时刻的多条占用不同轨道', () {
      // 10 条同时出现的滚动弹幕，画面只够有限轨道。
      final items = [
        for (var index = 0; index < 10; index++)
          item(0, '同时出现的第 $index 条弹幕'),
      ];
      final visible = DanmakuTrackAllocator.visibleAt(
        items: items,
        positionMs: 100,
        enabled: true,
        width: 1280,
        height: 720,
        trackHeight: 28,
      );
      final allocator = DanmakuTrackAllocator(
        width: 1280,
        height: 720,
        trackHeight: 28,
      );
      expect(visible.length, lessThanOrEqualTo(allocator.scrollTrackCount));
      // 同一时刻的弹幕不得重叠在同一轨道。
      final tracks = visible.map((v) => v.track).toList();
      expect(tracks.toSet().length, tracks.length);
    });

    test('顶部/底部各自独立分轨道且互不抢占', () {
      final items = [
        item(0, '顶部1', type: DanmakuType.top),
        item(0, '顶部2', type: DanmakuType.top),
        item(0, '底部1', type: DanmakuType.bottom),
        item(0, '底部2', type: DanmakuType.bottom),
      ];
      final visible = DanmakuTrackAllocator.visibleAt(
        items: items,
        positionMs: 100,
        enabled: true,
      );
      expect(visible, hasLength(4));
      final tops = visible
          .where((v) => v.item.type == DanmakuType.top)
          .map((v) => v.track)
          .toList();
      final bottoms = visible
          .where((v) => v.item.type == DanmakuType.bottom)
          .map((v) => v.track)
          .toList();
      expect(tops.toSet().length, tops.length);
      expect(bottoms.toSet().length, bottoms.length);
      // 顶部与底部轨道编号可以相同（它们分居上下两侧）。
      expect(tops, isNotEmpty);
    });

    test('宽度估算遵循全角:半角 = 2:1（东亚宽度约定）', () {
      // 1 个汉字 ≈ 2 个 ASCII 字形的推进宽度，这是排版上的通用约定；
      // 若半角比例被调成 0.55 之类的值，这个等式立刻不成立（本用例即锁定点）。
      expect(
        VisibleDanmaku.estimateWidth('中', 16),
        closeTo(VisibleDanmaku.estimateWidth('ab', 16), 1e-9),
      );
      expect(
        VisibleDanmaku.estimateWidth('中文字幕', 16),
        closeTo(VisibleDanmaku.estimateWidth('abcdefgh', 16), 1e-9),
      );
      // 同字数下全角严格更宽。
      expect(
        VisibleDanmaku.estimateWidth('中文字幕', 16),
        greaterThan(VisibleDanmaku.estimateWidth('abcdef', 16)),
      );
      expect(VisibleDanmaku.estimateWidth('', 16), 0);
    });
  });

  group('弹幕失败隔离（§10.4 同语义）', () {
    test('弹幕错误分类可识别，播放错误不受影响', () {
      expect(
        isDanmakuError(AppError(AppErrorKind.danmakuHttp, 'HTTP 403')),
        isTrue,
      );
      expect(
        isDanmakuError(AppError(AppErrorKind.danmakuUnsupported, 'ws 不支持')),
        isTrue,
      );
      expect(
        isDanmakuError(AppError(AppErrorKind.playbackUrlMissing, '缺地址')),
        isFalse,
      );
      expect(isDanmakuError(StateError('boom')), isFalse);
    });

    test('提示文案明确说明不影响视频播放', () {
      final fromKind = describeDanmakuFailure(
        AppError(AppErrorKind.danmakuNetwork, '下载失败'),
      );
      expect(fromKind, contains('弹幕加载失败'));
      expect(fromKind, contains('不影响视频播放'));

      final plain = describeDanmakuFailure(StateError('boom'));
      expect(plain, contains('不影响视频播放'));
    });
  });
}
