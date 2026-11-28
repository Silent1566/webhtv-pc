/// 去广告归因：播放上下文（片名/线路/分集）必须能到达代理记账。
///
/// 为什么单独锁这一层：清洗与统计各自都有用例，但「这一条拦截属于哪一集」
/// 只由这里的映射决定。映射错了不会报错，只会让统计页安静地显示错误的归属。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/playback_request.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

PlaybackRequest request() => PlaybackRequest(
  url: 'https://media.test/ep2.m3u8',
  title: '示例剧',
  siteKey: 'demo',
  vodId: '42',
  vodName: '示例剧',
  episodeName: '第 2 集',
  flag: '线路一',
  playLines: [
    VodPlayLine(
      flag: '线路一',
      episodes: [
        VodEpisode(name: '第 1 集', url: 'https://media.test/ep1.m3u8'),
        VodEpisode(name: '第 2 集', url: 'https://media.test/ep2.m3u8'),
      ],
    ),
    VodPlayLine(
      flag: '线路二',
      episodes: [
        VodEpisode(name: '第 1 集(二线)', url: 'https://cdn2.test/ep1.m3u8'),
      ],
    ),
  ],
);

void main() {
  group('从播放请求解析归因标签', () {
    test('片名取 vodName；线路与分集按 flag + 目标地址解析', () {
      final labels = request().adBlockLabelsFor(
        episodeTarget: 'https://media.test/ep2.m3u8',
        flag: '线路一',
      );
      expect(labels.vodName, '示例剧');
      expect(labels.lineName, '线路一');
      expect(labels.episodeName, '第 2 集');
    });

    test('换了线路就报那一路的线路名与它自己的分集名', () {
      final labels = request().adBlockLabelsFor(
        episodeTarget: 'https://cdn2.test/ep1.m3u8',
        flag: '线路二',
      );
      expect(labels.lineName, '线路二');
      expect(labels.episodeName, '第 1 集(二线)');
    });

    test('目录记录这类没有线路表的请求只报片名，不猜线路与分集', () {
      final labels = request().adBlockLabelsFor(
        episodeTarget: 'https://media.test/other.m3u8',
        flag: '线路一',
      );
      expect(labels.vodName, '示例剧');
      expect(labels.episodeName, '', reason: '目标地址不在线路表里就不能套用别的集名');
    });

    test('未知线路只报片名', () {
      final labels = request().adBlockLabelsFor(
        episodeTarget: 'https://media.test/ep2.m3u8',
        flag: '线路九',
      );
      expect(labels.lineName, '');
      expect(labels.episodeName, '');
    });
  });

  group('AppState 把标签交给代理侧记账上下文', () {
    late Directory temp;
    late AppState state;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-ad-attribution');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': p.join(temp.path, 'config'),
            'data': p.join(temp.path, 'data'),
            'cache': p.join(temp.path, 'cache'),
            'state': p.join(temp.path, 'logs'),
          },
        ),
        log: LogService(),
      );
    });

    tearDown(() {
      state.dispose();
      temp.deleteSync(recursive: true);
    });

    test('未登记时为空白，登记后三个字段都带进上下文', () {
      expect(state.debugAdBlockContext().vodName, '');
      state.noteAdBlockPlayback(const (
        vodName: '示例剧',
        lineName: '线路一',
        episodeName: '第 2 集',
      ));
      final context = state.debugAdBlockContext();
      expect(context.vodName, '示例剧');
      expect(context.lineName, '线路一');
      expect(context.episodeName, '第 2 集');
      expect(context.pipeline, 'HLS');
    });

    test('撤销代理会话后归因清零，下一集不会继承上一集的名字', () {
      state.noteAdBlockPlayback(const (
        vodName: '示例剧',
        lineName: '线路一',
        episodeName: '第 2 集',
      ));
      state.revokeProxySession();
      final context = state.debugAdBlockContext();
      expect(context.vodName, '');
      expect(context.lineName, '');
      expect(context.episodeName, '');
    });
  });
}
