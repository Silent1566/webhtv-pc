import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';

void main() {
  const vod = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10.000000,
seg-1.ts
#EXTINF:6.500000,
seg-2.ts
#EXTINF:10.000000,
seg-3.ts
#EXT-X-ENDLIST
''';

  const live = '''
#EXTM3U
#EXT-X-VERSION:9
#EXT-X-TARGETDURATION:4
#EXT-X-DISCONTINUITY-SEQUENCE:7
#EXT-X-MAP:URI="init.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="k.bin"
#EXT-X-BYTERANGE:737280@0
#EXTINF:4.000000,
seg-1.m4s
#EXT-X-DISCONTINUITY
#EXT-X-PART:DURATION=0.500000,URI="part-1.m4s"
#EXTINF:4.000000,
seg-2.m4s
''';

  const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=1280x720
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080
1080/index.m3u8
''';

  group('点播清单', () {
    test('段数与 Σ EXTINF 就是引擎本该上报的总时长', () {
      final shape = HlsPlaylistShape.parse(vod);
      expect(shape.segments, 3);
      expect(shape.totalSeconds, 26.5);
      expect(shape.hasEndList, isTrue);
      expect(shape.playlistType, 'VOD');
      expect(shape.isMaster, isFalse);
      expect(shape.hasByteRange, isFalse);
      expect(shape.hasParts, isFalse);
    });

    test('summary 是一行可 grep 的 key=value（日志格式即契约）', () {
      expect(
        HlsPlaylistShape.parse(vod).summary,
        'segments=3 extinfSum=26.5s endlist=yes type=VOD master=no '
        'byrange=no parts=no map=no key=no disc=0',
      );
    });
  });

  group('直播 / 低延迟清单', () {
    test('没有 ENDLIST 的清单不是完整点播', () {
      final shape = HlsPlaylistShape.parse(live);
      expect(shape.hasEndList, isFalse);
      expect(shape.playlistType, isNull);
      expect(shape.segments, 2);
      expect(shape.hasByteRange, isTrue);
      expect(shape.hasParts, isTrue);
      expect(shape.hasMap, isTrue);
      expect(shape.hasKey, isTrue);
    });

    test('DISCONTINUITY-SEQUENCE 不算断点', () {
      // 清单里同时有 SEQUENCE(7) 与一个真正的 DISCONTINUITY → 只数后者。
      expect(HlsPlaylistShape.parse(live).discontinuities, 1);
    });
  });

  group('主清单', () {
    test('主清单没有分片，时长要问子清单', () {
      final shape = HlsPlaylistShape.parse(master);
      expect(shape.isMaster, isTrue);
      expect(shape.segments, 0);
      expect(shape.totalSeconds, 0.0);
    });
  });

  test('空清单与错误页文本不抛异常', () {
    final empty = HlsPlaylistShape.parse('');
    expect(empty.segments, 0);
    expect(empty.hasEndList, isFalse);
    expect(empty.summary, contains('endlist=no'));
    expect(HlsPlaylistShape.parse('<html>502 Bad Gateway</html>').segments, 0);
  });

  group('接线锁：形状日志真的接在重写路径上', () {
    test('代理每次重写清单都会记一行形状', () {
      final source = File('lib/services/proxy_server.dart').readAsStringSync();
      expect(source, contains('_logPlaylistShape('));
      expect(source, contains('HlsPlaylistShape.parse(cleaned.text)'));
    });

    test('播放页会记引擎时长的变化与越界时刻', () {
      final source = File('lib/ui/player_page.dart').readAsStringSync();
      expect(source, contains('_logEngineDurationDrift();'));
      expect(source, contains('已播超过引擎总长'));
    });
  });
}
