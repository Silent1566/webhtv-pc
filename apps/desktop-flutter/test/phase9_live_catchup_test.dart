import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/live_catchup.dart';
import 'package:webhtv_pc/core/live_settings.dart';
import 'package:webhtv_pc/core/live_playlist.dart';

void main() {
  group('P0-8 catchup 模板（design/03 §2）', () {
    const append = CatchupSpec(
      type: 'append',
      days: '7',
      source: '?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}',
    );

    test('append：拼接查询串，已有 query 时用 &', () {
      final url = formatCatchupUrl(
        spec: append,
        channelUrl: 'http://example.test/live/1.m3u8',
        startMs: DateTime(2026, 10, 21, 20).millisecondsSinceEpoch,
        endMs: DateTime(2026, 10, 21, 21).millisecondsSinceEpoch,
      );
      expect(
        url,
        'http://example.test/live/1.m3u8'
        '?playseek=20261021200000-20261021210000',
      );

      final withQuery = formatCatchupUrl(
        spec: append,
        channelUrl: 'http://example.test/live/1.m3u8?token=abc',
        startMs: DateTime(2026, 10, 21, 20).millisecondsSinceEpoch,
        endMs: DateTime(2026, 10, 21, 21).millisecondsSinceEpoch,
      );
      expect(
        withQuery,
        'http://example.test/live/1.m3u8?token=abc'
        '&playseek=20261021200000-20261021210000',
      );
    });

    test('append + replace：先做正则替换', () {
      const spec = CatchupSpec(
        type: 'append',
        replace: '/PLTV/,/TVOD/',
        source: '?start=\${utc:}&end=\${utcend:}',
      );
      final start = DateTime(2026, 10, 21, 20).millisecondsSinceEpoch;
      final end = DateTime(2026, 10, 21, 21).millisecondsSinceEpoch;
      final url = formatCatchupUrl(
        spec: spec,
        channelUrl: 'http://example.test/PLTV/1/index.m3u8',
        startMs: start,
        endMs: end,
      );
      expect(
        url,
        'http://example.test/TVOD/1/index.m3u8'
        '?start=${start ~/ 1000}&end=${end ~/ 1000}',
      );
    });

    test('default：source 即完整地址，不拼频道地址', () {
      const spec = CatchupSpec(
        type: 'default',
        source: 'http://cdn.test/timeshift/\${(b)yyyyMMdd}/\${(e)HH}.m3u8',
      );
      final url = formatCatchupUrl(
        spec: spec,
        channelUrl: 'http://example.test/live/1.m3u8',
        startMs: DateTime(2026, 10, 21, 20).millisecondsSinceEpoch,
        endMs: DateTime(2026, 10, 21, 21).millisecondsSinceEpoch,
      );
      expect(url, 'http://cdn.test/timeshift/20261021/21.m3u8');
    });

    test('非法输入返回 null（不生成坏地址）', () {
      expect(
        formatCatchupUrl(
          spec: CatchupSpec.none,
          channelUrl: 'http://example.test/1.m3u8',
          startMs: 1,
          endMs: 2,
        ),
        isNull,
      );
      expect(
        formatCatchupUrl(
          spec: append,
          channelUrl: '',
          startMs: 1,
          endMs: 2,
        ),
        isNull,
      );
      // 结束不晚于开始。
      expect(
        formatCatchupUrl(
          spec: append,
          channelUrl: 'http://example.test/1.m3u8',
          startMs: 2,
          endMs: 2,
        ),
        isNull,
      );
      // 未知模板片段。
      expect(
        formatCatchupUrl(
          spec: const CatchupSpec(
            type: 'append',
            source: '?x=\${(x)yyyy}',
          ),
          channelUrl: 'http://example.test/1.m3u8',
          startMs: 1,
          endMs: 2,
        ),
        isNull,
      );
      // 非法 replace 正则。
      expect(
        formatCatchupUrl(
          spec: const CatchupSpec(
            type: 'append',
            replace: '[unclosed,to',
            source: '?a=1',
          ),
          channelUrl: 'http://example.test/1.m3u8',
          startMs: 1,
          endMs: 2,
        ),
        isNull,
      );
    });

    test('timestamp 模板', () {
      final url = formatCatchupUrl(
        spec: const CatchupSpec(
          type: 'append',
          source: '?t=\${(b)timestamp}',
        ),
        channelUrl: 'http://example.test/1.m3u8',
        startMs: 1700000000000,
        endMs: 1700003600000,
      );
      expect(url, 'http://example.test/1.m3u8?t=1700000000');
    });
  });

  group('P0-8 解析器接入（M3U / JSON）', () {
    test('M3U 的 catchup 属性进入频道模型', () {
      final playlist = parseLivePlaylist('src', '''
#EXTM3U
#EXTINF:-1 tvg-id="cctv1" group-title="央视" catchup="append" catchup-source="?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}" catchup-replace="/PLTV/,/TVOD/" timeshift="7",CCTV1
http://example.test/PLTV/1/index.m3u8
''');
      final channel = playlist.allChannels.single;
      expect(channel.catchup.isEmpty, isFalse);
      expect(channel.catchup.type, 'append');
      expect(channel.catchup.days, '7');
      expect(channel.catchup.replace, '/PLTV/,/TVOD/');
      expect(channel.catchup.source, contains(r'${(b)'));
    });

    test('M3U 只有 catchup-source 也接受', () {
      final playlist = parseLivePlaylist('src', '''
#EXTM3U
#EXTINF:-1 group-title="g" catchup-source="?start=\${utc:}",C1
http://example.test/1.m3u8
''');
      expect(playlist.allChannels.single.catchup.source, '?start=\${utc:}');
    });

    test('JSON 嵌套/扁平两种 catchup 写法', () {
      final playlist = parseLivePlaylist('src', '''
{"groups":[{"name":"g","channel":[
  {"name":"nested","urls":["http://example.test/1.m3u8"],"catchup":{"type":"append","source":"?a=1"}},
  {"name":"flat","urls":["http://example.test/2.m3u8"],"catchupSource":"?b=2","catchupType":"append"}
]}]}
''');
      final channels = playlist.allChannels;
      expect(channels.firstWhere((c) => c.name == 'nested').catchup.source, '?a=1');
      expect(channels.firstWhere((c) => c.name == 'flat').catchup.source, '?b=2');
    });

    test('没有 catchup 的频道保持空，不伪造入口', () {
      final playlist = parseLivePlaylist('src', '''
#EXTM3U
#EXTINF:-1 group-title="g",C1
http://example.test/1.m3u8
''');
      expect(playlist.allChannels.single.catchup.isEmpty, isTrue);
    });
  });

  group('P0-8 直播设置（design/03 §5）', () {
    test('默认值等价现状', () {
      const settings = LiveSettings.defaults();
      expect(settings.sourceFallback, isTrue);
      expect(settings.changeLine, isTrue);
    });

    test('宽松解析与序列化', () {
      final parsed = LiveSettings.fromJson({
        'sourceFallback': false,
        'changeLine': 'nope',
      });
      expect(parsed.sourceFallback, isFalse);
      expect(parsed.changeLine, isTrue);
      expect(parsed.toJson()['sourceFallback'], isFalse);
    });
  });
}
