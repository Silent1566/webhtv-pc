/// 推送解析（安卓 `utils/PushParser.java` 的移植）与推送播放请求。
///
/// 锁定的行为：
/// 1. 安卓已支持的写法必须逐条成立：`地址|剧名`、`push://`、说明文字里嗅探、
///    结构化播放串透传、请求头行不当剧名；
/// 2. 两栏字段（PC 推送页/对话框）优先于 `地址|剧名`；
/// 3. 展示标题：剧名 → 文件名 → 兜底标题，历史卡片不出现整条 URL；
/// 4. 推送合成站点的播放请求字段（`siteKey`/`vodId`/`episodeTarget`）；
/// 5. 本地路径判定与本地播放请求沿用既有本地语义。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_request.dart';
import 'package:webhtv_pc/core/detail_source_merge.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/push_parser.dart';

void main() {
  group('安卓同款语法', () {
    test('地址|剧名 按最后一个竖线拆分', () {
      final parsed = parsePushText('https://cdn.example/a.m3u8|庆余年');
      expect(parsed.url, 'https://cdn.example/a.m3u8');
      expect(parsed.title, '庆余年');
      expect(parsed.hasExplicitTitle, isTrue);
      expect(parsed.id, 'https://cdn.example/a.m3u8|庆余年');
    });

    test('剧名里带竖线时只拆最后一个', () {
      final parsed = parsePushText('https://cdn.example/a.m3u8|名字|别名');
      expect(parsed.url, 'https://cdn.example/a.m3u8|名字');
      expect(parsed.title, '别名');
    });

    test('后缀是另一个地址时不当剧名', () {
      const text = 'http://a/1.m3u8|https://b/2.m3u8';
      final parsed = parsePushText(text);
      expect(parsed.url, text, reason: '整段都要原样保留，不能把第二个地址甩掉');
      expect(parsed.hasExplicitTitle, isFalse);
    });

    test('后缀是请求头行时不当剧名，且只留地址本身', () {
      // 安卓会把 `|User-Agent:` 一起当成地址（上游 test 只覆盖无空格形态），
      // 那种串播不了；PC 只保留地址，请求头不进 do=push 载荷。
      for (final text in [
        'http://a/1.m3u8|User-Agent: okhttp',
        'http://a/1.m3u8|User-Agent=okhttp',
        'http://a/1.m3u8|Referer: https://x/',
      ]) {
        final parsed = parsePushText(text);
        expect(parsed.url, 'http://a/1.m3u8', reason: text);
        expect(parsed.hasExplicitTitle, isFalse, reason: text);
      }
    });

    test('后缀没有文字（含纯标点/空）时不当剧名', () {
      for (final text in ['http://a/1.m3u8|', 'http://a/1.m3u8|···']) {
        final parsed = parsePushText(text);
        expect(parsed.url, text, reason: text);
        expect(parsed.hasExplicitTitle, isFalse, reason: text);
      }
    });

    test('数字后缀算剧名（是否参与自动匹配由守卫另行判定）', () {
      final parsed = parsePushText('http://a/1.m3u8|1234');
      expect(parsed.title, '1234');
    });

    test('push:// 前缀被剥离', () {
      expect(parsePushText('push://https://cdn.example/a.m3u8').url,
          'https://cdn.example/a.m3u8');
    });

    test('夹在说明文字里的地址被嗅探出来', () {
      final parsed = parsePushText('这个能看吗？ https://cdn.example/a.m3u8 谢谢');
      expect(parsed.url, 'https://cdn.example/a.m3u8');
    });

    test('结构化播放串原样透传', () {
      const text = r'{"url":"https://a/1.m3u8","headers":{"Referer":"x"}}';
      expect(parsePushText(text).url, text);
      const play = r'https://a/1.m3u8$https://a/2.m3u8';
      expect(parsePushText(play).url, play, reason: '含 \$ 的站点播放串不拆不嗅探');
    });
  });

  group('两栏字段', () {
    test('独立剧名字段优先', () {
      final parsed = parsePushFields(
        url: 'https://cdn.example/a.m3u8|旧的',
        title: '新的',
      );
      expect(parsed.url, 'https://cdn.example/a.m3u8');
      expect(parsed.title, '新的');
    });

    test('没给剧名字段时按地址里的后缀解析', () {
      final parsed = parsePushFields(url: 'https://a/1.m3u8|庆余年');
      expect(parsed.title, '庆余年');
    });

    test('空白剧名字段不算显式剧名', () {
      final parsed = parsePushFields(url: 'https://a/1.m3u8', title: '   ');
      expect(parsed.hasExplicitTitle, isFalse);
    });
  });

  group('展示标题', () {
    test('剧名优先', () {
      expect(pushDisplayTitle(url: 'https://a/1.m3u8', title: '庆余年'), '庆余年');
    });

    test('没剧名时用地址里的文件名（去扩展名）', () {
      expect(pushDisplayTitle(url: 'https://a/庆余年.S01E01.mkv'), '庆余年.S01E01');
      expect(pushDisplayTitle(url: '/mnt/videos/阿凡达.2009.mkv'), '阿凡达.2009');
    });

    test('只有域名或磁力链时用兜底标题', () {
      expect(pushDisplayTitle(url: 'https://cdn.example/'), pushFallbackTitle);
      expect(pushDisplayTitle(url: 'https://cdn.example'), pushFallbackTitle);
      expect(
        pushDisplayTitle(url: 'magnet:?xt=urn:btih:abcdef'),
        pushFallbackTitle,
      );
    });
  });

  group('本地路径判定', () {
    test('盘符 / POSIX / UNC / file:// 都算本地', () {
      for (final value in [
        r'D:\视频\a.mkv',
        'D:/视频/a.mkv',
        '/mnt/videos/a.mkv',
        r'\\nas\share\a.mkv',
        'file:///mnt/videos/a.mkv',
      ]) {
        expect(looksLikeLocalMediaPath(value), isTrue, reason: value);
      }
    });

    test('网络地址与相对路径不算本地', () {
      for (final value in [
        'https://cdn.example/a.m3u8',
        'magnet:?xt=urn:btih:abcdef',
        'videos/a.mkv',
        '',
      ]) {
        expect(looksLikeLocalMediaPath(value), isFalse, reason: value);
      }
    });

    test('明显媒体位置（守卫用）', () {
      expect(isObviousMediaLocation('https://a/1.m3u8'), isTrue);
      expect(isObviousMediaLocation('/mnt/a.mkv'), isTrue);
      expect(isObviousMediaLocation('庆余年'), isFalse);
    });
  });

  group('推送播放请求', () {
    test('远程地址 → 推送合成站点', () {
      final request = pushPlaybackRequest(
        parsed: parsePushFields(url: 'https://cdn.example/a.m3u8', title: '庆余年'),
      );
      expect(request.url, 'https://cdn.example/a.m3u8');
      expect(request.siteKey, pushSiteKey);
      expect(request.vodId, 'https://cdn.example/a.m3u8');
      expect(request.vodName, '庆余年');
      expect(request.title, '庆余年');
      expect(request.episodeName, '庆余年');
      expect(request.flag, pushSourceName);
      expect(request.episodeTarget, request.url, reason: '历史续播要回传站点入口目标');
      expect(request.headers, isEmpty);
      expect(request.isLocal, isFalse);
      expect(request.tmdb, isNull);
    });

    test('本地路径 → 既有本地播放语义', () {
      final request = pushPlaybackRequest(
        parsed: parsePushFields(url: '/mnt/videos/a.mkv', title: '阿凡达'),
        localPath: '/mnt/videos/a.mkv',
      );
      expect(request.isLocal, isTrue);
      expect(request.sourceKind, PlaybackSourceKind.local);
      expect(request.siteKey, PlaybackRequest.localSiteKey);
      expect(request.localPath, '/mnt/videos/a.mkv');
      expect(request.title, '阿凡达', reason: '剧名就是屏显标题');
      expect(request.headers, isEmpty);
    });
  });

  group('合成推送详情（安卓 pushDetail 对应物）', () {
    test('一条线路一集，地址就是推送地址', () {
      final detail = pushSiteDetail(
        parsePushFields(url: 'https://cdn.example/a.m3u8', title: '庆余年'),
      );
      expect(detail.list, hasLength(1));
      final vod = detail.list.single;
      expect(vod.vodName, '庆余年');
      expect(vod.vodPlayFrom, pushSourceName);
      final lines = parseVodPlayLines(vod);
      expect(lines, hasLength(1));
      expect(lines.single.flag, pushSourceName);
      expect(lines.single.episodes.single.name, '庆余年');
      expect(lines.single.episodes.single.url, 'https://cdn.example/a.m3u8');
    });

    test('没剧名时用文件名，集名是兜底文案', () {
      final detail = pushSiteDetail(
        parsePushFields(url: 'https://cdn.example/阿凡达.2009.mkv'),
      );
      final vod = detail.list.single;
      expect(vod.vodName, '阿凡达.2009');
      expect(vod.vodContent, isNull);
      expect(parseVodPlayLines(vod).single.episodes.single.name, '推送内容');
    });
  });

  group('推送源选择（跨配置）', () {
    Site site(String key, String name, {int type = 3}) =>
        Site(key: key, name: name, type: type, api: 'x');

    test('key 精确命中 push_agent 优先于名字像推送的站点', () {
      final config = AppConfig(
        sites: [
          site('nodejs_push', '推送', type: 4),
          site('push_agent', '推送'),
        ],
      );
      expect(pushSiteInConfig(config)?.key, 'push_agent');
    });

    test('没有精确 key 时认 key/名字像推送的站点', () {
      final config = AppConfig(
        sites: [site('other', '别的'), site('nodejs_push', '推送', type: 4)],
      );
      expect(pushSiteInConfig(config)?.key, 'nodejs_push');
    });

    test('完全没有推送站点时返回 null（走合成详情）', () {
      final config = AppConfig(sites: [site('a', '甲站'), site('b', '乙站')]);
      expect(pushSiteInConfig(config), isNull);
    });
  });

  group('片名优先级（手填剧名压过推送源名字）', () {
    final detail = Vod(
      vodId: 'https://pan.baidu.com/s/abc',
      vodName: 'pan.baidu.com/s/abc',
      vodPlayFrom: '推送',
      vodPlayUrl: '第1集\$https://pan.baidu.com/s/abc',
    );
    final listing = Vod(
      vodId: 'https://pan.baidu.com/s/abc',
      vodName: '罪蓝之路',
      vodPlayFrom: '推送',
      vodPlayUrl: '第1集\$https://pan.baidu.com/s/abc',
    );

    test('给了剧名就用剧名', () {
      final merged = mergeSourceDetailDisplay(
        detail: detail,
        listing: listing,
        nameOverride: '罪蓝之路',
      );
      expect(merged.vodName, '罪蓝之路');
      expect(merged.vodPlayUrl, detail.vodPlayUrl, reason: '线路仍来自详情');
    });

    test('没给剧名时听详情返回的名字', () {
      final merged = mergeSourceDetailDisplay(detail: detail, listing: listing);
      expect(merged.vodName, 'pan.baidu.com/s/abc');
    });

    test('空白的覆盖不算覆盖', () {
      final merged = mergeSourceDetailDisplay(
        detail: detail,
        listing: listing,
        nameOverride: '   ',
      );
      expect(merged.vodName, 'pan.baidu.com/s/abc');
    });
  });

  group('推送集名清洗（历史卡片用刮削后的名称）', () {
    test('剥掉大小前缀并识别 SxxExx', () {
      expect(pushEpisodeLabel('[2.44G] S01E01'), '第1集');
      expect(pushEpisodeLabel('【4K】S02E13'), '第13集');
    });

    test('纯数字与第N集', () {
      expect(pushEpisodeLabel('[6.17G] 1'), '第1集');
      expect(pushEpisodeLabel('第8集'), '第8集');
      expect(pushEpisodeLabel('第三集'), '第三集');
      expect(pushEpisodeLabel('e07'), '第7集');
    });

    test('识别不出集号时只做清洗', () {
      expect(pushEpisodeLabel('  第1集 高清  '), '第1集');
      expect(pushEpisodeLabel('[2.44G] 大结局'), '大结局');
      expect(pushEpisodeLabel('   '), '');
    });
  });

  group('推送身份稳定（站源改 id 也不能换片）', () {
    test('idOverride 压过详情返回的 id', () {
      final merged = mergeSourceDetailDisplay(
        detail: Vod(
          vodId: 'pan.baidu.com/s/abc',
          vodName: 'LIANGCHEN',
          vodPlayFrom: '推送',
          vodPlayUrl: 'E1\$https://pan.baidu.com/s/abc',
        ),
        listing: Vod(
          vodId: 'https://pan.baidu.com/s/abc',
          vodName: '良陈美锦',
          vodPlayFrom: '推送',
          vodPlayUrl: 'E1\$https://pan.baidu.com/s/abc',
        ),
        nameOverride: '良陈美锦',
        idOverride: 'https://pan.baidu.com/s/abc',
      );
      expect(merged.vodId, 'https://pan.baidu.com/s/abc');
      expect(merged.vodName, '良陈美锦');
    });
  });

  group('其它支持格式的落点（磁力 / 电驴 / 本地）', () {
    test('磁力链接当作推送地址原样交给推送源', () {
      const magnet = 'magnet:?xt=urn:btih:abcdef0123456789&dn=庆余年';
      final request = pushPlaybackRequest(
        parsed: parsePushFields(url: magnet, title: '庆余年'),
      );
      expect(request.siteKey, pushSiteKey);
      expect(request.vodId, magnet, reason: '推送源拿到的必须是原始磁力链');
      expect(request.isLocal, isFalse);
      expect(request.title, '庆余年');
    });

    test('本地路径走本地播放语义，不会被当成站源内容', () {
      final request = pushPlaybackRequest(
        parsed: parsePushFields(url: '/mnt/videos/a.mkv'),
        localPath: '/mnt/videos/a.mkv',
      );
      expect(request.isLocal, isTrue);
      expect(request.siteKey, PlaybackRequest.localSiteKey);
      expect(looksLikeLocalMediaPath('magnet:?xt=urn:btih:abc'), isFalse);
    });
  });
}
