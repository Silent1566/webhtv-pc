/// 外挂字幕测试（设计文档 §10.3「字幕轨选择」「外挂字幕」、§13.3「字幕可开启和关闭」）。
///
/// 覆盖四层：
/// 1. 模型：`Result.subs` → `SubtitleInfo` 的解析与往返、`flag` 位语义；
/// 2. 纯逻辑：格式推断、候选构建、菜单顺序、默认/强制字幕选择、切集后的沿用；
/// 3. 加载服务：HTTP（带 Header）/本地文件/GBK 兜底/大小上限/各类错误归一化；
/// 4. 失败隔离：字幕错误只提示，不得升级为播放失败（§10.4）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/subtitle.dart';
import 'package:webhtv_pc/services/subtitle_service.dart';

import 'fixture_support.dart';
import 'support/test_fixture_server.dart';

/// 解析一份 fixture 播放结果（与产品同一条 `HttpApiResponseParser` 链路）。
SiteResult parsePlayResult(String fixture) => HttpApiResponseParser.parse(
  readFixture(fixture),
  siteKey: 'fixture-type1',
);

void main() {
  group('字幕模型（§10.3）', () {
    test('从播放结果解析 subs，字段与 WebHTV `Sub` 对齐', () {
      final result = parsePlayResult('http/play-with-subs.json');

      // fixture 含 3 条：缺地址的那条在解析阶段就丢弃（不进入候选）。
      expect(result.subs, hasLength(2));
      final first = result.subs.first;
      expect(first.url, endsWith('/media/sample.srt'));
      expect(first.name, '简体中文');
      expect(first.lang, 'zh');
      expect(first.format, 'srt');
      expect(first.flag, 1);
      expect(first.isDefault, isTrue);
      expect(first.isForced, isFalse);
    });

    test('flag 位语义：0 视为默认，forced/autoselect 按位判定', () {
      expect(const SubtitleInfo(url: 'a.srt').effectiveFlag, 1);
      expect(const SubtitleInfo(url: 'a.srt').isDefault, isTrue);
      expect(const SubtitleInfo(url: 'a.srt', flag: 2).isForced, isTrue);
      expect(const SubtitleInfo(url: 'a.srt', flag: 2).isDefault, isFalse);
      expect(const SubtitleInfo(url: 'a.srt', flag: 4).isAutoSelect, isTrue);
      expect(const SubtitleInfo(url: 'a.srt', flag: 1).isForced, isFalse);
    });

    test('往返不失真；缺 url 的条目丢弃', () {
      const sub = SubtitleInfo(
        url: 'http://h/a.ass',
        name: '简中',
        lang: 'zh',
        format: 'ass',
        flag: 3,
      );
      final restored = SubtitleInfo.fromJson(sub.toJson());
      expect(restored, sub);
      expect(restored!.isDefault, isTrue);
      expect(restored.isForced, isTrue);

      final list = SubtitleInfo.listFromJson([
        sub.toJson(),
        {'name': '无地址'},
        'not-a-map',
      ]);
      expect(list, hasLength(1));
    });

    test('展示名回退：name → lang → 地址末段', () {
      expect(const SubtitleInfo(url: 'http://h/a.srt', name: '简中').displayName, '简中');
      expect(const SubtitleInfo(url: 'http://h/a.srt', lang: 'en').displayName, 'en');
      expect(const SubtitleInfo(url: 'http://h/b.srt').displayName, 'b.srt');
    });

    test('缺 subs 字段时为空列表，不报错（§8.4 不把缺失当错误）', () {
      final result = parsePlayResult('http/play.json');
      expect(result.subs, isEmpty);
    });
  });

  group('播放决策携带字幕（§10.3）', () {
    test('PlaybackDecision 透传 subs 并给出附加资源 Header', () {
      const subs = [SubtitleInfo(url: 'http://h/a.srt', flag: 1)];
      final upstream = HeaderMap({'Referer': 'http://h/'});
      final decision = PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'http://h/v.m3u8',
        headers: HeaderMap(),
        subs: subs,
        upstreamHeaders: upstream,
      );

      expect(decision.subs, subs);
      // 代理场景：媒体 Header 被清空，字幕必须仍能拿到代理前的 Header。
      expect(decision.assetHeaders?['Referer'], 'http://h/');
      expect(decision.logLine, contains('subs=1'));
    });
  });

  group('字幕格式推断（§10.3）', () {
    test('按扩展名识别，忽略 query 与 fragment', () {
      expect(inferSubtitleFormat('http://h/a.srt'), 'srt');
      expect(inferSubtitleFormat('http://h/a.SRT'), 'srt');
      expect(inferSubtitleFormat('http://h/a.ass?token=1'), 'ass');
      expect(inferSubtitleFormat('http://h/a.ssa#x'), 'ssa');
      expect(inferSubtitleFormat('http://h/a.vtt'), 'vtt');
      expect(inferSubtitleFormat('http://h/a.sub'), 'sub');
      expect(inferSubtitleFormat(r'D:\subs\a.srt'), 'srt');
    });

    test('无扩展名时用声明值兜底，无法判定返回空串', () {
      expect(inferSubtitleFormat('http://h/sub', declared: 'application/x-subrip'), 'srt');
      expect(inferSubtitleFormat('http://h/sub', declared: 'text/x-ssa'), 'ssa');
      expect(inferSubtitleFormat('http://h/sub', declared: 'text/vtt'), 'vtt');
      expect(inferSubtitleFormat('http://h/sub'), '');
      expect(inferSubtitleFormat('http://h/a.exe'), '');
      expect(inferSubtitleFormat('http://h/a.mp4'), '');
    });

    test('MIME 映射与设计文档列举的格式一致', () {
      expect(subtitleMimeType('a.srt'), 'application/x-subrip');
      expect(subtitleMimeType('a.ass'), 'text/x-ssa');
      expect(subtitleMimeType('a.vtt'), 'text/vtt');
      expect(subtitleMimeType('a.sub'), 'text/x-microdvd');
      expect(subtitleMimeType('a.mp4'), '');
    });
  });

  group('字幕候选与选择（§10.3）', () {
    test('外挂候选丢弃缺地址/格式不支持的条目并上报原因', () {
      final discarded = <String>[];
      final options = externalSubtitleOptions(
        const [
          SubtitleInfo(url: 'http://h/a.srt', name: '可用', flag: 1),
          SubtitleInfo(url: '', name: '无地址'),
          SubtitleInfo(url: 'http://h/b.mp4', name: '非字幕'),
          SubtitleInfo(url: 'http://h/sub', name: '无扩展名'),
        ],
        onDiscard: (sub, reason) => discarded.add('${sub.name}:$reason'),
      );

      expect(options.map((option) => option.label), ['可用']);
      expect(options.first.id, 'external:0');
      expect(options.first.format, 'srt');
      expect(discarded, hasLength(3));
      expect(discarded.first, contains('无地址'));
      expect(discarded[1], contains('非字幕'));
    });

    test('外挂条目标签带语言，flag 位映射到 forced/default', () {
      final options = externalSubtitleOptions(
        const [
          SubtitleInfo(url: 'http://h/a.ass', name: '简体', lang: 'zh', flag: 2),
        ],
      );
      expect(options.first.label, '简体（zh）');
      expect(options.first.isForced, isTrue);
      expect(options.first.isDefault, isFalse);
    });

    test('内嵌候选过滤 auto/no 伪轨（media-kit 固定携带）', () {
      final options = embeddedSubtitleOptions(const [
        (id: 'auto', title: '', language: '', isDefault: false),
        (id: 'no', title: '', language: '', isDefault: false),
        (id: '2', title: '中文', language: 'zh', isDefault: true),
        (id: '3', title: '', language: 'en', isDefault: false),
      ]);

      expect(options.map((option) => option.id), ['embedded:2', 'embedded:3']);
      expect(options.first.label, '中文（zh）');
      expect(options.first.isDefault, isTrue);
      expect(options[1].label, 'en');
    });

    test('菜单顺序为 外挂 → 内嵌 → 关闭，并去重', () {
      final menu = subtitleMenu(
        externalSubtitleOptions(const [SubtitleInfo(url: 'http://h/a.srt', name: '外挂')]),
        embeddedSubtitleOptions(const [
          (id: '2', title: '内嵌中文', language: 'zh', isDefault: false),
        ]),
      );

      expect(menu.map((option) => option.id), [
        'external:0',
        'embedded:2',
        SubtitleOption.offId,
      ]);
      expect(menu.last.label, '关闭字幕');

      // 同一批候选重复传入时不得出现重复条目。
      final deduped = subtitleMenu(
        externalSubtitleOptions(const [SubtitleInfo(url: 'http://h/a.srt', name: '外挂')]),
        externalSubtitleOptions(const [SubtitleInfo(url: 'http://h/a.srt', name: '外挂')]),
        includeOff: false,
      );
      expect(deduped, hasLength(1));
    });

    test('默认选择优先级：外挂 default → 内嵌 default → forced → 不自动开', () {
      final externalDefault = SubtitleOption(
        id: 'external:0',
        label: '外挂默认',
        kind: SubtitleSourceKind.external,
        isDefault: true,
      );
      final embeddedDefault = SubtitleOption(
        id: 'embedded:2',
        label: '内嵌默认',
        kind: SubtitleSourceKind.embedded,
        isDefault: true,
      );
      final forced = SubtitleOption(
        id: 'embedded:3',
        label: '强制',
        kind: SubtitleSourceKind.embedded,
        isForced: true,
      );

      expect(
        defaultSubtitleOption([forced, embeddedDefault, externalDefault])?.id,
        'external:0',
      );
      expect(defaultSubtitleOption([forced, embeddedDefault])?.id, 'embedded:2');
      expect(defaultSubtitleOption([forced])?.id, 'embedded:3');
      // 都不是默认/强制 → 不自动开字幕，避免给无需字幕的用户添噪。
      expect(
        defaultSubtitleOption([
          SubtitleOption(
            id: 'external:0',
            label: '普通外挂',
            kind: SubtitleSourceKind.external,
          ),
        ]),
        isNull,
      );
    });

    test('切集后：关闭保持关闭、内嵌按语言沿用、外挂回退默认', () {
      final off = SubtitleOption.off;
      expect(resolveSelectionAfterSwitch(previous: off, options: const []), off);

      final zhEmbedded = SubtitleOption(
        id: 'embedded:2',
        label: '中文',
        kind: SubtitleSourceKind.embedded,
        language: 'zh',
      );
      final nextEpisodeEmbedded = SubtitleOption(
        id: 'embedded:7',
        label: '中文',
        kind: SubtitleSourceKind.embedded,
        language: 'zh',
      );
      expect(
        resolveSelectionAfterSwitch(
          previous: zhEmbedded,
          options: [nextEpisodeEmbedded],
        )?.id,
        'embedded:7',
      );

      final external = SubtitleOption(
        id: 'external:0',
        label: '外挂',
        kind: SubtitleSourceKind.external,
        url: 'http://h/a.srt',
      );
      final nextDefault = SubtitleOption(
        id: 'external:1',
        label: '下一集外挂默认',
        kind: SubtitleSourceKind.external,
        isDefault: true,
      );
      // 外挂字幕地址随集数变化，不能沿用上一集的选择。
      expect(
        resolveSelectionAfterSwitch(previous: external, options: [nextDefault])?.id,
        'external:1',
      );
    });
  });

  group('SubtitleService 加载（§10.3）', () {
    late TestFixtureServer server;
    late SubtitleService service;

    setUp(() async {
      server = await TestFixtureServer.start();
      service = SubtitleService();
    });

    tearDown(() async {
      service.close();
      await server.stop();
    });

    test('HTTP 拉取带 Header 的字幕并解码中文', () async {
      final document = await service.load(
        SubtitleInfo(url: '${server.baseUrl}/media/sample.srt', name: '简中'),
        headers: fixtureMediaHeaders,
      );

      expect(document.format, 'srt');
      expect(document.text, contains('WebHTV PC 外挂字幕 fixture'));
      expect(document.text, contains('第二行：字幕加载成功'));
      expect(document.byteLength, greaterThan(0));
      // Header 确实带上了（fixture 服务对 /media/ 有 Referer/UA 门禁）。
      final request = server.captured.lastWhere(
        (item) => item.path.endsWith('sample.srt'),
      );
      expect(request.headers['referer'], 'http://127.0.0.1:18080/');
      expect(request.headers['user-agent'], isNotNull);
    });

    test('缺 Header 时上游 403 → subtitleHttp（且不是播放失败）', () async {
      await expectLater(
        service.load(
          SubtitleInfo(url: '${server.baseUrl}/media/sample.srt'),
          // 故意不带 Header：媒体门禁必须同样作用于字幕。
        ),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.subtitleHttp)
              .having((error) => error.statusCode, 'statusCode', 403),
        ),
      );
    });

    test('404 → subtitleHttp', () async {
      await expectLater(
        service.load(
          SubtitleInfo(url: '${server.baseUrl}/media/nope.srt'),
          headers: fixtureMediaHeaders,
        ),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.subtitleHttp)
              .having((error) => error.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('本地文件加载（含 Windows 盘符路径语义）', () async {
      final document = await service.load(
        SubtitleInfo(url: fixturePath('media/sample.srt')),
      );
      expect(document.text, contains('第三行'));
      expect(document.format, 'srt');
    });

    test('GBK 字幕按 GBK 兜底解码，中文不乱码', () async {
      final gbkBytes = gbk.encode('1\n00:00:00,000 --> 00:00:01,000\n中文字幕测试\n');
      final temp = await Directory.systemTemp.createTemp('webhtv-srt-gbk');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'gbk.srt'));
      await file.writeAsBytes(gbkBytes);

      final document = await service.load(SubtitleInfo(url: file.path));
      expect(document.text, contains('中文字幕测试'));
      expect(document.encoding, 'gbk');
    });

    test('超过大小上限 → subtitleTooLarge，不读满内存', () async {
      final temp = await Directory.systemTemp.createTemp('webhtv-srt-big');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'big.srt'));
      await file.writeAsBytes(Uint8List(4096));

      final small = SubtitleService(maxBytes: 1024);
      addTearDown(small.close);
      await expectLater(
        small.load(SubtitleInfo(url: file.path)),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.subtitleTooLarge),
        ),
      );
    });

    test('空内容 → subtitleEmpty', () async {
      final temp = await Directory.systemTemp.createTemp('webhtv-srt-empty');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File(p.join(temp.path, 'empty.srt'));
      await file.writeAsBytes(const []);

      await expectLater(
        service.load(SubtitleInfo(url: file.path)),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.subtitleEmpty),
        ),
      );
    });

    test('不支持的协议与格式 → subtitleUnsupported', () async {
      await expectLater(
        service.load(const SubtitleInfo(url: 'ftp://h/a.srt')),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.subtitleUnsupported),
        ),
      );
      await expectLater(
        service.load(const SubtitleInfo(url: 'http://h/a.mp4')),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.subtitleUnsupported),
        ),
      );
      await expectLater(
        service.load(const SubtitleInfo(url: '')),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.subtitleUnsupported),
        ),
      );
    });

    test('文件不存在 → subtitleNetwork（可定位，不抛未捕获异常）', () async {
      await expectLater(
        service.load(SubtitleInfo(url: p.join(Directory.systemTemp.path, 'nope-${DateTime.now().microsecondsSinceEpoch}.srt'))),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.subtitleNetwork),
        ),
      );
    });
  });

  group('字幕失败隔离（§10.4、§13.3）', () {
    test('字幕错误分类可识别，播放错误不受影响', () {
      expect(
        isSubtitleError(
          AppError(AppErrorKind.subtitleHttp, '字幕下载返回 HTTP 403'),
        ),
        isTrue,
      );
      expect(
        isSubtitleError(AppError(AppErrorKind.playbackUrlMissing, '缺地址')),
        isFalse,
      );
      expect(isSubtitleError(StateError('boom')), isFalse);
    });

    test('提示文案明确说明不影响视频播放', () {
      final message = describeSubtitleFailure(
        AppError(AppErrorKind.subtitleNetwork, '字幕下载失败'),
      );
      expect(message, contains('字幕加载失败'));
      expect(message, contains('不影响视频播放'));

      final plain = describeSubtitleFailure(StateError('boom'));
      expect(plain, contains('不影响视频播放'));
    });
  });
}
