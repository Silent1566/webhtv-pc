/// V3 真机验证用的最小服务端（`docs/phase7/design/02` §6.3 / `design/04` §7）。
///
/// **为什么单独写一个而不是跑整个 PC app**：
/// V3 要回答的问题是「安卓的『远端同步源』指向 PC 的 `/api/playback/sync`
/// 能不能真的拉到增量」。这只需要 `SyncServer` 本身——它已经是
/// `lib/services/sync_server.dart` 里的真实实现（与 app 内跑的是同一份代码、
/// 同一条路由、同一套鉴权），差别只是宿主 I/O 由本脚本提供。
///
/// 跑整个 PC app 反而更难判读：窗口、播放器、爬虫进程都会干扰日志。
///
/// 用法：
///   `puro -e webhtv -p . dart run tool/v3_host.dart --port 19990 --token v3secret`
///
/// 它会：
/// 1. 起真实 `SyncServer`（回环 + 指定端口）；
/// 2. 打印可直接粘进安卓「远端同步源」的 URL；
/// 3. 每收到一次 `/api/playback/sync` 就打印一行证据；
/// 4. Ctrl+C 退出。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/playback_identity.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_server.dart';

/// 宿主侧「本地历史」：V3 只需要能证明「PC 有新记录时安卓能拉到」。
///
/// 用固定两条而不是空数组：空数组会让 `items` 为空，**无法区分**
/// 「端点通了但没有数据」与「端点根本没被调用」——那正是 P5 禁止的伪装。
final _history = <SyncHistoryItem>[
  SyncHistoryItem(
    siteKey: 'v3_site',
    vodId: '/v3/demo-1',
    vodName: 'V3 实测剧集',
    flag: '线路一',
    episodeName: '第01集',
    episodeId: 'v3-ep-1',
    positionMs: 600000,
    durationMs: 2700000,
    // 固定时间戳：让 `nextSince` 可读、可对账。
    updatedAt: DateTime.now().millisecondsSinceEpoch - 60000,
  ),
  SyncHistoryItem(
    siteKey: 'v3_site',
    vodId: '/v3/demo-2',
    vodName: 'V3 实测剧集二',
    flag: '线路一',
    episodeName: '第02集',
    episodeId: 'v3-ep-2',
    positionMs: 1200000,
    durationMs: 2700000,
    updatedAt: DateTime.now().millisecondsSinceEpoch - 30000,
  ),
];

Future<void> main(List<String> args) async {
  var port = 19990;
  var token = 'v3secret';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--port') port = int.tryParse(args[i + 1]) ?? port;
    if (args[i] == '--token') token = args[i + 1];
  }

  final log = LogService();
  final identity = PlaybackIdentityStore();

  var pullCalls = 0;

  final host = SyncServerHost(
    deviceUuid: 'v3-pc-uuid',
    deviceName: 'WebHTV PC (V3 实测)',
    isEnabled: () => true,
    // V3 的鉴权走 token（安卓侧填同一个），因此白名单一律放行。
    isPeerAuthorized: (_) => true,
    onHistory: (_, {String sourceKey = ''}) async =>
        const SyncMergeStats.empty(),
    onKeep: (_) async => const SyncMergeStats.empty(),
    onBackup: (_, _) async => const SyncSettings.empty(),
    realtimePull: ({required int since, required int limit}) {
      pullCalls++;
      final batch = buildSyncPullBatch(
        history: _history,
        deletions: const [],
        since: since,
        limit: limit,
      );
      // 每次被拉都打印一行，作为「安卓真的打过来了」的现场证据。
      stdout.writeln(
        'V3-EVIDENCE pull call=$pullCalls since=$since limit=$limit '
        '-> ${batch.describe()}',
      );
      return batch;
    },
    pullToken: token,
    playbackIdentity: identity,
    playbackCounts: () => (
      items: _history.length,
      tombstones: 0,
      nextSince: _history.last.updatedAt,
    ),
  );

  final server = SyncServer(
    log: log,
    host: host,
    bindAddress: '0.0.0.0',
  );
  final actualPort = await server.start();

  // 打印 PC 的局域网地址：安卓侧要填这个。
  final lanIps = <String>[];
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) lanIps.add('${interface.name}=${address.address}');
    }
  }

  stdout
    ..writeln('V3-EVIDENCE server started port=$actualPort')
    ..writeln('V3-EVIDENCE lan interfaces: ${lanIps.join(', ')}')
    ..writeln('')
    ..writeln('安卓「远端同步源」填：')
    ..writeln('  URL   = http://<PC-IP>:$actualPort/api/playback/sync')
    ..writeln('  Token = $token')
    ..writeln('  （模拟器 NAT 场景用 adb reverse tcp:$actualPort tcp:$actualPort，')
    ..writeln('    然后 URL 填 http://127.0.0.1:$actualPort/api/playback/sync）')
    ..writeln('')
    ..writeln('本地自检：')
    ..writeln('  curl "http://127.0.0.1:$actualPort/api/playback/sync?since=0" \\')
    ..writeln('       -H "X-WebHTV-Token: $token"')
    ..writeln('')
    ..writeln('等待安卓来拉... (Ctrl+C 退出)');

  // 保持进程存活，直到被中断。
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });
  await done.future;

  await server.stop();
  stdout.writeln('V3-EVIDENCE server stopped pullCalls=$pullCalls');
}

/// 让 `jsonEncode` 的 import 被用到（保留以便排障时打印原始响应）。
// ignore: unused_element
String _debugJson(Object? value) => jsonEncode(value);
