/// 播放入口目标（`PlaybackRequest.episodeTarget`）门禁测试。
///
/// 缺陷背景（用户反馈 2026-10-09：「无法从历史记录页面继续播放」）：
///
/// 历史记录里的 `episodeId` 必须是**站点播放入口的输入目标**（详情 `vod_play_url`
/// 里该集 `$` 之后的值；网盘站是分享链，普通站是剧集地址），续播时拿它回传站点
/// **重新解析**。但实现里 `recordProgress` 存的是 `_request.url`——那是解析后的
/// **可播地址**（T4 站点还会被换成本地代理 `127.0.0.1/p/<token>/…`，带时效签名）。
/// 站点认不了这个值，于是续播得到「站点返回业务错误」，表现为「点继续播放没反应」。
///
/// 因此 `PlaybackRequest` 拆出两个字段：
/// - `url`：解析后的可播地址（交给播放器）；
/// - `episodeTarget`：站点入口输入（写历史 / 回传站点重解析）。
///
/// 本文件锁定三条不变量（都是这次缺陷的直接成因）：
/// 1. 不传 `episodeTarget` 时回退到 `url`（命令行媒体 / 直播等无二次解析场景）；
/// 2. 显式传入时两者**分离**，不互相覆盖；
/// 3. `copyWith` 换 `url`（换集）时 **不得**把 `episodeTarget` 顶成播放地址——
///    必须由调用点显式传入该集的入口目标，否则历史会记成站点认不了的值。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

PlaybackRequest _request({
  required String url,
  String? episodeTarget,
  String flag = '百度#木偶',
}) => PlaybackRequest(
  url: url,
  episodeTarget: episodeTarget,
  title: '测试影片',
  siteKey: 'site-a',
  vodId: 'vod-1',
  vodName: '测试影片',
  episodeName: '第 1 集',
  flag: flag,
);

void main() {
  group('episodeTarget 与 url 的语义分离（§15.2）', () {
    test('不传 episodeTarget → 回退到 url（命令行 / 直播兼容）', () {
      const url = 'http://127.0.0.1:4712/p/token/aHR0cHM6Ly8';
      final request = _request(url: url);
      expect(request.url, url);
      expect(
        request.episodeTarget,
        url,
        reason: '无站点入口语义的场景（命令行 / 直播）应回退到可播地址',
      );
    });

    test('显式传入时与 url 分离：url 是解析结果，episodeTarget 是站点入口', () {
      const target = 'https://pan.baidu.com/s/10VoZ5K';
      const resolved = 'http://127.0.0.1:4712/p/token/aHR0cHM6Ly8';
      final request = _request(url: resolved, episodeTarget: target);
      expect(request.url, resolved, reason: 'url 必须是交给播放器的可播地址');
      expect(
        request.episodeTarget,
        target,
        reason: 'episodeTarget 必须是站点能认的入口目标（历史存它）',
      );
      expect(
        request.episodeTarget,
        isNot(request.url),
        reason: '两者语义不同，分离后不应相等',
      );
    });

    test('folder 条目：入口目标是分享链，url 是代理地址', () {
      const shareLink = 'https://pan.baidu.com/s/1abcDEF';
      const proxy = 'http://127.0.0.1:4712/p/xyz/aHR0cHM6';
      final request = _request(url: proxy, episodeTarget: shareLink);
      expect(request.episodeTarget, shareLink);
      expect(request.url, proxy);
    });
  });

  group('copyWith 不因换 url 而漂移 episodeTarget（缺陷成因）', () {
    test('只换 url：episodeTarget 必须保持不变', () {
      const target = 'https://pan.baidu.com/s/10VoZ5K';
      final first = _request(url: 'http://127.0.0.1/p/t1/a', episodeTarget: target);

      // 模拟「只更新可播地址」的调用（例如重试 / 刷新直链）。
      final second = first.copyWith(url: 'http://127.0.0.1/p/t2/b');

      expect(second.url, 'http://127.0.0.1/p/t2/b');
      expect(
        second.episodeTarget,
        target,
        reason: '换 url 不得把站点入口目标顶成播放地址（否则历史又存错）',
      );
    });

    test('换集显式传 episodeTarget：两者一起更新', () {
      final first = _request(
        url: 'http://127.0.0.1/p/t1/a',
        episodeTarget: 'https://pan.baidu.com/s/EP1',
      );
      final second = first.copyWith(
        url: 'http://127.0.0.1/p/t2/b',
        episodeTarget: 'https://pan.baidu.com/s/EP2',
        episodeName: '第 2 集',
      );
      expect(second.episodeTarget, 'https://pan.baidu.com/s/EP2');
      expect(second.url, 'http://127.0.0.1/p/t2/b');
      expect(second.episodeName, '第 2 集');
    });

    test('未传 episodeTarget 且未换 url：保持原值', () {
      final first = _request(
        url: 'http://127.0.0.1/p/t1/a',
        episodeTarget: 'https://pan.baidu.com/s/EP1',
      );
      final second = first.copyWith(episodeName: '第 3 集');
      expect(second.episodeTarget, 'https://pan.baidu.com/s/EP1');
      expect(second.url, first.url);
    });
  });
}
