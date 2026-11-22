/// `PlaybackRequest.posterUrl` 的承载锁。
///
/// 播放器选集卡片的「剧照缺席 → 本剧海报」回退依赖这一个字段：
/// 详情页带下来、播放器换集后仍要在。换集走的是 `copyWith`，所以它必须
/// 原样带过（曾经 `vodPic` 在 `copyWith` 里被清成 null，历史记录立刻掉封面）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_request.dart';
import 'package:webhtv_pc/core/protocol.dart';

PlaybackRequest _request({String? posterUrl}) => PlaybackRequest(
  url: 'https://media.test/1.m3u8',
  title: '晚秋寄情',
  siteKey: 'site',
  vodId: 'vod-1',
  vodName: '晚秋寄情',
  episodeName: '第1集',
  flag: '线路一',
  posterUrl: posterUrl,
  playLines: [
    VodPlayLine(
      flag: '线路一',
      episodes: [
        VodEpisode(name: '第1集', url: 'https://site.test/1'),
        VodEpisode(name: '第2集', url: 'https://site.test/2'),
      ],
    ),
  ],
);

void main() {
  test('缺省为空：没有海报就是没有，不编造', () {
    expect(_request().posterUrl, isNull);
  });

  test('copyWith 换集保留海报：否则选集卡片又退回灰块', () {
    const poster = 'https://img.test/poster.jpg';
    final next = _request(posterUrl: poster).copyWith(
      episodeName: '第2集',
      episodeTarget: 'https://site.test/2',
      episodeIndex: 1,
      flag: '线路二',
    );
    expect(next.posterUrl, poster);
    expect(next.episodeIndex, 1);
    expect(next.flag, '线路二');
  });
}
