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
import '../core/protocol.dart';
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
  final Future<SyncMergeStats> Function(SyncHistoryParseResult parsed)
  onHistory;

  /// 应用一批收藏。
  final Future<SyncMergeStats> Function(SyncFavoriteParseResult parsed)
  onKeep;

  /// 应用设置备份（白名单子集）。
  final Future<SyncSettings> Function(Object? backup, bool allowSensitive)
  onBackup;

  /// 对端要求 PC 主动推给它（`mode=2` + `device`）时调用。
  final Future<void> Function(String deviceJson)? onPullRequest;
}

/// 一次请求的处理结果（供测试直接断言状态码与 message）。
class SyncResponse {
  const SyncResponse(this.statusCode, this.body);

  const SyncResponse.ok(String detail) : statusCode = 200, body = 'OK $detail';

  final int statusCode;
  final String body;

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
        _ => const SyncResponse(404, '未知路径（仅支持 /device 与 /action）'),
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
        ..headers.contentType = ContentType(
          'text',
          'plain',
          charset: 'utf-8',
        )
        ..write(response.body);
      await request.response.close();
    } on Object {
      // 对端可能已断开；同步失败由状态层呈现，这里不额外抛。
    }
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
