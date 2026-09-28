/// 直播单元测试（设计文档 §13.2、§13.3）。
///
/// 覆盖 `LiveSource`（配置 `lives[]`）、`LiveChannel`（频道/多线路）、
/// `LiveGroup`/`LivePlaylist`（分组树）的解析与序列化，`AppConfig` 对
/// `lives` 字段的解析（§7.1、§7.5），以及 M3U/TXT/JSON 直播清单解析与
/// 错误路径（§8.4）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/config_parser.dart';
import 'package:webhtv_pc/core/live_playlist.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/storage.dart';

import 'fixture_support.dart';

void main() {
  group('直播数据模型（§13.2）', () {
    test('LiveSource 解析：name/type/url 与额外字段', () {
      final source = LiveSource.fromJson({
        'name': '央视',
        'type': 2,
        'url': 'http://h/live.txt',
        'epg': 'http://h/epg.xml',
        'proxy': 'http://p:8080',
        'referer': 'http://h/',
        'userAgent': 'UA/1.0',
        'customKey': 'custom-value',
      })!;
      expect(source.name, '央视');
      expect(source.type, LiveLineType.txt);
      expect(source.url, 'http://h/live.txt');
      expect(source.epg, 'http://h/epg.xml');
      expect(source.proxy, 'http://p:8080');
      expect(source.referer, 'http://h/');
      expect(source.userAgent, 'UA/1.0');
      // 未知字段保留，支持「导入 → 保存 → 恢复」不失真（§7.1）。
      expect(source.extra['customKey'], 'custom-value');
    });

    test('LiveSource 缺 name 返回 null；type 缺省为 M3U', () {
      expect(LiveSource.fromJson({'url': 'http://h/a.m3u'}), isNull);
      final source = LiveSource.fromJson({'name': 'x'})!;
      expect(source.type, LiveLineType.m3u);
    });

    test('LiveSource 序列化往返保留未知字段', () {
      final source = LiveSource.fromJson({
        'name': 'x',
        'type': 3,
        'futureField': 42,
      })!;
      final restored = LiveSource.fromJson(source.toJson())!;
      expect(restored.name, 'x');
      expect(restored.type, LiveLineType.json);
      expect(restored.extra['futureField'], 42);
    });

    test('LiveChannel：多线路保留顺序，播放失败可依次尝试', () {
      final channel = LiveChannel.fromJson({
        'name': '中央一台',
        'number': 1,
        'logo': 'http://h/logo.png',
        'epgId': 'cctv1',
        'urls': ['http://h/a.m3u8', 'http://h/b.m3u8', 'http://h/c.m3u8'],
        'group': '默认',
      });
      expect(channel.number, 1);
      expect(channel.logo, 'http://h/logo.png');
      expect(channel.epgId, 'cctv1');
      expect(channel.group, '默认');
      expect(channel.urls, hasLength(3));
      expect(channel.urls.first, 'http://h/a.m3u8');
      // 未知字段保留。
      expect(channel.toJson().containsKey('urls'), isTrue);
    });

    test('LiveChannel 缺 name 时用「未知频道」，缺 urls 时为空列表', () {
      final channel = LiveChannel.fromJson({'name': null, 'url': 'http://h/x'});
      expect(channel.name, '未知频道');
      expect(channel.urls, isEmpty);
      // toJson 将 url（未知字段）保留且不丢。
      expect(channel.toJson()['url'], 'http://h/x');
    });

    test('LivePlaylist：分组、频道数与展平查询', () {
      final playlist = LivePlaylist(
        sourceName: '样本',
        groups: [
          LiveGroup(
            name: '新闻',
            channels: [
              LiveChannel.fromJson({'name': '央视新闻', 'urls': ['http://h/a']}),
              LiveChannel.fromJson({'name': 'BBC', 'urls': ['http://h/b']}),
            ],
          ),
          LiveGroup(
            name: '体育',
            channels: [
              LiveChannel.fromJson({'name': 'ESPN', 'urls': ['http://h/c']}),
            ],
          ),
        ],
        rawLines: 12,
      );

      expect(playlist.groups, hasLength(2));
      expect(playlist.channelCount, 3);
      expect(playlist.allChannels.map((c) => c.name), containsAll(['央视新闻', 'BBC', 'ESPN']));
      expect(playlist.channelById('bbc')!.urls.first, 'http://h/b');
      expect(playlist.channelById('不存在'), isNull);
      expect(playlist.rawLines, 12);
    });

    test('LivePlaylist 未分组频道归入「未分组」组', () {
      final playlist = LivePlaylist(
        sourceName: 'x',
        groups: [
          LiveGroup(
            name: '未分组',
            channels: [
              LiveChannel.fromJson({'name': '无名频道', 'urls': ['http://h/a']}),
            ],
          ),
        ],
      );
      expect(playlist.groups.single.name, '未分组');
      expect(playlist.allChannels.single.name, '无名频道');
    });
  });

  group('AppConfig.lives 解析（§7.1、§7.5）', () {
    test('config-full 中的直播源被解析为 LiveSource', () {
      final document = parseConfigDocument(
        readFixture('config/config-full.json'),
      );
      final config = document.config!;
      expect(config.lives, hasLength(1));
      final live = config.lives.single;
      expect(live.name, 'fixture-live');
      expect(live.type, LiveLineType.m3u);
      expect(live.url, 'http://127.0.0.1:18080/live.m3u');
    });

    test('无 lives 时不报错且为空列表', () {
      final document = parseConfigDocument(
        jsonEncode({
          'name': 't',
          'sites': [
            {'key': 'k', 'name': 'n', 'type': 1, 'api': 'http://h/api'},
          ],
        }),
      );
      expect(document.config!.lives, isEmpty);
      expect(document.diagnostics, isEmpty);
    });

    test('缺 name 的直播源条目被跳过并记诊断', () {
      final document = parseConfigDocument(
        jsonEncode({
          'name': 't',
          'sites': [
            {'key': 'k', 'name': 'n', 'type': 1, 'api': 'http://h/api'},
          ],
          'lives': [
            {'url': 'http://h/no-name.m3u'},
            {'name': '正常', 'url': 'http://h/ok.m3u', 'type': 1},
          ],
        }),
      );
      expect(document.config!.lives.single.name, '正常');
      expect(document.diagnostics.join(), contains('直播源'));
    });

    test('AppConfig 往返（toJson → fromJson）保留直播源', () {
      final source = LiveSource.fromJson({'name': '回看', 'type': 1, 'url': 'http://h/a.m3u'})!;
      final config = AppConfig(
        name: 't',
        sites: [
          Site(key: 'k', name: 'n', type: 1, api: 'http://h/api'),
        ],
        lives: [source],
      );
      final restored = parseConfigRecord(config.toJson());
      expect(restored.lives, hasLength(1));
      expect(restored.lives.single.name, '回看');
      expect(restored.lives.single.url, 'http://h/a.m3u');
    });
  });

  // ---------------------------------------------------------------------------
  // 直播清单解析（§13.3）：M3U / TXT / JSON
  // ---------------------------------------------------------------------------

  group('直播解析：格式识别与 M3U（§13.3）', () {
    test('含 #EXTM3U 且不含 #genre# 判为 M3U 并解析分组与属性', () {
      final playlist = parseLivePlaylist(
        'live.m3u',
        readFixture('live/live.m3u'),
      );

      // 分组顺序按首次出现：央视 → 卫视 → 未分组。
      expect(
        playlist.groups.map((group) => group.name),
        ['央视', '卫视', '未分组'],
      );
      expect(playlist.channelCount, 6);
      // `#EXTM3U url-tvg` 被解析为清单 EPG（§13.1）。
      expect(playlist.epg, 'http://127.0.0.1:18080/live/epg.xml');

      final cctv1 = playlist.channelById('CCTV-1 综合')!;
      expect(cctv1.number, 1);
      expect(cctv1.epgId, 'cctv1');
      expect(cctv1.logo, 'http://127.0.0.1:18080/live/logo/cctv1.png');
      expect(cctv1.group, '央视');
      expect(cctv1.urls, ['http://127.0.0.1:18080/media/sample.m3u8']);
      // `tvg-name` 保留为扩展字段。
      expect(cctv1.extra['tvgName'], 'CCTV1');
    });

    test('M3U 同名频道跨行合并线路，且按频道号排序', () {
      final playlist = parseLivePlaylist(
        'live.m3u',
        readFixture('live/live.m3u'),
      );
      final live = playlist.groups.firstWhere((group) => group.name == '卫视');
      // 卫视组内：湖南卫视(10) 在前，浙江卫视(无号) 在后。
      expect(live.channels.map((channel) => channel.name), ['湖南卫视', '浙江卫视']);
      final hunan = live.channels.first;
      // 两条同名 `#EXTINF` 的线路合并到同一频道，保持声明顺序。
      expect(hunan.urls, [
        'http://127.0.0.1:18080/media/sample.m3u8',
        'http://127.0.0.1:18080/media/sample.mp4',
      ]);
      expect(hunan.number, 10);
    });

    test('M3U 的 #EXTVLCOPT 头部注入到紧随频道（§13.1 直播 Header）', () {
      final playlist = parseLivePlaylist(
        'live.m3u',
        readFixture('live/live.m3u'),
      );
      final zhejiang = playlist.channelById('浙江卫视')!;
      expect(zhejiang.header['Referer'], 'http://127.0.0.1:18080/');
      expect(zhejiang.header['User-Agent'], 'WebHTV-PC/0.1 (Windows)');
    });

    test('无 group-title 的频道归入「未分组」；元频道行被跳过', () {
      final playlist = parseLivePlaylist(
        'live.m3u',
        readFixture('live/live.m3u'),
      );
      final ungrouped = playlist.groups.firstWhere((group) => group.name == '未分组');
      expect(ungrouped.channels.single.name, '无分组测试频道');
      // `更新时间 2026-09-28` 是元行，不产生频道。
      expect(playlist.allChannels.any((c) => c.name.startsWith('更新时间')), isFalse);
    });
  });

  group('直播解析：TXT（§13.3）', () {
    test('#genre# 分组行建立层级，频道行按 `名称,地址` 解析', () {
      final playlist = parseLivePlaylist(
        'live.txt',
        readFixture('live/live.txt'),
      );
      expect(
        playlist.groups.map((group) => group.name),
        ['央视', '卫视'],
      );
      final cctv1 = playlist.channelById('CCTV-1 综合')!;
      expect(cctv1.group, '央视');
      expect(cctv1.urls, ['http://127.0.0.1:18080/media/sample.m3u8']);
    });

    test('同频道多地址用 `#` 分隔并保持顺序', () {
      final playlist = parseLivePlaylist(
        'live.txt',
        readFixture('live/live.txt'),
      );
      final cctv2 = playlist.channelById('CCTV-2 财经')!;
      expect(cctv2.urls, [
        'http://127.0.0.1:18080/media/sample.m3u8',
        'http://127.0.0.1:18080/media/sample.mp4',
      ]);
    });

    test('单地址可附带 `|header参数`（§13.1 直播 Header）', () {
      final playlist = parseLivePlaylist(
        'live.txt',
        readFixture('live/live.txt'),
      );
      final zhejiang = playlist.channelById('浙江卫视')!;
      expect(zhejiang.urls, ['http://127.0.0.1:18080/media/sample.m3u8']);
      expect(zhejiang.header['Referer'], 'http://127.0.0.1:18080/');
      expect(zhejiang.header['User-Agent'], 'WebHTV-PC/0.1');
    });

    test('元频道行被跳过；无分组行时频道归入「未分组」', () {
      final playlist = parseLivePlaylist(
        'x.txt',
        '未分组频道,http://h/a.m3u8\n'
            '更新时间,2026-01-01\n',
      );
      expect(playlist.groups.single.name, '未分组');
      expect(playlist.allChannels.map((c) => c.name), ['未分组频道']);
    });
  });

  group('直播解析：JSON（§13.3）', () {
    test('JSON 数组按 groups[].channel[] 解析', () {
      final playlist = parseLivePlaylist(
        'live.json',
        readFixture('live/live.json'),
      );
      expect(playlist.groups.map((group) => group.name), ['央视', '卫视']);
      expect(playlist.channelCount, 4);

      final cctv1 = playlist.channelById('CCTV-1 综合')!;
      expect(cctv1.number, 1);
      expect(cctv1.epgId, 'cctv1');
      expect(cctv1.logo, 'http://127.0.0.1:18080/live/logo/cctv1.png');
    });

    test('JSON 多线路保留顺序，非 URL 条目被丢弃', () {
      final playlist = parseLivePlaylist(
        'live.json',
        readFixture('live/live.json'),
      );
      expect(playlist.channelById('CCTV-2 财经')!.urls, [
        'http://127.0.0.1:18080/media/sample.m3u8',
        'http://127.0.0.1:18080/media/sample.mp4',
      ]);
      // `not-a-url` 不含 `://`，按 WebHTV `isPlayableUrl` 规则丢弃。
      expect(playlist.channelById('浙江卫视')!.urls, [
        'http://127.0.0.1:18080/media/sample.m3u8',
      ]);
    });

    test('JSON 空频道号按顺序生成编号（WebHTV apply 语义）', () {
      final playlist = parseLivePlaylist(
        'live.json',
        readFixture('live/live.json'),
      );
      final weishi = playlist.groups.firstWhere((group) => group.name == '卫视');
      expect(weishi.channels.first.number, 10);
      // 浙江卫视无 number，接在最大号 10 之后生成 11。
      expect(weishi.channels.last.number, 11);
    });

    test('`{"groups":[...]}` 信封形态同样被接受', () {
      final playlist = parseLivePlaylist(
        'x.json',
        jsonEncode({
          'groups': [
            {
              'name': 'g',
              'channel': [
                {
                  'name': 'c',
                  'urls': ['http://h/a.m3u8'],
                },
              ],
            },
          ],
        }),
      );
      expect(playlist.channelById('c')!.urls, ['http://h/a.m3u8']);
    });
  });

  group('直播解析：错误路径（§8.4 不许静默成功）', () {
    test('申明为 JSON 但内容非法时抛 liveInvalid，不返回空列表', () {
      expect(
        () => parseLivePlaylist('bad.json', '{"not": ', declaredType: LiveLineType.json),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.liveInvalid),
        ),
      );
    });

    test('申明为 JSON 但内容非数组/无 groups 时抛 liveInvalid', () {
      expect(
        () => parseLivePlaylist('bad.json', '{"foo":1}', declaredType: LiveLineType.json),
        throwsA(isA<AppError>()),
      );
    });

    test('内容以 `[` 开头时按 JSON 解析（无需申明 type）', () {
      final playlist = parseLivePlaylist(
        'auto.json',
        '[{"name":"g","channel":[{"name":"c","urls":["http://h/a.m3u8"]}]}]',
      );
      expect(playlist.channelCount, 1);
    });

    test('空清单返回空分组而不抛错', () {
      final playlist = parseLivePlaylist('empty.txt', '');
      expect(playlist.groups, isEmpty);
      expect(playlist.channelCount, 0);
      expect(playlist.rawLines, 0);
    });

    test('不可播放地址（无 ://）在 TXT 中被丢弃', () {
      final playlist = parseLivePlaylist(
        'x.txt',
        '分组,#genre#\n频道,not-a-url\n',
      );
      expect(playlist.allChannels, isEmpty);
    });
  });

  test('rawLines 记录原始行数（含空行，供诊断）', () {
    final playlist = parseLivePlaylist('x.txt', 'a,b\n\nc,d\n');
    expect(playlist.rawLines, 4);
  });

  // ---------------------------------------------------------------------------
  // 兼容与健壮性（§13.3）
  // ---------------------------------------------------------------------------

  group('直播解析：兼容与健壮性（§13.3）', () {
    test('缺地址行的 #EXTINF 不串台（不会被下一个频道污染）', () {
      final playlist = parseLivePlaylist(
        'x.m3u',
        '#EXTM3U\n'
            '#EXTINF:-1 group-title="A",孤儿频道\n'
            '#EXTINF:-1 group-title="A",正常频道\n'
            'http://h/ok.m3u8\n',
      );
      // 「孤儿频道」无地址行，但仍作为一个（无线路）频道存在于分组中；
      // 关键是 URL 不会被错误地归属到「正常频道」以外的地方。
      final normal = playlist.channelById('正常频道')!;
      expect(normal.urls, ['http://h/ok.m3u8']);
      expect(playlist.channelById('孤儿频道')!.urls, isEmpty);
    });

    test(r'频道线路名后缀 `url$线路名` 保留线路地址', () {
      final playlist = parseLivePlaylist(
        'x.json',
        jsonEncode({
          'groups': [
            {
              'name': 'g',
              'channel': [
                {
                  'name': 'c',
                  'urls': ['http://h/a.m3u8\$线路一', 'http://h/b.m3u8\$线路二'],
                },
              ],
            },
          ],
        }),
      );
      // 线路名后缀不影响「是否可播放」判定，两条线路都被保留。
      expect(playlist.channelById('c')!.urls, hasLength(2));
    });

    test('{code:0,data:[...]} 信封按 JSON 数组解析', () {
      final playlist = parseLivePlaylist(
        'x.json',
        jsonEncode({
          'code': 0,
          'data': [
            {
              'name': 'g',
              'channel': [
                {
                  'name': 'c',
                  'urls': ['http://h/a.m3u8'],
                },
              ],
            },
          ],
        }),
        declaredType: LiveLineType.json,
      );
      expect(playlist.channelById('c')!.urls, ['http://h/a.m3u8']);
    });

    test('type 声明为 M3U 但内容实为 TXT 时按内容兑底', () {
      final playlist = parseLivePlaylist(
        'x',
        '频道,http://h/a.m3u8\n',
        declaredType: LiveLineType.m3u,
      );
      expect(playlist.channelById('频道')!.urls, ['http://h/a.m3u8']);
    });

    test('type 声明为 JSON 但内容是 TXT 时按 JSON 解析并报 liveInvalid', () {
      expect(
        () => parseLivePlaylist('x', '频道,http://h/a.m3u8', declaredType: LiveLineType.json),
        throwsA(isA<AppError>()),
      );
    });
  });
}
