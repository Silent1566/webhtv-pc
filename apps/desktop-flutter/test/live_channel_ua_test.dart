import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/live_playlist.dart';
import 'package:webhtv_pc/ui/live_page.dart';

/// M3U/JSON 直播源里声明的 UA（`#EXTINF http-user-agent` / JSON `ua`）必须落成
/// 请求头：播放时取的是 `channel.header`，只留在 `extra['ua']` 里等于丢失。
void main() {
  group('直播源声明的 UA → 请求头', () {
    test('M3U：#EXTINF 的 http-user-agent 变成 User-Agent 请求头', () {
      final playlist = parseLivePlaylist('live.m3u', '''
#EXTM3U
#EXTINF:-1 tvg-name="CCTV1" http-user-agent="FooUA",CCTV1
http://h/a.m3u8
''');
      final channel = playlist.allChannels.single;
      expect(channel.header.asRequestHeaders['User-Agent'], 'FooUA');
      // HeaderMap 大小写不敏感，读键口径不受影响。
      expect(channel.header['user-agent'], 'FooUA');
      // extras 里的声明保留（其它代码将来可能用到）。
      expect(channel.extra['ua'], 'FooUA');
      // tvgName 行为不变（EPG 补全依赖它）。
      expect(channel.extra['tvgName'], 'CCTV1');
    });

    test('M3U：#EXTVLCOPT 行级 UA 压过 #EXTINF 属性', () {
      final playlist = parseLivePlaylist('live.m3u', '''
#EXTM3U
#EXTINF:-1 http-user-agent="FooUA",A
#EXTVLCOPT:http-user-agent=BarUA
http://h/a.m3u8
''');
      expect(playlist.allChannels.single.header['User-Agent'], 'BarUA');
    });

    test('M3U：URL 行 |User-Agent 参数同样压过 #EXTINF 属性', () {
      final playlist = parseLivePlaylist('live.m3u', '''
#EXTM3U
#EXTINF:-1 http-user-agent="FooUA",A
http://h/a.m3u8|User-Agent=BazUA
''');
      expect(playlist.allChannels.single.header['User-Agent'], 'BazUA');
    });

    test('M3U：已显式写入的 User-Agent 不被后一条 #EXTINF 属性改写', () {
      final playlist = parseLivePlaylist('live.m3u', '''
#EXTM3U
#EXTINF:-1,A
#EXTVLCOPT:http-user-agent=BarUA
http://h/a.m3u8
#EXTINF:-1 http-user-agent="FooUA",A
http://h/a2.m3u8
''');
      final channel = playlist.allChannels.single;
      expect(channel.urls, hasLength(2));
      expect(channel.header['User-Agent'], 'BarUA');
    });

    test('M3U：未声明 UA 时 header 里不出现 User-Agent', () {
      final playlist = parseLivePlaylist('live.m3u', '''
#EXTM3U
#EXTINF:-1,无 UA 频道
http://h/a.m3u8
''');
      final channel = playlist.allChannels.single;
      expect(channel.header.containsKey('User-Agent'), isFalse);
      expect(channel.header.asRequestHeaders, isEmpty);
    });

    test('JSON：频道的 ua 字段同样变成 User-Agent 请求头', () {
      final playlist = parseLivePlaylist('live.json', '''
[
  {
    "name": "央视",
    "channel": [
      {"name": "CCTV1", "urls": ["http://h/a.m3u8"], "ua": "FooUA", "tvgName": "CCTV1A"},
      {"name": "CCTV2", "urls": ["http://h/b.m3u8"]}
    ]
  }
]
''');
      final cctv1 = playlist.channelById('CCTV1')!;
      expect(cctv1.header.asRequestHeaders['User-Agent'], 'FooUA');
      expect(cctv1.extra['ua'], 'FooUA');
      expect(cctv1.extra['tvgName'], 'CCTV1A');
      // 未声明 ua 的频道保持「未声明」语义，不塞默认值。
      expect(playlist.channelById('CCTV2')!.header.keyNames, isEmpty);
    });

    test('JSON：channel.header 对象按 HeaderMap 口径解析', () {
      final playlist = parseLivePlaylist('live.json', '''
[
  {
    "name": "央视",
    "channel": [
      {
        "name": "CCTV1",
        "urls": ["http://h/a.m3u8"],
        "header": {"User-Agent": "ExplicitUA", "Referer": "http://r/", "Cookie": "k=v"}
      }
    ]
  }
]
''');
      expect(playlist.allChannels.single.header.asRequestHeaders, {
        'User-Agent': 'ExplicitUA',
        'Referer': 'http://r/',
        'Cookie': 'k=v',
      });
    });

    test('JSON：显式 header 的 User-Agent 压过 ua 字段（键名大小写不敏感）', () {
      final playlist = parseLivePlaylist('live.json', '''
[
  {
    "name": "央视",
    "channel": [
      {"name": "CCTV1", "urls": ["http://h/a.m3u8"], "header": {"user-agent": "ExplicitUA"}, "ua": "FooUA"}
    ]
  }
]
''');
      final channel = playlist.allChannels.single;
      // HeaderMap 读取大小写不敏感，写出去的键名保留配置里的原始大小写。
      expect(channel.header['User-Agent'], 'ExplicitUA');
      // 同名字段不应因大小写差异并存成两条。
      expect(channel.header.keyNames, ['user-agent']);
      // extras 里的声明原样保留。
      expect(channel.extra['ua'], 'FooUA');
    });

    test('JSON：referer / origin 字段落成请求头（未显式声明时）', () {
      final playlist = parseLivePlaylist('live.json', '''
[
  {
    "name": "央视",
    "channel": [
      {"name": "CCTV1", "urls": ["http://h/a.m3u8"], "ua": "FooUA", "referer": "http://r/", "origin": "http://o/"}
    ]
  }
]
''');
      expect(playlist.allChannels.single.header.asRequestHeaders, {
        'User-Agent': 'FooUA',
        'Referer': 'http://r/',
        'Origin': 'http://o/',
      });
    });

    test('JSON：显式 header 的 Referer 压过 referer 字段', () {
      final playlist = parseLivePlaylist('live.json', '''
[
  {
    "name": "央视",
    "channel": [
      {"name": "CCTV1", "urls": ["http://h/a.m3u8"], "header": {"Referer": "http://explicit/"}, "referer": "http://field/"}
    ]
  }
]
''');
      expect(
        playlist.allChannels.single.header.asRequestHeaders['Referer'],
        'http://explicit/',
      );
    });

    test('JSON：header 里的空值等同未声明，字段兜底仍然生效', () {
      final playlist = parseLivePlaylist('live.json', '''
[
  {
    "name": "央视",
    "channel": [
      {"name": "CCTV1", "urls": ["http://h/a.m3u8"], "header": {"User-Agent": "", "X-Keep": "1"}, "ua": "FooUA"}
    ]
  }
]
''');
      expect(playlist.allChannels.single.header.asRequestHeaders, {
        'User-Agent': 'FooUA',
        'X-Keep': '1',
      });
    });

    test('JSON：什么都没声明时 header 为空（不注入默认值）', () {
      final playlist = parseLivePlaylist('live.json', '''
[
  {
    "name": "央视",
    "channel": [
      {"name": "CCTV1", "urls": ["http://h/a.m3u8"]}
    ]
  }
]
''');
      expect(playlist.allChannels.single.header.asRequestHeaders, isEmpty);
    });

    test('解析出的 UA 随播放请求下发（UI 层无需改动）', () {
      // live_page / live_playback_session 都是直接转发 channel.header，
      // 所以只要解析器把声明落进 header，播放请求就自然带上。
      final playlist = parseLivePlaylist('live.m3u', '''
#EXTM3U
#EXTINF:-1 http-user-agent="FooUA",CCTV1
http://h/a.m3u8
''');
      final request = LivePage.requestForChannel(
        playlist.allChannels.single,
        sourceName: 'src',
      );
      expect(request.headers['User-Agent'], 'FooUA');
    });
  });
}
