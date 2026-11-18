import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_platform.dart';

void main() {
  group('播放平台文案（TMDB networks）', () {
    test('台名以 / 连接，最多两个', () {
      expect(
        playbackPlatformLabel(networks: const ['CCTV-8', 'Youku', 'Tencent Video']),
        'CCTV-8 / 优酷',
      );
    });

    test('没有台名时返回空串（调用方隐藏标签）', () {
      expect(playbackPlatformLabel(), '');
      expect(playbackPlatformLabel(networks: const ['', ' ']), '');
    });

    test('去重且保序，映射后重复也算重复', () {
      expect(
        playbackPlatformLabel(networks: const ['Youku', 'Youku']),
        '优酷',
      );
      expect(
        playbackPlatformLabel(networks: const ['Youku', '优酷']),
        '优酷',
      );
    });

    test('maxNetworks 小于等于 0 不设上限', () {
      expect(
        playbackPlatformLabel(networks: const ['HBO', 'Netflix', 'AMC'], maxNetworks: 0),
        'HBO / Netflix / AMC',
      );
    });

    test('台名与站源名无关：站点名不在这个函数里出现', () {
      // 站源名（如「荐片」）不再参与平台标签：没有 networks 就是空文案。
      expect(playbackPlatformLabel(networks: const []), '');
    });
  });

  group('TMDB 台名中文显示名', () {
    test('常见平台映射成中文', () {
      expect(tmdbNetworkDisplayName('Tencent Video'), '腾讯视频');
      expect(tmdbNetworkDisplayName('iQIYI'), '爱奇艺');
      expect(tmdbNetworkDisplayName('  youku '), '优酷');
      expect(tmdbNetworkDisplayName('Mango TV'), '芒果TV');
      expect(tmdbNetworkDisplayName('Hunan TV'), '湖南卫视');
      // TMDB 两套写法都要收：Hunan Television / Zhejiang Television。
      expect(tmdbNetworkDisplayName('Hunan Television'), '湖南卫视');
      expect(tmdbNetworkDisplayName('Zhejiang Television'), '浙江卫视');
      expect(tmdbNetworkDisplayName('Jiangsu television'), '江苏卫视');
    });

    test('未收录的原样返回（英文品牌与 CCTV 频段）', () {
      expect(tmdbNetworkDisplayName('HBO'), 'HBO');
      expect(tmdbNetworkDisplayName('Netflix'), 'Netflix');
      expect(tmdbNetworkDisplayName('CCTV-8'), 'CCTV-8');
      expect(tmdbNetworkDisplayName(''), '');
    });
  });

  group('TMDB networks 解析', () {
    test('取 name、去空、去重、保序', () {
      final raw = [
        {'id': 521, 'name': 'CCTV-8'},
        {'id': 1419, 'name': 'Youku'},
        {'id': 9, 'name': ''},
        {'id': 1, 'name': 'CCTV-8'},
        {'id': 7},
        'not-a-map',
      ];
      expect(tmdbNetworkNames(raw), ['CCTV-8', 'Youku']);
      expect(tmdbNetworkNames(raw, cap: 1), ['CCTV-8']);
      expect(tmdbNetworkNames(raw, cap: 0), ['CCTV-8', 'Youku']);
    });

    test('非 List / null 一律空列表', () {
      expect(tmdbNetworkNames(null), isEmpty);
      expect(tmdbNetworkNames('Youku'), isEmpty);
      expect(tmdbNetworkNames(const <String>[]), isEmpty);
    });
  });
}
