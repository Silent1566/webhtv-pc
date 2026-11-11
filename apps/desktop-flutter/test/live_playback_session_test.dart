import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/live_catchup.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/live_service.dart';
import 'package:webhtv_pc/services/epg_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/live_playback_session.dart';

class FixtureLiveService extends LiveService {
  final loads = <String, Future<LivePlaylist> Function()>{};
  @override
  Future<LiveLoadResult> load(
    LiveSource source, {
    bool useCache = true,
  }) async => LiveLoadResult(
    playlist: await loads[source.name]!(),
    source: source,
    latency: Duration.zero,
  );
}

class FixtureState extends AppState {
  FixtureState({
    required super.paths,
    required super.log,
    required super.liveService,
    super.epgService,
  });
  List<LiveSource> sources = [];
  @override
  List<LiveSource> get liveSources => sources;
}

({FixtureState state, FixtureLiveService service, LivePlaybackSession session})
fixture({
  EpgProgram? initialProgram,
  EpgGuide? guide,
  EpgService? epgService,
  String? sourceEpg,
}) {
  final temp = Directory.systemTemp.createTempSync('live-session');
  final service = FixtureLiveService();
  final state = FixtureState(
    paths: AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    ),
    log: LogService(),
    liveService: service,
    epgService: epgService,
  );
  final source = LiveSource(
    name: '源一',
    type: 1,
    url: 'https://fixture.test/source1',
    epg: sourceEpg,
  );
  final channel = LiveChannel(
    name: 'CCTV-5',
    group: '一组',
    urls: ['https://fixture.test/a', 'https://fixture.test/b'],
    header: HeaderMap({
      'User-Agent': 'channel-agent',
      'Referer': 'https://fixture.test/',
    }),
    catchup: const CatchupSpec(type: 'append', source: '?start=\${utc:}'),
  );
  final playlist = LivePlaylist(
    sourceName: '源一',
    groups: [
      LiveGroup(name: '一组', channels: [channel]),
      LiveGroup(name: '空组'),
      LiveGroup(
        name: '二组',
        channels: [
          LiveChannel(name: '空台'),
          LiveChannel(
            name: '频道二',
            urls: ['https://fixture.test/c'],
            header: HeaderMap({'User-Agent': 'second-agent'}),
          ),
        ],
      ),
    ],
  );
  final session = LivePlaybackSession(
    state: state,
    source: source,
    playlist: playlist,
    channel: channel,
    lineIndex: 1,
    initialProgram: initialProgram,
    guide: guide,
  );
  state.sources = [source];
  addTearDown(() {
    session.dispose();
    state.dispose();
    service.close();
    temp.deleteSync(recursive: true);
  });
  return (state: state, service: service, session: session);
}

class PendingEpgService extends EpgService {
  PendingEpgService() : super(cacheDir: Directory.systemTemp.path);
  final gate = Completer<EpgLoadResult>();
  @override
  Future<EpgLoadResult> load({
    required String url,
    List<LiveChannel> liveChannels = const [],
    String sourceName = '',
    bool forceRefresh = false,
  }) => gate.future;
}

void main() {
  test('初始会话生成频道请求并保留Header和线路下标', () {
    final session = fixture().session;
    expect(session.request.url, 'https://fixture.test/b');
    expect(session.request.headers, {
      'User-Agent': 'channel-agent',
      'Referer': 'https://fixture.test/',
    });
    expect(session.request.title, 'CCTV-5');
    expect(session.request.episodeIndex, 1);
    expect(session.request.playLines.single.episodes.length, 2);
  });
  test('快速选源只浏览，迟到的旧清单不能覆盖新源', () async {
    final f = fixture();
    final a = LiveSource(name: '慢源', type: 1);
    final b = LiveSource(name: '快源', type: 1);
    final gate = Completer<LivePlaylist>();
    f.service.loads[a.name] = () => gate.future;
    f.service.loads[b.name] = () async => LivePlaylist(sourceName: b.name);
    final pending = f.session.browse(a);
    await f.session.browse(b);
    gate.complete(LivePlaylist(sourceName: a.name));
    await pending;
    expect(f.session.browseSource.name, '快源');
    expect(f.session.browsePlaylist!.sourceName, '快源');
    expect(f.session.source.name, '源一');
    expect(f.session.request.url, 'https://fixture.test/b');
  });
  test('源失败可重试且不影响正在播放', () async {
    final f = fixture();
    final source = LiveSource(name: '重试源', type: 1);
    f.service.loads[source.name] = () async => throw StateError('失败');
    await f.session.browse(source);
    expect(f.session.browseError, isNotNull);
    f.service.loads[source.name] = () async => LivePlaylist(sourceName: '重试源');
    await f.session.retryBrowse();
    expect(f.session.browseError, isNull);
    expect(f.session.source.name, '源一');
  });
  test('跨分组切台重建标题Header和线路，不把空频道当节目', () {
    final session = fixture().session;
    expect(session.stepChannel(1), isTrue);
    expect(session.request.title, '频道二');
    expect(session.request.headers, {'User-Agent': 'second-agent'});
    expect(session.request.episodeIndex, 0);
    expect(
      session.request.playLines.single.episodes.single.url,
      'https://fixture.test/c',
    );
    expect(session.channel.name, 'CCTV-5', reason: '请求尚未成功不得改最后播放态');
    session.confirmPlayback(session.playbackRevision);
    expect(session.channel.name, '频道二');
    expect(session.stepChannel(-1), isTrue);
    session.confirmPlayback(session.playbackRevision);
    expect(session.channel.name, 'CCTV-5');
    expect(session.selectChannel(LiveChannel(name: '空台')), isFalse);
    expect(session.selectLine(99), isFalse);
  });
  test('过期加载确认不会覆盖后续频道或线路选择', () {
    final session = fixture().session;
    session.stepChannel(1);
    final old = session.playbackRevision;
    session.selectLine(0);
    session.confirmPlayback(old);
    expect(session.channel.name, 'CCTV-5');
    session.confirmPlayback(session.playbackRevision);
    expect(session.lineIndex, 0);
    expect(session.request.url, 'https://fixture.test/a');
  });
  test('单线路耗尽可跨源，精确匹配不误选CCTV5+且不循环', () async {
    final f = fixture();
    final source2 = LiveSource(name: '源二', type: 1);
    f.state.sources = [...f.state.sources, source2];
    f.service.loads[source2.name] = () async => LivePlaylist(
      sourceName: '源二',
      groups: [
        LiveGroup(
          name: '体育',
          channels: [
            LiveChannel(name: 'CCTV5+', urls: ['https://fixture.test/wrong']),
            LiveChannel(
              name: 'CCTV5 HD',
              urls: ['https://fixture.test/fallback'],
              header: HeaderMap({'Referer': 'https://fallback.test/'}),
            ),
          ],
        ),
      ],
    );
    expect(
      await f.session.fallback(changeLine: true, sourceFallback: true),
      isTrue,
    );
    expect(f.session.request.url, 'https://fixture.test/fallback');
    expect(f.session.request.headers, {'Referer': 'https://fallback.test/'});
    f.session.confirmPlayback(f.session.playbackRevision);
    expect(f.session.source.name, '源二');
    expect(f.session.channel.name, 'CCTV5 HD');
    expect(f.session.browseSource.name, '源二');
    expect(f.session.browseGroup, '体育');
    expect(
      await f.session.fallback(changeLine: true, sourceFallback: true),
      isFalse,
    );
  });
  test('回退开关独立保留且旧跨源加载不会覆盖新手动选择', () async {
    final f = fixture();
    expect(
      await f.session.fallback(changeLine: false, sourceFallback: true),
      isFalse,
    );
    expect(
      await f.session.fallback(changeLine: true, sourceFallback: false),
      isFalse,
    );
    final source2 = LiveSource(name: '源二', type: 1);
    f.state.sources = [...f.state.sources, source2];
    final gate = Completer<LivePlaylist>();
    f.service.loads[source2.name] = () => gate.future;
    final pending = f.session.fallback(changeLine: true, sourceFallback: true);
    f.session.stepChannel(1);
    gate.complete(
      LivePlaylist(
        sourceName: '源二',
        groups: [
          LiveGroup(
            name: '体育',
            channels: [
              LiveChannel(name: 'CCTV5', urls: ['https://fixture.test/late']),
            ],
          ),
        ],
      ),
    );
    expect(await pending, isFalse);
    expect(f.session.request.title, '频道二');
  });
  test('回看只有已结束节目可选，回直播恢复频道线路Header', () {
    final session = fixture().session;
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = EpgProgram(
      title: '当前',
      startMs: now - 1000,
      stopMs: now + 1000,
    );
    final ended = EpgProgram(
      title: '已结束',
      startMs: 1700000000000,
      stopMs: 1700003600000,
    );
    expect(session.watchProgram(current), isFalse);
    expect(session.watchProgram(ended), isTrue);
    expect(session.request.url, 'https://fixture.test/b?start=1700000000');
    expect(session.request.flag, '回看');
    expect(session.requestProgram, ended);
    session.confirmPlayback(session.playbackRevision);
    expect(session.program, ended);
    expect(session.returnToLive(), isTrue);
    expect(session.requestProgram, isNull);
    expect(session.request.url, 'https://fixture.test/b');
    expect(session.request.episodeIndex, 1);
    expect(session.request.headers['User-Agent'], 'channel-agent');
  });
  test('初始回看模式生成回看请求而非直播', () {
    final session = fixture(
      initialProgram: const EpgProgram(
        title: '旧节目',
        startMs: 1700000000000,
        stopMs: 1700003600000,
      ),
    ).session;
    expect(session.request.flag, '回看');
    expect(session.request.title, 'CCTV-5 · 旧节目');
  });
  test('初值及重开浏览定位频道所属分组而非首组', () async {
    final f = fixture();
    final second = f.session.playlist.allChannels.last;
    final session = LivePlaybackSession(
      state: f.state,
      source: f.session.source,
      playlist: f.session.playlist,
      channel: second,
    );
    addTearDown(session.dispose);
    expect(session.browseGroup, '二组');
    session.selectGroup('一组');
    await session.browse(session.source);
    expect(session.browseGroup, '二组');
  });
  test('旧源EPG在途切到无EPG源，加载标记复位且迟到结果丢弃', () async {
    final epg = PendingEpgService();
    addTearDown(epg.close);
    final f = fixture(
      epgService: epg,
      sourceEpg: 'https://fixture.test/epg.xml',
    );
    final pending = f.session.loadGuide();
    expect(f.session.guideLoading, isTrue);
    final other = LiveSource(name: '无EPG', type: 1);
    f.service.loads[other.name] = () async => LivePlaylist(
      sourceName: other.name,
      groups: [
        LiveGroup(
          name: '其它',
          channels: [
            LiveChannel(name: '其它台', urls: ['https://fixture.test/no-epg']),
          ],
        ),
      ],
    );
    await f.session.browse(other);
    f.session.selectChannel(f.session.browsePlaylist!.allChannels.single);
    f.session.confirmPlayback(f.session.playbackRevision);
    expect(f.session.guideLoading, isFalse);
    epg.gate.complete(
      const EpgLoadResult(
        guide: EpgGuide.empty,
        url: 'https://fixture.test/epg.xml',
        fromCache: false,
        latency: Duration.zero,
      ),
    );
    await pending;
    expect(f.session.guide, isNull);
    expect(f.session.guideLoading, isFalse);
  });
  test('连按切台依据待播放请求推进和撤回，getter仍保留成功频道', () {
    final session = fixture().session;
    session.stepChannel(1);
    expect(session.request.title, '频道二');
    session.stepChannel(1);
    expect(session.request.title, 'CCTV-5');
    expect(session.channel.name, 'CCTV-5');
    session.stepChannel(1);
    session.stepChannel(-1);
    expect(session.request.title, 'CCTV-5');
    expect(session.channel.name, 'CCTV-5');
  });
  test('跨源频道待确认时相对切台仍用新源清单，成功态保持旧源', () async {
    final f = fixture();
    final other = LiveSource(name: '另一个源', type: 1);
    final first = LiveChannel(
      name: '新源一台',
      urls: ['https://fixture.test/new1'],
    );
    final second = LiveChannel(
      name: '新源二台',
      urls: ['https://fixture.test/new2'],
      header: HeaderMap({'Referer': 'https://new-source.test/'}),
    );
    f.service.loads[other.name] = () async => LivePlaylist(
      sourceName: other.name,
      groups: [
        LiveGroup(name: '新组', channels: [first, second]),
      ],
    );
    await f.session.browse(other);
    f.session.selectChannel(first);
    final stale = f.session.playbackRevision;
    f.session.stepChannel(1);
    expect(f.session.request.url, 'https://fixture.test/new2');
    expect(f.session.request.headers, {'Referer': 'https://new-source.test/'});
    expect(f.session.source.name, '源一');
    f.session.confirmPlayback(stale);
    expect(f.session.source.name, '源一');
    f.session.confirmPlayback(f.session.playbackRevision);
    expect(f.session.source.name, '另一个源');
    expect(f.session.channel.name, '新源二台');
  });
}
