/// PC 侧同步客户端（`docs/phase5/design/02` §3.2）。
///
/// 方向与 `sync_server.dart` 相反：这里是 **PC 当调用方**，向安卓的
/// `/action?do=sync` 推送历史/收藏/设置，或请求安卓主动推给 PC。
///
/// ## `mode` 语义（源码实证，`design/02` §3.2）
///
/// `mode` 从**被请求方**视角定义：
/// - PC **推送**给安卓 → `mode=1`（“你接收我发的”）；
/// - PC **拉取**安卓数据 → `mode=2` + `device=<PC 的 Device JSON>`；
/// - 双向 → `mode=0` + `device=<PC 的 Device JSON>`。
///
/// 写错方向会静默失效，因此这里集中构造路径（[buildSyncActionPath]），
/// 由测试锁定（`design/03` §3.4 用例 1）。
///
/// ## 两条必须校验的前置条件（P5）
///
/// 1. `type=history` 时 `config` 必须含**非空 `url`**：安卓的 `syncHistory`
///    首行就是 `if (config.getUrl() == null) return;` —— 静默无操作但返回 200，
///    不校验就会把“什么都没写”报成成功；
/// 2. 请求必须打到 PC 视角的**可达地址**，并显式设置 `Host` 头，
///    与 T4 桥接同一约定（`design/01` §4）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/android_bridge.dart';
import '../core/android_sync.dart';
import '../core/app_error.dart';
import '../core/protocol.dart';
import 'log_service.dart';

/// 一次推送的结果。
class SyncPushResult {
  const SyncPushResult({
    required this.statusCode,
    required this.body,
    required this.type,
    required this.mode,
    required this.itemCount,
    this.stats,
  });

  final int statusCode;

  /// 对端响应正文（PC 服务端会回 `OK applied=… skipped=… failed=…`）。
  final String body;

  final String type;
  final String mode;

  /// 本次发送的条目数。
  final int itemCount;

  /// 从响应正文解析出的明细（对端没给明细时为 `null`）。
  final SyncMergeStats? stats;

  /// 对端是否自报明细不闭合（`applied+skipped+failed != total`）。
  bool get isInconsistent => body.contains('INCONSISTENT');

  String describe() =>
      'push type=$type mode=$mode items=$itemCount status=$statusCode'
      '${stats == null ? '' : ' ${stats!.describe()}'}';

  @override
  String toString() => describe();
}

/// 向安卓推送与拉取的客户端。
class SyncClient {
  SyncClient({
    required this.log,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final LogService log;

  /// 推送超时（`design/02` §4.3 对齐服务端的 30 s）。
  final Duration timeout;

  void close() => _client.close();

  /// 把本地历史推给安卓（`design/02` §3.5）。
  ///
  /// [configJson] 必须是含非空 `url` 的 JSON 对象——见库注释第 1 条。
  Future<SyncPushResult> pushHistory({
    required String deviceBase,
    required String configJson,
    required List<SyncHistoryItem> items,
    SyncOptions options = SyncOptions.pcDefault,
  }) async {
    _requireConfigUrl(configJson);
    final targets = items.map((item) => item.toAndroidJson()).toList();
    return _post(
      deviceBase: deviceBase,
      type: 'history',
      mode: '1',
      form: {
        'config': configJson,
        'targets': jsonEncode(targets),
        'options': options.jsonText,
      },
      itemCount: targets.length,
    );
  }

  /// 把本地收藏推给安卓（`type=keep`）。
  Future<SyncPushResult> pushKeep({
    required String deviceBase,
    required List<SyncFavoriteItem> items,
    SyncOptions options = SyncOptions.pcDefault,
    String configsJson = '[]',
  }) async {
    final targets = items.map((item) => item.toAndroidJson()).toList();
    return _post(
      deviceBase: deviceBase,
      type: 'keep',
      mode: '1',
      form: {
        'targets': jsonEncode(targets),
        'configs': configsJson,
        'options': options.jsonText,
      },
      itemCount: targets.length,
    );
  }

  /// 把设置推给安卓（`type=backup`）。
  ///
  /// [options] 的 `settings` 默认 `false`：含凭据的设置项**默认不发送**，
  /// 用户显式勾选后才置 `true`（P3）。
  Future<SyncPushResult> pushBackup({
    required String deviceBase,
    required Map<String, Object?> backup,
    SyncOptions options = SyncOptions.pcDefault,
  }) async {
    return _post(
      deviceBase: deviceBase,
      type: 'backup',
      mode: '1',
      form: {
        'options': options.jsonText,
        'backup': jsonEncode(backup),
        if (options.settings) 'allowSensitive': 'true',
      },
      itemCount: 1,
    );
  }

  /// 请求安卓把它的数据推给 PC（`mode=2` + `device`，`design/02` §3.2）。
  ///
  /// 这是"便利路径"：PC 的常规接收方式是自己的服务端被动接收推送。
  Future<SyncPushResult> requestPull({
    required String deviceBase,
    required String type,
    required String pcDeviceJson,
  }) async {
    return _post(
      deviceBase: deviceBase,
      type: type,
      mode: '2',
      // `mode=2` 时安卓**不会**应用请求体载荷，因此载荷给空占位即可。
      form: {'device': pcDeviceJson},
      itemCount: 0,
      requirePayload: false,
    );
  }

  // ------------------------------------------------------------------ 内部

  void _requireConfigUrl(String configJson) {
    Object? decoded;
    try {
      decoded = jsonDecode(configJson);
    } on FormatException {
      throw AppError(
        AppErrorKind.syncPayloadInvalid,
        '同步配置不是合法 JSON',
        detail: 'config',
      );
    }
    final url = (asString(asMap(decoded)['url']) ?? '').trim();
    if (url.isEmpty) {
      throw AppError(
        AppErrorKind.syncPayloadInvalid,
        '推送历史前必须选择与安卓当前一致的配置（config.url 为空时'
        '安卓会静默忽略全部记录，却仍返回成功）',
        detail: 'config.url',
      );
    }
  }

  Future<SyncPushResult> _post({
    required String deviceBase,
    required String type,
    required String mode,
    required Map<String, String> form,
    required int itemCount,
    bool requirePayload = true,
  }) async {
    final base = normalizeBase(deviceBase);
    final path = buildSyncActionPath(mode: mode, type: type);
    final uri = Uri.parse('$base$path');
    final hostPort = hostPortOf(base);

    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            // 显式 `Host`：见库注释第 2 条（`design/01` §4 同一约定）。
            headers: {
              'Host': hostPort,
              'Accept': 'text/plain',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: _encodeForm(form),
          )
          .timeout(timeout);
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.syncPeerUnreachable,
        '同步超时（${timeout.inSeconds}s），对端未响应',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    } on SocketException catch (error) {
      throw AppError(
        AppErrorKind.syncPeerUnreachable,
        '无法连接对端设备：${error.osError?.message ?? '连接失败'}',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    } catch (error) {
      throw AppError(
        AppErrorKind.syncPeerUnreachable,
        '无法连接对端设备：${error.runtimeType}',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    }

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode == 403) {
      // 403 是安卓侧"本机 API 修改未开启"的信号；文案必须给出开关位置，
      // 否则用户会去查网络（`design/02` §6）。
      throw AppError(
        AppErrorKind.syncLocalWriteRejected,
        '安卓拒绝写入：需在安卓的「设置 → 观影记录同步」中开启「本机 API 修改」'
        '（对端返回 403${body.isEmpty ? '' : '：$body'}）',
        detail: hostPort,
        statusCode: 403,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 4xx/5xx 不得静默、不得折叠成"连不上"（`design/02` §6 的 `syncPeerError`）。
      throw AppError(
        AppErrorKind.syncPeerError,
        '对端返回 HTTP ${response.statusCode}'
        '${body.trim().isEmpty ? '' : '：${body.trim()}'}',
        detail: hostPort,
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }

    final result = SyncPushResult(
      statusCode: response.statusCode,
      body: body,
      type: type,
      mode: mode,
      itemCount: itemCount,
      stats: parseStats(body),
    );
    log.info(
      '${requirePayload ? '推送' : '请求拉取'}完成 ${result.describe()}',
      scope: 'sync',
    );
    return result;
  }

  String _encodeForm(Map<String, String> form) => form.entries
      .map(
        (entry) =>
            '${Uri.encodeQueryComponent(entry.key)}='
            '${Uri.encodeQueryComponent(entry.value)}',
      )
      .join('&');
}

/// 从对端响应正文里解析 `applied=… skipped=… failed=… total=…`。
///
/// 对端没给明细（例如把 PC 当成老版本安卓）时返回 `null`，而不是伪造 0。
SyncMergeStats? parseStats(String body) {
  int? pick(String key) {
    final match = RegExp('$key=(\\d+)').firstMatch(body);
    final text = match?.group(1);
    return text == null ? null : int.tryParse(text);
  }

  final applied = pick('applied');
  final skipped = pick('skipped');
  final failed = pick('failed');
  final total = pick('total');
  if (applied == null || skipped == null || failed == null || total == null) {
    return null;
  }
  return SyncMergeStats(
    applied: applied,
    skipped: skipped,
    failed: failed,
    total: total,
  );
}
