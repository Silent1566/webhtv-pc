/// PC 侧同步服务端（`docs/phase5/design/02` §4）。
///
/// 为什么必须有这个服务端：Android **没有"拉取历史"的接口**（`design/00` §3.5），
/// 只有"被推"与"主动推"两种能力。PC 要让用户能"拉"，只能自己实现
/// `GET /device` 与 `POST /action?do=sync`，让 Android 主动推过来。
///
/// 路径必须与 Android 完全一致（`Action.isRequest` 的判据是
/// `url.startsWith("/action")`，`ScanTask` 打的是 `/device`），因此**不能**
/// 复用 `LocalProxyServer` —— 后者硬性只允许回环且路径空间是 `/p/<token>/…`。
///
/// 硬约束：
/// - **默认关闭**（P3）：只在用户显式开启后才监听；
/// - 绑定 `0.0.0.0`，端口从 9978 顺序探测到 9998（与 Android 同策略）；
/// - 单请求串行（同步是低频操作）；
/// - 请求体上限 8 MiB，读取超时 30 s；
/// - 失败必须带明确状态码与 message（P5）：403/400/413 不得折叠成"同步成功"；
/// - 日志不含片名、不含 `config` JSON、设备 uuid 只留前 4 位（§7）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../core/android_bridge.dart';
import '../core/android_sync.dart';
import '../core/app_error.dart';
import '../core/playback_identity.dart';
import '../core/protocol.dart';
import '../core/realtime_sync.dart';
import 'log_service.dart';

/// 服务端能对外提供的信息与能力（由状态层注入，服务端不直接碰 `AppState`）。
class SyncServerHost {
  const SyncServerHost({
    required this.deviceUuid,
    required this.deviceName,
    required this.isEnabled,
    required this.isPeerAuthorized,
    required this.onHistory,
    required this.onKeep,
    required this.onBackup,
    this.onPullRequest,
    this.realtimePull,
    this.pullToken,
    this.playbackIdentity,
    this.playbackCounts,
  });

  /// PC 的稳定 uuid（首次启动生成并持久化，`design/02` §8 Q5）。
  ///
  /// 必须持久化：否则每次重启 Android 都会把它当成一台新设备。
  final String deviceUuid;
  final String deviceName;

  /// 同步是否已开启（P3）。返回 `false` 时任何 `/action` 请求都 `403`。
  final bool Function() isEnabled;

  /// 对端是否在 uuid 白名单内（§5）。未授权一律 `403`。
  final bool Function(String peerUuid) isPeerAuthorized;

  /// 应用一批历史，返回明细统计。
  ///
  /// [sourceKey] 来自载荷里的 `configKey`（安卓推给我们的那一源的标识）：
  /// 非空时只把记录写进该源、且不污染别的源；空串表示老安卓没给标识。
  final Future<SyncMergeStats> Function(
    SyncHistoryParseResult parsed, {
    String sourceKey,
  })
  onHistory;

  /// 应用一批收藏。
  final Future<SyncMergeStats> Function(SyncFavoriteParseResult parsed)
  onKeep;

  /// 应用设置备份（白名单子集）。
  final Future<SyncSettings> Function(Object? backup, bool allowSensitive)
  onBackup;

  /// 对端要求 PC 主动推给它（`mode=2` + `device`）时调用。
  final Future<void> Function(String deviceJson)? onPullRequest;

  /// 路径 B：按游标取一批变更（`design/01` §3.2.2）。
  ///
  /// 返回 `null` 表示「实时推送」未开启 → 端点回 403（P1）。
  /// 由状态层实现（它才能读本地历史与删除墓碑）。
  final SyncPullProvider? realtimePull;

  /// 路径 B 的可选 token（`design/01` §3.2.2）。
  ///
  /// 为空时只允许 `uuid` 白名单内的对端（局域网默认形态）。
  final String? pullToken;

  /// 身份解析注册表（`design/01` §3.2.1）。
  ///
  /// 为 `null` 时 `/api/playback/identity/resolve` 回 **404**——安卓据此进入
  /// `unsupported` 旧服务端兼容模式（跨设备身份匹配永久失效）。
  final PlaybackIdentityStore? playbackIdentity;

  /// `sync/status` 要报的本地计数（`design/01` §3.2.1）。
  ///
  /// 必须由状态层提供：只有它知道历史库与删除墓碑。
  final SyncPlaybackCounts Function()? playbackCounts;
}

/// `sync/status` 的本机计数。
typedef SyncPlaybackCounts = ({int items, int tombstones, int nextSince});

/// 路径 B 的取数回调签名。
///
/// [since] 是安卓给的游标（`0` = 空游标 / 首次同步）；
/// [limit] 已由服务端夹到合法区间。
typedef SyncPullProvider =
    SyncPullBatch Function({required int since, required int limit});

/// 一次请求的处理结果（供测试直接断言状态码与 message）。
class SyncResponse {
  const SyncResponse(this.statusCode, this.body, {this.isJson = false});

  const SyncResponse.ok(String detail)
    : statusCode = 200,
      body = 'OK $detail',
      isJson = false;

  final int statusCode;
  final String body;

  /// 是否以 `application/json` 返回（路径 B 的响应体是 JSON）。
  final bool isJson;

  bool get isOk => statusCode == 200;

  @override
  String toString() => '$statusCode $body';
}

/// PC 侧同步服务端。
class SyncServer {
  SyncServer({
    required this.log,
    required this.host,
    this.requestTimeout = const Duration(seconds: 30),
    this.startPort = androidDefaultPort,
    this.endPort = androidPortRangeEnd,
    this.bindAddress = '0.0.0.0',
    this.lanIpOverride,
  });

  final LogService log;
  final SyncServerHost host;
  final Duration requestTimeout;
  final int startPort;
  final int endPort;
  final String bindAddress;
  final String? lanIpOverride;

  /// 绑定地址的展示文案（供 UI 在开启前告知用户监听范围）。
  String get bindAddressHint => bindAddress;

  HttpServer? _server;

  /// 串行化请求处理（`design/02` §4.3）。
  Future<void> _queue = Future.value();

  bool get isRunning => _server != null;

  int get port => _server?.port ?? 0;

  /// 供 Android 访问的基址（局域网 IP + 实际端口）。
  String get baseUrl => 'http://${lanIp ?? '0.0.0.0'}:$port';

  /// 选中的局域网 IP（多网卡时取第一个非回环 IPv4）。
  String? lanIp;

  /// 启动监听（`design/02` §4.1）。
  ///
  /// 端口按 [startPort] → [endPort] 顺序探测，占用第一个可用端口。
  /// 全部被占用时抛 [AppErrorKind.syncPortUnavailable]（而不是静默退到随机端口
  /// —— 用户按记忆填的地址会连不上，必须让他知道）。
  Future<int> start() async {
    final existing = _server;
    if (existing != null) return existing.port;

    lanIp = lanIpOverride ?? await _resolveLanIp();

    Object? lastError;
    for (var candidate = startPort; candidate <= endPort; candidate++) {
      try {
        final server = await HttpServer.bind(bindAddress, candidate)
          ..idleTimeout = requestTimeout;
        _server = server;
        server.listen(
          (request) => _enqueue(request),
          onError: (Object error) =>
              log.warning('同步服务监听出错：$error', scope: 'sync'),
        );
        log.info(
          '同步服务已启动：$baseUrl（uuid ${_maskUuid(host.deviceUuid)}）'
          '—— 同局域网设备可访问，仅接受已授权对端',
          scope: 'sync',
        );
        return candidate;
      } on SocketException catch (error) {
        lastError = error;
        continue;
      }
    }
    log.error('同步服务启动失败：$startPort–$endPort 端口全被占用', scope: 'sync');
    throw AppError(
      AppErrorKind.syncPortUnavailable,
      '同步服务无法启动：$startPort–$endPort 端口全被占用',
      detail: lastError == null ? null : '$lastError',
    );
  }

  /// 停止监听并立即释放端口（§5：关闭后端口立即释放）。
  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
      log.info('同步服务已停止，端口已释放', scope: 'sync');
    }
    // 等待在途请求收尾，避免测试里"停止后端口仍被占用"的假失败。
    try {
      await _queue.timeout(const Duration(seconds: 5));
    } catch (_) {
      // 超时不阻塞关闭。
    }
  }

  // ------------------------------------------------------------------ 路由

  void _enqueue(HttpRequest request) {
    _queue = _queue
        .then((_) => _handle(request))
        .catchError((Object error) {
          log.warning('同步请求处理异常：$error', scope: 'sync');
        });
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    try {
      final response = switch (path) {
        '/device' => _handleDevice(request),
        '/action' => await _handleAction(request),
        // 路径 B（`design/01` §3.2.2）：安卓的「远端同步源」就是客户端定时拉
        // HTTP 端点，PC 暴露这个端点即可获得「安卓侧实时」。
        '/api/playback/sync' || '/playback/sync' => _handleRealtimePull(request),
        // 身份解析与能力声明（`design/01` §3.2.1）。安卓在同步前必打
        // `identity/resolve`，缺它会被**永久**标记为 `unsupported`。
        '/api/playback/sync/status' ||
        '/playback/sync/status' => _handlePlaybackStatus(request),
        '/api/playback/identity/resolve' ||
        '/playback/identity/resolve' => await _handleIdentityResolve(request),
        _ => const SyncResponse(
          404,
          '未知路径（仅支持 /device、/action、/api/playback/sync、'
          '/api/playback/sync/status 与 /api/playback/identity/resolve）',
        ),
      };
      await _write(request, response);
    } catch (error) {
      log.warning('同步请求失败 $path：$error', scope: 'sync');
      await _write(request, SyncResponse(500, '服务端错误：$error'));
    }
  }

  /// `GET /device`：让 Android 能发现 PC（`design/02` §4.2）。
  ///
  /// `type` 写 `1`（Mobile）而不是 `2`（DLNA）：PC 是**应用对端**
  /// （`Device.isApp()` 为真），与"可被同步"的语义一致；写 `2` 会让 Android
  /// 把它当投屏设备。
  SyncResponse _handleDevice(HttpRequest request) {
    final payload = deviceJson();
    return SyncResponse(200, payload);
  }

  /// 本机对外的 `Device` JSON（`GET /device` 与 `mode=2` 的 `device` 参数共用）。
  String deviceJson() => jsonEncode({
    'uuid': host.deviceUuid,
    'name': host.deviceName,
    'ip': baseUrl,
    'type': 1,
    'serial': '',
    'eth': '',
    'wlan': '',
    'time': DateTime.now().millisecondsSinceEpoch,
  });

  /// `POST /action?do=sync&mode=…&type=…`（`design/02` §3.1 / §4.2）。
  Future<SyncResponse> _handleAction(HttpRequest request) async {
    if (request.method != 'POST') {
      return const SyncResponse(405, '仅支持 POST');
    }
    final params = request.uri.queryParameters;
    if (params['do'] != 'sync') {
      return const SyncResponse(
        400,
        '仅支持 do=sync（PC 不实现 file/push/cast 等安卓本机操作）',
      );
    }

    // 先读体（同时施加 8 MiB 上限），再校验——否则校验通过后才发现体超限，
    // 对端已经白传了几十 MB。
    final body = await _readBody(request);
    if (body == null) {
      return SyncResponse(
        413,
        '请求体超过上限 ${syncMaxPayloadBytes ~/ (1024 * 1024)} MiB',
      );
    }

    final parsed = _parseForm(request, body);
    if (parsed == null) {
      return const SyncResponse(
        415,
        '不支持的请求体格式（仅接受 application/x-www-form-urlencoded；'
        'PC 不处理归档文件，请在安卓端关闭 paths/mpvConfig/loginState 同步项）',
      );
    }

    final peerUuid = _peerUuid(parsed.fields, params);
    // 对端身份：优选用它自报的 uuid（`device` JSON 里的 `uuid`），
    // 缺时回退到远端 IP。为什么必须回退：安卓推送历史/收藏的
    // `FormBody` 只带 `config`/`targets`（`Action.sendHistory` 源码），
    // **不带**任何设备标识，只认 uuid 会让该功能永远 403。
    final peerIdentity = peerUuid.isNotEmpty
        ? peerUuid
        : (request.connectionInfo?.remoteAddress.address ?? '');
    final check = validateSyncAction(
      params: params,
      form: parsed.fields,
      enabled: host.isEnabled(),
      peerAuthorized: host.isPeerAuthorized(peerIdentity),
    );
    if (!check.isOk) {
      log.warning(
        '同步请求被拒绝 status=${check.status} type=${params['type']} '
        'mode=${params['mode']} uuid=${_maskUuid(peerUuid)} '
        'reason=${check.message}',
        scope: 'sync',
      );
      return SyncResponse(check.status, check.message ?? '请求被拒绝');
    }

    // `mode` 语义（`Action.onSync` 源码，见 `design/02` §3.2）：
    //   0 = 带 device 则推给 device，**并且**应用请求体载荷
    //   1 = 只应用请求体载荷
    //   2 = 只推送（必须带 device），**不**应用请求体载荷
    final mode = params['mode']!;
    final type = params['type']!;
    final deviceJson = parsed.fields['device'];

    if (mode == '2' && (deviceJson == null || deviceJson.trim().isEmpty)) {
      // 对齐上游 `Manage.syncStart`：缺 device 直接 400 Missing device。
      return const SyncResponse(400, 'mode=2 需要提供 device（缺 device）');
    }

    if (mode == '0' && deviceJson != null && deviceJson.trim().isNotEmpty) {
      await _requestPull(deviceJson);
    }
    if (mode == '2') {
      await _requestPull(deviceJson!);
      return const SyncResponse.ok('mode=2 已请求对端推送（未应用请求体载荷）');
    }

    final stats = switch (type) {
      'history' => await host.onHistory(
        SyncHistoryParseResult.parse(_decode(parsed.fields['targets'])),
        sourceKey: (parsed.fields['configKey'] ?? '').trim(),
      ),
      'keep' => await host.onKeep(
        SyncFavoriteParseResult.parse(_decode(parsed.fields['targets'])),
      ),
      'backup' => await _applyBackup(parsed.fields),
      _ => const SyncMergeStats.empty(),
    };

    log.info(
      '同步完成 type=$type mode=$mode ${stats.describe()} '
      'uuid=${_maskUuid(peerUuid)}',
      scope: 'sync',
    );

    // 明细必须回传（P5）：`applied+skipped+failed` 不闭合时说明实现有缺陷，
    // 明确标出来而不是让对端以为"全部成功"。
    final suffix = stats.isConsistent ? '' : ' INCONSISTENT';
    return SyncResponse.ok('${stats.describe()}$suffix');
  }

  Future<SyncMergeStats> _applyBackup(Map<String, String> fields) async {
    final allowSensitive = fields['allowSensitive'] == 'true';
    final backup = _decode(fields['backup']);
    final settings = await host.onBackup(backup, allowSensitive);
    log.info(
      '同步设置 ${settings.describe()}（白名单子集，凭据默认排除）',
      scope: 'sync',
    );
    return SyncMergeStats(
      applied: settings.values.length,
      skipped: settings.skippedKeys.length,
      failed: 0,
      total: settings.values.length + settings.skippedKeys.length,
    );
  }

  Future<void> _requestPull(String deviceJson) async {
    final callback = host.onPullRequest;
    if (callback == null) return;
    await callback(deviceJson);
  }

  /// `GET /api/playback/sync?since=&limit=`（`design/01` §3.2.2）。
  ///
  /// 安卓的「远端同步源」会带这些头：
  /// `X-WebHTV-Config-Key` / `X-WebHTV-Config-Aliases` / `X-WebHTV-Since` /
  /// `X-WebHTV-Limit` / `X-WebHTV-Token`。
  /// 同时接受 query 参数（`since`/`limit`）——安卓两种都可能用。
  ///
  /// **不推进任何本地游标**：游标由安卓侧保存（`RemoteSyncConfig.cursors`）。
  SyncResponse _handleRealtimePull(HttpRequest request) {
    if (request.method != 'GET') {
      return const SyncResponse(405, '仅支持 GET');
    }
    final provider = host.realtimePull;
    final query = request.uri.queryParameters;
    final headerSince = request.headers.value('x-webhtv-since');
    final headerLimit = request.headers.value('x-webhtv-limit');
    final headerToken = request.headers.value('x-webhtv-token');

    // 游标：非法值必须 400（对齐 Go 参考实现），不得回落 0——
    // 回落会让安卓把全部历史再拉一遍（数据不错但用户看到一次莫名全量）。
    //
    // **header 优先于 query**：安卓 `PlaybackRemoteSyncer` 发的是 header，
    // query 只是给手动调试/第三方服务端的便利形式；
    // 两者都给时以客户端真实协议为准。
    final rawSince = headerSince ?? query['since'];
    final since = parseSyncCursor(rawSince);
    if (since == null) {
      return SyncResponse(
        400,
        'Invalid X-WebHTV-Since cursor（收到 ${rawSince ?? '(空)'}）',
      );
    }
    final limit = parseSyncLimit(headerLimit ?? query['limit']);

    final peerAddress = request.connectionInfo?.remoteAddress.address ?? '';
    final auth = validateSyncPullAuth(
      pushEnabled: host.isEnabled() && provider != null,
      configuredToken: host.pullToken,
      providedToken: headerToken,
      peerAuthorized: host.isPeerAuthorized(peerAddress),
    );
    if (!auth.allowed) {
      log.warning(
        '实时拉取被拒绝 status=${auth.status} since=$since '
        'peer=${_maskAddress(peerAddress)} reason=${auth.message}',
        scope: 'realtime',
      );
      return SyncResponse(auth.status, auth.message ?? '请求被拒绝');
    }

    final batch = provider!(since: since, limit: limit);
    log.info(
      '实时拉取响应 ${batch.describe()} peer=${_maskAddress(peerAddress)}',
      scope: 'realtime',
    );
    return SyncResponse(200, jsonEncode(batch.toJson()), isJson: true);
  }

  /// `POST /api/playback/identity/resolve`（`design/01` §3.2.1）。
  ///
  /// 安卓同步前必打这个端点（`PlaybackIdentityResolver.resolve()`）。
  /// 响应 404/405/501 会被它写成 **永久的** `unsupported`，所以未接线时
  /// 我们宁可回 404 也不回 200 假成功。
  ///
  /// **不要求「向安卓推送」已开启**：本端点只返回身份键（不返回任何播放
  /// 数据），拒绝它反而会制造上面那个永久后遗症。
  Future<SyncResponse> _handleIdentityResolve(HttpRequest request) async {
    if (request.method != 'POST') {
      return const SyncResponse(405, '仅支持 POST');
    }
    final store = host.playbackIdentity;
    if (store == null) {
      return const SyncResponse(
        404,
        '未实现 /api/playback/identity/resolve',
      );
    }

    // 先验授权再读体：未授权对端不该有机会让我们读 8 MiB。
    final peerAddress = request.connectionInfo?.remoteAddress.address ?? '';
    final auth = validateSyncPullAuth(
      pushEnabled: host.isEnabled(),
      configuredToken: host.pullToken,
      providedToken: request.headers.value('x-webhtv-token'),
      peerAuthorized: host.isPeerAuthorized(peerAddress),
      disabledMessage: '同步服务未开启（请在 WebHTV PC 的设置中开启 Android 同步）',
    );
    if (!auth.allowed) {
      log.warning(
        '身份解析被拒绝 status=${auth.status} peer=${_maskAddress(peerAddress)} '
        'reason=${auth.message}',
        scope: 'realtime',
      );
      return SyncResponse(auth.status, auth.message ?? '请求被拒绝');
    }

    final bytes = await _readBody(request);
    if (bytes == null) {
      return SyncResponse(
        413,
        '请求体超过上限 ${syncMaxPayloadBytes ~/ (1024 * 1024)} MiB',
      );
    }
    final decoded = _decode(utf8.decode(bytes, allowMalformed: true));
    final body = asMap(decoded);
    if (body.isEmpty) {
      return _invalidIdentity('Invalid identity request');
    }
    final input = PlaybackIdentityInput.parse(
      body,
      headerInterfaceKey: request.headers.value('x-webhtv-config-key'),
    );
    if (input == null) {
      return _invalidIdentity('identity key is invalid');
    }
    if (input.schema != playbackIdentitySchema || input.operation != 'resolve') {
      return _invalidIdentity(
        'Unsupported identity request（schema=${input.schema} '
        'operation=${input.operation}）',
        input: input,
      );
    }

    final result = store.resolve(input);
    log.info(
      '身份解析 configType=${input.configType} '
      'action=${result.body['action']} '
      'matchedBy=${result.body['matchedBy']} '
      'epoch=${result.body['identityEpoch']} peer=${_maskAddress(peerAddress)}',
      scope: 'realtime',
    );
    return SyncResponse(
      result.statusCode,
      jsonEncode(result.body),
      isJson: true,
    );
  }

  /// `GET /api/playback/sync/status`（`design/01` §3.2.1）。
  ///
  /// 安卓本身**不调用**它（只按同步 URL 推导 `identity/resolve`），但
  /// `design/04` 的 6c 门禁要用它断言能力声明，第三方客户端也靠它探测。
  SyncResponse _handlePlaybackStatus(HttpRequest request) {
    if (request.method != 'GET') {
      return const SyncResponse(405, '仅支持 GET');
    }
    final peerAddress = request.connectionInfo?.remoteAddress.address ?? '';
    final auth = validateSyncPullAuth(
      pushEnabled: host.isEnabled(),
      configuredToken: host.pullToken,
      providedToken: request.headers.value('x-webhtv-token'),
      peerAuthorized: host.isPeerAuthorized(peerAddress),
      disabledMessage: '同步服务未开启（请在 WebHTV PC 的设置中开启 Android 同步）',
    );
    if (!auth.allowed) {
      return SyncResponse(auth.status, auth.message ?? '请求被拒绝');
    }

    final counts =
        host.playbackCounts?.call() ??
        (items: 0, tombstones: 0, nextSince: 0);
    final headerKey = (request.headers.value('x-webhtv-config-key') ?? '').trim();
    final usePrefix = request.uri.path.startsWith('/api/');
    final hostHeader = request.headers.value('host') ?? '';
    final origin = hostHeader.isEmpty ? baseUrl : 'http://$hostHeader';
    final body = buildPlaybackSyncStatus(
      configKey: headerKey.isEmpty ? host.deviceUuid : headerKey,
      // 如实声明：拉取关闭时 `playbackSync` 就是 false（不谎报能力）。
      playbackSyncEnabled: host.realtimePull != null,
      items: counts.items,
      tombstones: counts.tombstones,
      nextSince: counts.nextSince,
      endpoint: '$origin${usePrefix ? '/api' : ''}/playback/sync',
      identityEpoch: '${host.playbackIdentity?.registryFor('vod').epoch ?? 0}',
    );
    return SyncResponse(200, jsonEncode(body), isJson: true);
  }

  /// 非法身份请求的 400 响应（安卓据此得到 `action=invalid`）。
  SyncResponse _invalidIdentity(String error, {PlaybackIdentityInput? input}) {
    final placeholder =
        input ??
        const PlaybackIdentityInput(
          configType: 'vod',
          interfaceKey: '',
          strictAddressKeys: [],
          endpointMatchKeys: [],
          hostMatchKeys: [],
          legacyConfigKeys: [],
          sourceDataState: 'unknown',
        );
    log.warning('身份解析请求非法：$error', scope: 'realtime');
    return SyncResponse(
      400,
      jsonEncode(
        playbackIdentityResponse(
          'invalid',
          placeholder,
          extra: {'error': error},
        ),
      ),
      isJson: true,
    );
  }

  /// 从表单里取对端自报的 uuid（`device` JSON 优先，其次平铺字段）。
  String _peerUuid(Map<String, String> fields, Map<String, String> params) {
    for (final candidate in [fields['device'], fields['deviceUuid']]) {
      if (candidate == null || candidate.trim().isEmpty) continue;
      final decoded = _decode(candidate);
      if (decoded is Map) {
        final uuid = asString(asMap(decoded)['uuid']) ?? '';
        if (uuid.trim().isNotEmpty) return uuid.trim();
      } else if (decoded == null) {
        // 不是 JSON：当作裸 uuid 字符串。
        if (candidate.trim().isNotEmpty) return candidate.trim();
      }
    }
    return params['uuid'] ?? '';
  }

  // ------------------------------------------------------------------ 解析

  /// 读取请求体，超过 [syncMaxPayloadBytes] 返回 `null`。
  ///
  /// 超限时必须**先排空**再回 413：在 `await for` 里直接 `return` 会取消订阅，
  /// Dart 会提前拆掉连接，对端只会看到
  /// “Connection closed before full header was received”，拿不到 413。
  Future<List<int>?> _readBody(HttpRequest request) async {
    if (request.contentLength > syncMaxPayloadBytes) {
      await _drain(request);
      return null;
    }
    final builder = BytesBuilder(copy: false);
    var overflow = false;
    try {
      await for (final chunk in request.timeout(requestTimeout)) {
        if (overflow) continue;
        builder.add(chunk);
        if (builder.length > syncMaxPayloadBytes) {
          overflow = true;
          // 已确定要拒绝，不再保留这几十 MB。
          builder.clear();
        }
      }
    } on TimeoutException {
      return const [];
    }
    return overflow ? null : builder.takeBytes();
  }

  /// 排空（丢弃）请求体，让对端能收到响应而不是连接被拆。
  Future<void> _drain(HttpRequest request) async {
    try {
      await for (final _ in request.timeout(requestTimeout)) {
        // 丢弃。
      }
    } on Object {
      // 对端提前断开：无法给响应，交由调用方的写入失败分支处理。
    }
  }

  /// 解析表单体。
  ///
  /// 只支持 `application/x-www-form-urlencoded`（`design/02` §8 Q4：PC 无对应
  /// 文件语义，不处理 multipart 归档）。multipart 里若**只有**普通文本字段
  /// （无文件部分），仍然接受——安卓的 `FormBody` 有时带 multipart 头。
  _SyncForm? _parseForm(HttpRequest request, List<int> body) {
    final contentType =
        request.headers.contentType?.mimeType ?? 'application/x-www-form-urlencoded';
    if (contentType == 'application/x-www-form-urlencoded' ||
        contentType.isEmpty) {
      return _SyncForm(
        fields: Uri.splitQueryString(
          utf8.decode(body, allowMalformed: true),
          encoding: utf8,
        ),
      );
    }
    if (contentType == 'multipart/form-data') {
      return _parseMultipart(request, body);
    }
    return null;
  }

  /// 极简 multipart 解析：只取文本字段，遇到任何文件部分即拒绝。
  _SyncForm? _parseMultipart(HttpRequest request, List<int> body) {
    final boundary = request.headers.contentType?.parameters['boundary'];
    if (boundary == null || boundary.isEmpty) return null;
    final text = latin1.decode(body);
    final fields = <String, String>{};
    for (final part in text.split('--$boundary')) {
      final headerEnd = part.indexOf('\r\n\r\n');
      if (headerEnd < 0) continue;
      final headers = part.substring(0, headerEnd).toLowerCase();
      final name = RegExp(r'name="([^"]*)"').firstMatch(headers)?.group(1);
      if (name == null) continue;
      if (headers.contains('filename=')) {
        // 归档文件：PC 明确不支持，拒绝整请求并让对端看到原因（P5）。
        log.warning('同步请求包含归档文件，PC 不支持：name=$name', scope: 'sync');
        return null;
      }
      var value = part.substring(headerEnd + 4);
      if (value.endsWith('\r\n')) value = value.substring(0, value.length - 2);
      fields[name] = value;
    }
    return _SyncForm(fields: fields);
  }

  Object? _decode(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  Future<void> _write(HttpRequest request, SyncResponse response) async {
    try {
      request.response
        ..statusCode = response.statusCode
        ..headers.contentType = response.isJson
            ? ContentType('application', 'json', charset: 'utf-8')
            : ContentType('text', 'plain', charset: 'utf-8')
        ..write(response.body);
      await request.response.close();
    } on Object {
      // 对端可能已断开；同步失败由状态层呈现，这里不额外抛。
    }
  }

  /// 地址脱敏：只留前两段（`design/02` §7 的同一口径）。
  String _maskAddress(String address) {
    if (address.isEmpty) return '****';
    final parts = address.split('.');
    if (parts.length == 4) return '${parts[0]}.${parts[1]}.*.*';
    return '****';
  }

  /// uuid 只留前 4 位（`design/02` §7）。
  String _maskUuid(String uuid) =>
      uuid.length <= 4 ? '****' : '${uuid.substring(0, 4)}****';

  /// 选一个局域网 IPv4 作为对外地址（多网卡时取第一个非回环）。
  Future<String?> _resolveLanIp() async {
    try {
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final address in interface.addresses) {
          if (address.address.startsWith('169.254.')) continue; // 链路本地
          return address.address;
        }
      }
    } catch (error) {
      log.warning('同步服务：枚举网络接口失败 $error', scope: 'sync');
    }
    return null;
  }
}

/// 请求体字段。
class _SyncForm {
  const _SyncForm({required this.fields});

  final Map<String, String> fields;
}
