/// 安卓读取客户端（`docs/phase7/design/01` §4.1）——路径 A 的 PC 侧调用方。
///
/// 方向与 `sync_client.dart` 不同：后者是**推送**（`POST /action?do=sync`），
/// 这里只做**只读 GET**，不改动安卓任何状态。
///
/// ## 三个端点
///
/// | 方法 | 路径 | 用途 |
/// | --- | --- | --- |
/// | `GET` | `/api/playback/history?siteKey=&limit=` | 该站点最近 N 条历史（**推荐**） |
/// | `GET` | `/api/playback/current?siteKey=` | 仅「正在播放的那一条」（降级用） |
/// | `GET` | `/manage/session` | 唤醒 + 读服务状态（保活用，T6 消费） |
///
/// ## 必须处理的四件事
///
/// 1. **能力探测 + 降级**（`design/01` §4.1）：`/api/playback/history` 不存在时
///    降级为 `/current`，并在 UI 常驻披露「仅能同步正在播放的记录」。
///    **空数组（200）算可用**——「没有历史」与「端点不存在」必须可区分，
///    否则没看过任何剧的用户会被永久降级。
/// 2. **`updatedAt` 不可靠**（`design/01` §4.1「阻塞性发现」）：安卓的
///    `/history` **不返回**记录更新时间，只有响应生成时刻 `timestamp`。
///    必须按优先级探测并留痕来源，见 `resolveUpdatedAt`。
/// 3. **`episodeId` 两层兜底**（`design/01` §4.1 警告）：安卓已交付
///    `episodeId` 字段（= `episodeUrl` 的 SHA-256），但旧版本/第三方服务端
///    可能没有，需用 `episodeName` 兜底；两者都空则**不合并**。
/// 4. **`Host` 头**：与 T4 桥接同一约定——模拟器 NAT 场景下必须显式设置，
///    否则安卓的 `Server` 认不出请求（`design/01` §4）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/android_bridge.dart';
import '../core/android_sync.dart';
import '../core/app_error.dart';
import '../core/protocol.dart';
import '../core/realtime_sync.dart';
import 'log_service.dart';
import 'realtime_sync_engine.dart';

/// 一次「按站点读历史」的结果。
class AndroidHistoryReadResult {
  const AndroidHistoryReadResult({
    required this.siteKey,
    required this.items,
    required this.failures,
    required this.updatedAtSource,
    required this.skippedAsUnchanged,
    required this.endpoint,
  });

  final String siteKey;

  /// 解析成功的条目（已按 `updatedAt` 优先级与 `episodeId` 兜底处理）。
  final List<SyncHistoryItem> items;

  /// 解析失败的明细（P5：不得静默丢弃）。
  final List<SyncFailure> failures;

  /// 本批的 `updatedAt` 来源（取最差的那个，供披露）。
  final UpdatedAtSource updatedAtSource;

  /// 因「内容等价」被跳过的条数（时间戳不可靠时的幂等兜底）。
  final int skippedAsUnchanged;

  /// 实际使用的端点（`history` 或 `current`），供证据与 UI 披露。
  final RealtimePullCapability endpoint;

  bool get isEmpty => items.isEmpty && failures.isEmpty;

  String describe() =>
      'read(site=$siteKey endpoint=${endpoint.name} '
      'items=${items.length} failed=${failures.length} '
      'updatedAt=${updatedAtSource.name} skippedUnchanged=$skippedAsUnchanged)';
}

/// 端点能力探测结果（含耗时与状态码，供证据落盘）。
class AndroidPullProbe {
  const AndroidPullProbe({
    required this.capability,
    required this.historyStatusCode,
    required this.currentStatusCode,
    this.historyResult = EndpointProbeResult.missing,
    this.currentResult = EndpointProbeResult.missing,
  });

  final RealtimePullCapability capability;
  final int? historyStatusCode;
  final int? currentStatusCode;

  /// 形态级探测结果（`design/01` §4.1 的第二个阻塞性发现：不能只看状态码）。
  final EndpointProbeResult historyResult;
  final EndpointProbeResult currentResult;

  String describe() =>
      'probe(capability=${capability.name} '
      'history=${historyStatusCode ?? '-'}/${historyResult.name} '
      'current=${currentStatusCode ?? '-'}/${currentResult.name})';
}

/// 安卓只读端点客户端。
class AndroidReadClient {
  AndroidReadClient({
    required this.log,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final LogService log;

  /// 单次读取超时。
  ///
  /// 比推送的 30 s 短得多：读取是**周期**动作（默认 60 s 一轮），
  /// 单站点慢请求不能拖垮整轮。8 s 与 T4 桥接的常规请求一致。
  final Duration timeout;

  void close() => _client.close();

  /// 探测路径 A 的读取能力（`design/01` §4.1 的探测矩阵）。
  ///
  /// 用 `limit=1` 打一个**几乎不可能存在**的 siteKey：只要能拿到
  /// 200+JSON / 400+JSON 就说明端点存在。
  ///
  /// **两个必须避开的陷阱**（均来自真机实测）：
  /// 1. **200 + 空数组算可用**——「没有历史」与「端点不存在」必须可区分，
  ///    否则没看过任何剧的用户会被永久降级；
  /// 2. **端点不存在时安卓返回 200 + `application/octet-stream` + 空体**
  ///    （`Nano.serve()` 落到 `getAssets()`，NanoHTTPD 对缺失资产回 200），
  ///    **不是 404**。只看状态码会把「不存在」当成「存在且无数据」。
  ///    必须看 `Content-Type` 与响应体形态，见 [classifyEndpointProbe]。
  Future<AndroidPullProbe> probePullCapability(String deviceBase) async {
    final history = await _probeEndpoint(
      deviceBase,
      '/api/playback/history',
      query: {'siteKey': '__webhtv_probe__', 'limit': '1'},
    );
    if (endpointExists(history.result)) {
      return AndroidPullProbe(
        capability: RealtimePullCapability.history,
        historyStatusCode: history.statusCode,
        currentStatusCode: null,
        historyResult: history.result,
      );
    }
    // 端点不存在 → 看降级端点是否可用。
    final current = await _probeEndpoint(
      deviceBase,
      '/api/playback/current',
      query: {'siteKey': '__webhtv_probe__'},
    );
    return AndroidPullProbe(
      capability: classifyPullCapability(
        history: history.result,
        current: current.result,
      ),
      historyStatusCode: history.statusCode,
      currentStatusCode: current.statusCode,
      historyResult: history.result,
      currentResult: current.result,
    );
  }

  /// 读某站点的历史（`design/01` §4.1）。
  ///
  /// [capability] 为 `null` 时先探测。传入已知能力可省一次探测
  /// （调用方通常已缓存 60 s，见 `RealtimeCapabilityCache`）。
  ///
  /// [localByMatchKey] 用于时间戳不可靠时的幂等兜底：本地已存在且进度
  /// 内容等价的记录会被跳过（`shouldSkipAsUnchanged`）。
  Future<AndroidHistoryReadResult> readHistory({
    required String deviceBase,
    required String siteKey,
    required RealtimePullCapability capability,
    int limit = realtimeDefaultSiteLimit,
    Map<String, SyncHistoryItem> localByMatchKey = const {},
  }) async {
    if (capability == RealtimePullCapability.unsupported) {
      throw AppError(
        AppErrorKind.realtimePullUnsupported,
        describeErrorKind(AppErrorKind.realtimePullUnsupported),
        detail: hostPortOf(normalizeBase(deviceBase)),
      );
    }

    final isDegraded = capability == RealtimePullCapability.currentOnly;
    final path = isDegraded ? '/api/playback/current' : '/api/playback/history';
    final query = isDegraded
        ? {'siteKey': siteKey}
        : {'siteKey': siteKey, 'limit': '$limit'};

    final response = await _get(
      deviceBase,
      path,
      query: query,
      // **只有降级端点**的 404 是合法形态（`/current` 未播放时）。
      //
      // `/api/playback/history` 对任一 siteKey 都返回 200+空数组，
      // 从不返回 404；因此它一旦“端点不存在”（真机形态是
      // 200+octet-stream），必须报错而不是静默变成空结果——
      // 否则用户会看到「同步成功但 0 条」，而实际是端点没了。
      allowNotFound: isDegraded,
    );
    if (response == null) {
      // 404：该站点当前无记录（降级端点未播放时的正常形态）。
      return AndroidHistoryReadResult(
        siteKey: siteKey,
        items: const [],
        failures: const [],
        updatedAtSource: UpdatedAtSource.none,
        skippedAsUnchanged: 0,
        endpoint: capability,
      );
    }

    final decoded = _decodeJson(response.body, deviceBase);
    // `/history` 返回 `{siteKey, items, total}`；`/current` 返回**单条记录**。
    final rawItems = isDegraded
        ? (decoded is Map ? [decoded] : const <Object?>[])
        : asList(asMap(decoded)['items']);

    final items = <SyncHistoryItem>[];
    final failures = <SyncFailure>[];
    var worstSource = UpdatedAtSource.updatedAt;
    var skippedUnchanged = 0;

    for (var index = 0; index < rawItems.length; index++) {
      final raw = asMap(rawItems[index]);
      if (raw.isEmpty) {
        failures.add(SyncFailure(index: index, reason: '记录不是 JSON 对象'));
        continue;
      }
      final resolved = resolveUpdatedAt(raw);
      // 取「最差」的来源：只要有一条不可靠，整批就要披露。
      if (_sourceRank(resolved.source) > _sourceRank(worstSource)) {
        worstSource = resolved.source;
      }

      final item = _mapRecord(raw, resolved, index, failures);
      if (item == null) continue;

      // 时间戳不可靠时的幂等兜底（`design/01` §4.1 处置第 2 条）。
      final local = localByMatchKey[item.matchKey];
      if (!resolved.isReliable &&
          shouldSkipAsUnchanged(
            localExists: local != null,
            sameProgress:
                local != null &&
                isSameProgress(
                  positionMsA: local.positionMs,
                  durationMsA: local.durationMs,
                  completedA: local.completed,
                  positionMsB: item.positionMs,
                  durationMsB: item.durationMs,
                  completedB: item.completed,
                ),
          )) {
        skippedUnchanged++;
        continue;
      }
      items.add(item);
    }

    final result = AndroidHistoryReadResult(
      siteKey: siteKey,
      items: items,
      failures: failures,
      updatedAtSource: worstSource,
      skippedAsUnchanged: skippedUnchanged,
      endpoint: capability,
    );
    log.info('读取安卓历史 ${result.describe()}', scope: 'realtime');
    return result;
  }

  /// 读安卓的服务状态（保活用，`design/02` §3.2）。
  ///
  /// 返回原始 JSON（字段由 T6 的保活引擎消费）；端点不存在时返回 `null`
  /// （老版本安卓无 `/manage` → 调用方降级到 `/device`）。
  ///
  /// **端点存在性同样不能只看状态码**：真机实测确认 `/manage/session`
  /// 返回 200 + JSON；但缺失路径会得到 200 + `octet-stream`，
  /// 因此这里用 [classifyEndpointProbe] 判形态。
  Future<Map<String, Object?>?> readManageSession(String deviceBase) async {
    final response = await _get(deviceBase, '/manage/session', allowNotFound: true);
    if (response == null) return null;
    final result = classifyEndpointProbe(
      statusCode: response.statusCode,
      contentType: response.contentType,
      bodyLength: response.body.length,
    );
    if (!endpointExists(result)) return null;
    final decoded = _decodeJson(response.body, deviceBase);
    return decoded is Map ? decoded.map((k, v) => MapEntry('$k', v)) : null;
  }

  /// 心跳探测（`design/02` §3.2、§4 的三步序列）。
  ///
  /// 与 [readManageSession] 的区别：后者只回答「能不能读到会话」，
  /// 本方法要回答「为什么不能」——这三者（端口无人监听 / 进程被冻结 /
  /// 网络不通）对用户是**三个完全不同的动作**（`design/02` §4）。
  ///
  /// 探测序列（每步 [stepTimeout]，总超时约 `3×stepTimeout + tcpTimeout`）：
  /// `S1 /manage/session` → `S2 /device` → `S3 TCP connect`。
  /// 判定完全交给 [classifyProbeSteps]（纯逻辑，已由 K 套件锁定）。
  ///
  /// **为何要单独一步 TCP connect**：进程被冻结时内核仍会完成 TCP 握手
  /// （监听队列在内核），只是用户态线程不调度、HTTP 响应出不来；
  /// 网络不通时握手本身就失败。这是 PC 侧唯一能区分二者的手段。
  ///
  /// **[tcpTimeout] 为什么要比 [stepTimeout] 宽**（实测结论，不是拍脑袋）：
  /// 本机（Windows）连一个**未监听的回环端口**时，「连接被拒」要 **~2 s**
  /// 才上报（实测：`Socket.connect` 2 s 超时 → errno 10060 超时；
  /// 5 s 超时 → errno 1225 拒绝）。而 [stepTimeout] 默认也是 2 s，
  /// 两者正好打平 → 拒绝被超时抢走 → 三态误判成 `networkUnreachable`。
  ///
  /// 后果很具体：安卓服务明明只是没开，用户却被指去查 WiFi，
  /// 而不是去打开安卓管理页（`design/02` §4 的 P5 要求）。
  /// TCP connect 是最廉价且最决定性的一步，值得给它足够预算。
  Future<RealtimeHeartbeatProbe> heartbeat(
    String deviceBase, {
    Duration stepTimeout = const Duration(seconds: 2),
    Duration? tcpTimeout,
  }) async {
    // 默认取「2×步超时」与 5 s 的较大者：既覆盖实测的 2 s 拒绝延迟，
    // 也不会在真不可达时把总预算拉得过长。
    final effectiveTcpTimeout =
        tcpTimeout ??
        (stepTimeout * 2 > const Duration(seconds: 5)
            ? stepTimeout * 2
            : const Duration(seconds: 5));
    final base = normalizeBase(deviceBase);
    final steps = <RealtimeProbeStep>[];
    Map<String, Object?> session = const <String, Object?>{};
    int? statusCode;
    var usedFallback = false;

    // S1：/manage/session（成功即顺手 touch 保活）。
    final manage = await _stepGet(base, '/manage/session', stepTimeout);
    statusCode = manage.statusCode;
    steps.add(manage.step);
    if (manage.step == RealtimeProbeStep.manageOk) {
      session = manage.session;
    } else if (manage.step != RealtimeProbeStep.connectionRefused) {
      // 端点缺失或超时 → S2。
      // **拒绝不必继续**：内核已经明确告诉我们「端口无人监听」，
      // 后两步只会多花 4 s 并得到同一个结论。
      final device = await _stepGet(base, '/device', stepTimeout);
      statusCode ??= device.statusCode;
      steps.add(device.step);
      usedFallback = device.step == RealtimeProbeStep.deviceOk;
    }

    // 已经能下结论的两种情况：可达、或被拒绝。
    final early = classifyProbeSteps(steps);
    if (early == RealtimePeerState.ok ||
        early == RealtimePeerState.serviceStopped) {
      return RealtimeHeartbeatProbe(
        state: early,
        statusCode: statusCode,
        session: session,
        usedDeviceFallback: usedFallback,
        detail: hostPortOf(base),
      );
    }

    // S3：TCP connect（区分「冻结」与「完全不通」）。
    // 用更宽的 [effectiveTcpTimeout]：拒绝可能比 [stepTimeout] 晚到（见方法注释）。
    final tcp = await _probeTcp(base, effectiveTcpTimeout);
    steps.add(tcp);
    return RealtimeHeartbeatProbe(
      state: classifyProbeSteps(steps),
      statusCode: statusCode,
      session: session,
      usedDeviceFallback: usedFallback,
      detail: '${hostPortOf(base)} tcp=${tcp.name}',
    );
  }

  /// 心跳里的单步 GET（不抛错，只归类）。
  Future<({RealtimeProbeStep step, int? statusCode, Map<String, Object?> session})>
  _stepGet(String base, String path, Duration stepTimeout) async {
    final hostPort = hostPortOf(base);
    try {
      final response = await _client
          .get(
            Uri.parse('$base$path'),
            headers: {'Host': hostPort, 'Accept': 'application/json'},
          )
          .timeout(stepTimeout);
      final probe = classifyEndpointProbe(
        statusCode: response.statusCode,
        contentType: response.headers['content-type'],
        bodyLength: response.bodyBytes.length,
      );
      if (!endpointExists(probe)) {
        // 端点缺失（含「200 + octet-stream」）→ 继续下一步。
        // 两种缺失（/manage 无、/device 无）在 [classifyProbeSteps] 里
        // 同义都是「继续」，因此复用 `manageMissing`。
        return (
          step: RealtimeProbeStep.manageMissing,
          statusCode: response.statusCode,
          session: const <String, Object?> {},
        );
      }
      // ⚠️ **404 也算端点缺失**（与 `endpointExists` 的口径不同）。
      //
      // 为什么这里必须额外判 404：`endpointExists` 把 `notFound` 归为「存在」
      // 是为了路径 A 的 `/current`（未播放时 404 是合法形态）。但保活端点
      // `/manage/session` 的 404 含义完全不同——它是**旧版安卓没有这个端点**，
      // 必须降级到 `/device`（`design/02` §3.2 的降级链）。
      //
      // 若把 404 当 `manageOk`：降级链永远不触发、`session` 为空表，
      // 表现为 `running=null`（UI 无法提示「管理页未运行」）而状态却是「可达」。
      // 实测现象（L3）：`heartbeat(state=ok status=404 fallback=false running=null)`。
      if (response.statusCode == 404) {
        return (
          step: RealtimeProbeStep.manageMissing,
          statusCode: response.statusCode,
          session: const <String, Object?> {},
        );
      }
      Map<String, Object?> session = const <String, Object?>{};
      if (path == '/manage/session') {
        try {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map) {
            session = decoded.map((key, value) => MapEntry('$key', value));
          }
        } on Object {
          // 会话 JSON 坏掉不影响「可达」结论（心跳的价值首先是可达性）。
        }
      }
      return (
        step: path == '/manage/session'
            ? RealtimeProbeStep.manageOk
            : RealtimeProbeStep.deviceOk,
        statusCode: response.statusCode,
        session: session,
      );
    } on TimeoutException {
      return (
        step: RealtimeProbeStep.timeout,
        statusCode: null,
        session: const <String, Object?> {},
      );
    } on SocketException catch (error) {
      return (
        step: _isConnectionRefused(error)
            ? RealtimeProbeStep.connectionRefused
            : RealtimeProbeStep.timeout,
        statusCode: null,
        session: const <String, Object?> {},
      );
    } on Object {
      return (
        step: RealtimeProbeStep.timeout,
        statusCode: null,
        session: const <String, Object?> {},
      );
    }
  }

  /// S3：TCP connect 探测。
  Future<RealtimeProbeStep> _probeTcp(
    String base,
    Duration stepTimeout,
  ) async {
    final uri = Uri.tryParse(base);
    final host = uri?.host;
    if (host == null || host.isEmpty) return RealtimeProbeStep.timeout;
    final port = uri?.port ?? 80;
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: stepTimeout);
      // 握手成功但 HTTP 没响应 → 进程被冻结（内核代理了三次握手）。
      return RealtimeProbeStep.tcpConnectedNoHttp;
    } on SocketException catch (error) {
      return _isConnectionRefused(error)
          ? RealtimeProbeStep.connectionRefused
          : RealtimeProbeStep.timeout;
    } on Object {
      return RealtimeProbeStep.timeout;
    } finally {
      socket?.destroy();
    }
  }

  // ------------------------------------------------------------------ 内部

  /// 来源可靠度排序（数值越大越差）。
  int _sourceRank(UpdatedAtSource source) => switch (source) {
    UpdatedAtSource.updatedAt => 0,
    UpdatedAtSource.createTime => 1,
    UpdatedAtSource.timestamp => 2,
    UpdatedAtSource.none => 3,
  };

  /// 把一条安卓记录映射成 [SyncHistoryItem]（`design/01` §4.1）。
  ///
  /// 失败时把原因写进 [failures] 并返回 `null`——**不得**用空串猜造记录（P5）。
  SyncHistoryItem? _mapRecord(
    Map<String, Object?> raw,
    UpdatedAtResolution resolved,
    int index,
    List<SyncFailure> failures,
  ) {
    final key = AndroidHistoryKey.tryParse(raw['historyKey'] ?? raw['key']);
    if (key == null) {
      failures.add(
        SyncFailure(index: index, reason: '缺少 historyKey 或不成段（无法定位记录）'),
      );
      return null;
    }
    final vodName = asString(raw['vodName']);
    if (vodName == null || vodName.isEmpty) {
      failures.add(SyncFailure(index: index, reason: '缺少 vodName'));
      return null;
    }

    // 集消歧两层兜底（`design/01` §4.1 警告）：
    // 首选安卓的 `episodeId` 字段，缺失时用 `episodeName`，双空则不合并。
    final episode = resolveEpisodeId(
      episodeIdField: asString(raw['episodeId']),
      episodeName: asString(raw['episodeName']) ?? asString(raw['vodRemarks']),
    );
    if (!episode.mergeable) {
      failures.add(
        SyncFailure(
          index: index,
          reason: 'episodeId 与 episodeName 都为空（宁可不合，不可错合）',
        ),
      );
      return null;
    }

    final positionMs = asInt(raw['positionMs']) ?? asInt(raw['position']) ?? 0;
    final durationMs = asInt(raw['durationMs']) ?? asInt(raw['duration']) ?? 0;

    return SyncHistoryItem(
      siteKey: key.siteKey,
      vodId: key.vodId,
      vodName: vodName,
      flag: asString(raw['flag']) ?? asString(raw['vodFlag']) ?? '',
      episodeName:
          asString(raw['episodeName']) ?? asString(raw['vodRemarks']) ?? '',
      episodeId: episode.episodeId,
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: resolved.value,
      cid: key.cid,
      vodPic: (asString(raw['vodPic']) ?? '').trim().isEmpty
          ? null
          : asString(raw['vodPic']),
      raw: {
        ...raw,
        // 留痕：让诊断能看出这条的集身份与时间戳是怎么来的（P5）。
        '_episodeIdSource': episode.source.name,
        '_updatedAtSource': resolved.source.name,
      },
    );
  }

  /// 一次 GET 的原始结果（带 `Content-Type`，供形态判定）。
  Future<_RawResponse?> _get(
    String deviceBase,
    String path, {
    Map<String, String> query = const {},
    bool allowNotFound = false,
  }) async {
    final base = normalizeBase(deviceBase);
    final hostPort = hostPortOf(base);
    final uri = Uri.parse('$base$path').replace(queryParameters: query);

    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: {'Host': hostPort, 'Accept': 'application/json'})
          .timeout(timeout);
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.realtimePartialFailure,
        '读取安卓数据超时（${timeout.inSeconds}s）',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    } on SocketException catch (error) {
      throw AppError(
        AppErrorKind.realtimePartialFailure,
        '无法连接安卓设备：${error.osError?.message ?? '连接失败'}',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    } catch (error) {
      throw AppError(
        AppErrorKind.realtimePartialFailure,
        '读取安卓数据失败：${error.runtimeType}',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    }

    final contentType = response.headers['content-type'];
    if (response.statusCode == 404) {
      if (allowNotFound) return null;
      // 不 allowNotFound 时 404 意味着端点缺失——那是能力探测的结论，
      // 不是「这个站点没有记录」（`design/01` §4.1 的 P5 要求）。
      throw AppError(
        AppErrorKind.realtimePullUnsupported,
        describeErrorKind(AppErrorKind.realtimePullUnsupported),
        detail: '$hostPort$path',
        statusCode: 404,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppError(
        AppErrorKind.realtimePartialFailure,
        '安卓返回 HTTP ${response.statusCode}',
        detail: '$hostPort$path',
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }
    // 第二种阻塞性发现：安卓对**未匹配的路径**落到 `getAssets()`，
    // NanoHTTPD 对缺失资产返回 `200 + application/octet-stream + 空体`。
    // 因此 2xx 也必须做形态判定，否则「端点不存在」会被当成
    // 「端点存在且无数据」，调用方静默拿到空结果。
    final probe = classifyEndpointProbe(
      statusCode: response.statusCode,
      contentType: contentType,
      bodyLength: response.bodyBytes.length,
    );
    if (probe == EndpointProbeResult.missing) {
      if (allowNotFound) return null;
      throw AppError(
        AppErrorKind.realtimePullUnsupported,
        describeErrorKind(AppErrorKind.realtimePullUnsupported),
        detail: '$hostPort$path',
        statusCode: response.statusCode,
      );
    }
    final String body;
    try {
      body = utf8.decode(response.bodyBytes);
    } on FormatException {
      throw AppError(
        AppErrorKind.realtimePartialFailure,
        '安卓响应不是 UTF-8 文本',
        detail: '$hostPort$path',
      );
    }
    return _RawResponse(
      statusCode: response.statusCode,
      contentType: contentType,
      body: body,
    );
  }

  /// 探测单个端点的形态（`design/01` §4.1）。
  ///
  /// 不抛错：连不上/超时归 [EndpointProbeResult.unreachable]。
  Future<({int? statusCode, EndpointProbeResult result})> _probeEndpoint(
    String deviceBase,
    String path, {
    Map<String, String> query = const {},
  }) async {
    final base = normalizeBase(deviceBase);
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    try {
      final response = await _client
          .get(
            uri,
            headers: {'Host': hostPortOf(base), 'Accept': 'application/json'},
          )
          .timeout(timeout);
      final result = classifyEndpointProbe(
        statusCode: response.statusCode,
        contentType: response.headers['content-type'],
        bodyLength: response.bodyBytes.length,
      );
      return (statusCode: response.statusCode, result: result);
    } on TimeoutException {
      return (statusCode: null, result: EndpointProbeResult.unreachable);
    } on SocketException {
      return (statusCode: null, result: EndpointProbeResult.unreachable);
    } catch (_) {
      return (statusCode: null, result: EndpointProbeResult.unreachable);
    }
  }

  Object? _decodeJson(String body, String deviceBase) {
    if (body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      throw AppError(
        AppErrorKind.realtimePartialFailure,
        '安卓响应不是合法 JSON',
        detail: hostPortOf(normalizeBase(deviceBase)),
      );
    }
  }
}

/// 「连接被拒」判定（`design/02` §4 三态的关键区分）。
///
/// 为何不能把 `SocketException` 一律当成「不通」：拒绝说明**端口无人监听**
/// （用户该去开安卓管理页），而不可达说明**网络不通**（用户该查 WiFi）。
/// 两者在 PC 侧只能靠 errno / 文案区分。
///
/// | 平台 | refused 的 errno |
/// | --- | --- |
/// | Windows | 10061（WSAECONNREFUSED） |
/// | Windows（本机回环实测） | **1225**（WSAECONNREFUSED 的另一种取值） |
/// | Linux | 111（ECONNREFUSED） |
/// | macOS/iOS | 61（ECONNREFUSED） |
///
/// **1225 是 L3 集成测试抓出来的**：只在 `127.0.0.1` 上连一个不监听的端口时
/// 出现（`errno = 1225`，文案是「远程计算机拒绝网络连接」）。漏了它会把
/// 「服务未运行」误归为 `networkUnreachable`，用户被指去查 WiFi。
bool _isConnectionRefused(SocketException error) {
  final code = error.osError?.errorCode;
  if (code == 10061 || code == 1225 || code == 111 || code == 61) return true;
  final message = '${error.message} ${error.osError?.message ?? ''}'
      .toLowerCase();
  return message.contains('refused') ||
      message.contains('拒绝') ||
      message.contains('refused the network connection');
}

/// 一次 GET 的原始结果。
class _RawResponse {
  const _RawResponse({
    required this.statusCode,
    required this.contentType,
    required this.body,
  });

  final int statusCode;
  final String? contentType;
  final String body;
}
