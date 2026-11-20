/// 追剧页共享 TMDB 数据（`FollowingAirData`）的取值口径。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/following_calendar.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_air_time_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_air_data.dart';

import 'support/detail_test_seams.dart';

class _AirOnlyState extends AppState {
  _AirOnlyState(Directory temp)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}${Platform.pathSeparator}config',
            'data': '${temp.path}${Platform.pathSeparator}data',
            'cache': '${temp.path}${Platform.pathSeparator}cache',
            'state': '${temp.path}${Platform.pathSeparator}logs',
          },
        ),
        log: MemoryOnlyLogService(),
      );

  int networkCalls = 0;
  int airCalls = 0;

  @override
  Future<Map<String, List<String>>> followingNetworksFor(
    List<Following> items,
  ) async {
    networkCalls++;
    return const {};
  }

  @override
  Future<List<FollowingAirTime>> followingAirTimes() async {
    airCalls++;
    return const [];
  }

  @override
  Future<List<FollowingSeasonTotal>> followingSeasonTotals() async => const [];
}

void main() {
  late Directory temp;
  late AppState state;
  late FollowingAirData data;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-air-data');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}${Platform.pathSeparator}config',
          'data': '${temp.path}${Platform.pathSeparator}data',
          'cache': '${temp.path}${Platform.pathSeparator}cache',
          'state': '${temp.path}${Platform.pathSeparator}logs',
        },
      ),
      log: LogService(),
    );
    data = FollowingAirData(state: state);
  });

  tearDown(() {
    data.dispose();
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  final identity = followingIdentityKey('s|v1', 0);
  int at(int month, int day, [int hour = 20]) =>
      DateTime(2026, month, day, hour).millisecondsSinceEpoch;

  test('只要播出时间时跳过平台名，且第二次刷新不再重复取数', () async {
    final only = _AirOnlyState(temp);
    final onlyData = FollowingAirData(state: only);
    addTearDown(() {
      onlyData.dispose();
      only.dispose();
    });
    final item = Following(
      seriesKey: 's|v1',
      season: 0,
      siteKey: 's',
      vodId: 'v1',
      vodName: '测试剧',
    );
    await onlyData.refresh([item], includeNetworks: false);
    expect(only.networkCalls, 0);
    expect(only.airCalls, 1);
    await onlyData.refresh([item], includeNetworks: false);
    expect(only.airCalls, 1);
  });

  test('下一集：取「不早于现在」的最早一集，落到自然日', () {
    data.airTimes = [
      FollowingAirTime(
        seriesKey: 's|v1',
        season: 0,
        episode: 5,
        airAtMs: at(11, 11),
      ),
      FollowingAirTime(
        seriesKey: 's|v1',
        season: 0,
        episode: 6,
        airAtMs: at(11, 18),
      ),
      FollowingAirTime(
        seriesKey: 's|v1',
        season: 0,
        episode: 7,
        airAtMs: at(11, 25),
      ),
    ];
    final morning = DateTime(2026, 11, 18, 10).millisecondsSinceEpoch;
    expect(data.nextAirDate(identity, nowMs: morning), DateTime(2026, 11, 18));
    // 今天这集已经播完 → 顺延到下一集。
    final night = DateTime(2026, 11, 18, 21).millisecondsSinceEpoch;
    expect(data.nextAirDate(identity, nowMs: night), DateTime(2026, 11, 25));
    // 别的剧不串线；集数全播完时没有「下一集」。
    expect(
      data.nextAirDate(followingIdentityKey('s|v2', 0), nowMs: morning),
      isNull,
    );
    expect(data.nextAirDate(identity, nowMs: at(12, 31)), isNull);
  });

  test('列表摘要：官方集数与本线路相同时不重复显示', () {
    data.seasonTotals = [
      const FollowingSeasonTotal(
        seriesKey: 's|v1',
        season: 0,
        totalEpisodes: 24,
      ),
    ];
    final item = Following(
      seriesKey: 's|v1',
      season: 0,
      siteKey: 's',
      vodId: 'v1',
      vodName: '测试剧',
      flag: '线路一',
      trackedSeason: 0,
      latestReleasedSeason: 0,
      latestReleasedEpisode: 24,
      seasonReleasedEpisodes: 24,
      status: FollowingStatus.returning,
      createdAtMs: 1,
      updatedAtMs: 1,
    );
    // 官方总集数永远可见：线路与官方一致时只报一个数（不重复）。
    expect(data.episodeLabelFor(item), '官方共 24 集');
    // 线路滞后/断更：官方 24 是唯一真实口径，线路集数作为偏差补一句。
    expect(
      data.episodeLabelFor(item.copyWith(latestReleasedEpisode: 18)),
      '本线路可播 18 集 · 官方共 24 集',
    );
    // 官方未知（未配置 TMDB / 未匹配）：返回空串，卡片退回本线路可播集数。
    data.seasonTotals = const [];
    expect(data.episodeLabelFor(item), isEmpty);
    // 「下一集」只报排期，不再重复集数。
    expect(data.airSummaryFor(item, nowMs: 0), isEmpty);
  });

  test('官方总集数：只在该季有数据时才有值', () {
    data.seasonTotals = [
      const FollowingSeasonTotal(
        seriesKey: 's|v1',
        season: 0,
        totalEpisodes: 12,
      ),
    ];
    expect(data.officialTotal(identity), 12);
    expect(data.officialTotal(followingIdentityKey('s|v1', 1)), 0);
  });
}
