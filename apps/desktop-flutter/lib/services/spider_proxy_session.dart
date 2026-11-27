import 'dart:async';

import '../core/ipc_protocol.dart';
import '../core/proxy_policy.dart';
import 'spider_process.dart';

/// One playback owner on one exact process generation; IPC carries control only.
class SpiderProxySession {
  SpiderProxySession._(
    this.host,
    this.supervisor,
    this.context,
    this.siteKey,
    this._identity,
  );

  static const ttl = Duration(seconds: 120);
  static const renewInterval = Duration(seconds: 30);
  static final _identities = ProxySessionManager(sessionTtl: ttl);
  static final _owners = Expando<SpiderProxySession>();
  static final _queues = Expando<Future<void>>();
  final SpiderHost host;
  final SpiderHostSupervisor supervisor;
  final Object context;
  final String siteKey;
  final ProxySession _identity;
  String get sessionId => _identity.id;
  String get token => _identity.token;
  Uri? _entryUrl;
  Uri get entryUrl => _entryUrl!;
  SpiderPlaybackLease? _lease;
  Timer? _renewTimer;
  Timer? _expiryTimer;
  bool _active = true;
  Future<void>? _closing;
  bool get active =>
      _active &&
      (_lease?.active ?? false) &&
      identical(supervisor.hostFor(siteKey), host) &&
      identical(_owners[host], this);

  static Future<T> _serial<T>(SpiderHost host, Future<T> Function() action) {
    final previous = _queues[host] ?? Future<void>.value();
    final result = previous.then((_) => action());
    _queues[host] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static Future<SpiderProxySession?> open({
    required SpiderHost host,
    required SpiderHostSupervisor supervisor,
    required Object context,
    required String siteKey,
    bool Function()? isCurrent,
  }) async {
    if (host.proxyHttp == null) return null;
    final identity = _identities.create(siteKey: siteKey);
    final owner = SpiderProxySession._(
      host,
      supervisor,
      context,
      siteKey,
      identity,
    );
    try {
      await _serial(host, () async {
        if (isCurrent != null && !isCurrent()) {
          throw StateError('proxyHttp request is stale');
        }
        if (!identical(supervisor.hostFor(siteKey), host)) {
          throw StateError('proxyHttp generation changed');
        }
        final old = _owners[host];
        old?.invalidate();
        _owners[host] = owner;
        owner._lease = host.acquirePlaybackLease(owner.sessionId);
        final value = await host.call(
          SpiderMethod.proxy,
          params: {
            'op': 'session.open',
            'sessionId': owner.sessionId,
            'token': owner.token,
            'ttlMs': ttl.inMilliseconds,
          },
        );
        if (!owner.active) throw StateError('proxyHttp owner expired');
        if (value is! Map ||
            value['sessionId'] != owner.sessionId ||
            value['expiresInMs'] != ttl.inMilliseconds ||
            value['entryUrl'] is! String) {
          throw StateError('Invalid proxyHttp open response');
        }
        final expected = '${host.proxyHttp!.baseUrl}/s/${owner.token}/proxy';
        if (value['entryUrl'] != expected) {
          throw StateError('Invalid proxyHttp entry authority or path');
        }
        owner._entryUrl = Uri.parse(expected);
        owner._arm();
      });
      unawaited(host.process.done.then((_) => owner.invalidate()));
      return owner;
    } catch (error) {
      await owner.close();
      if (error is SpiderError) {
        throw SpiderError(
          code: error.code,
          category: error.category,
          message: 'proxyHttp session open failed',
          retryable: error.retryable,
          userVisible: error.userVisible,
          siteKey: error.siteKey,
          requestId: error.requestId,
          diagnosticId: error.diagnosticId,
          details: const {'op': 'session.open'},
        );
      }
      throw StateError('proxyHttp session open failed');
    }
  }

  void _arm() {
    _lease?.renew(ttl);
    _expiryTimer?.cancel();
    _expiryTimer = Timer(ttl, () => unawaited(close()));
    _renewTimer?.cancel();
    _renewTimer = Timer(renewInterval, () => unawaited(renew()));
  }

  Future<void> renew() async {
    if (!active) {
      await close();
      return;
    }
    try {
      await _serial(host, () async {
        if (!active) return;
        final value = await host.call(
          SpiderMethod.proxy,
          params: {
            'op': 'session.renew',
            'sessionId': sessionId,
            'ttlMs': ttl.inMilliseconds,
          },
        );
        if (!active) return;
        if (value is! Map ||
            value['sessionId'] != sessionId ||
            value['expiresInMs'] != ttl.inMilliseconds) {
          throw StateError('Invalid proxyHttp renewal');
        }
        _arm();
      });
    } catch (_) {
      await close();
    }
  }

  Future<T> run<T>(Future<T> Function(SpiderHost host) action) =>
      _serial(host, () async {
        if (!active) throw StateError('proxyHttp playback owner is stale');
        try {
          final result = await action(host);
          if (!active) throw StateError('proxyHttp playback owner is stale');
          return result;
        } catch (_) {
          invalidate();
          rethrow;
        }
      });

  /// Invalidate synchronously; close must never consult a replacement host.
  void invalidate() {
    if (!_active) return;
    _active = false;
    _renewTimer?.cancel();
    _expiryTimer?.cancel();
    _lease?.release();
    _identities.revoke(token);
    if (identical(_owners[host], this)) _owners[host] = null;
  }

  Future<void> close() {
    invalidate();
    return _closing ??= _serial(host, () async {
      if (!host.process.isRunning ||
          !identical(supervisor.hostFor(siteKey), host)) {
        return;
      }
      try {
        await host.call(
          SpiderMethod.proxy,
          params: {'op': 'session.close', 'sessionId': sessionId},
        );
      } catch (_) {}
    });
  }

  bool ownsUrl(String url) {
    if (!active || _entryUrl == null) return false;
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == entryUrl.scheme &&
        uri.authority == entryUrl.authority &&
        uri.path == entryUrl.path &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment;
  }

  static String redact(String value) => redactSpiderProxyText(value);

  String scopeUrl(String url) {
    if (!active || _entryUrl == null) return url;
    return scopeLocalProxyUrl(
      url,
      entryUrl: entryUrl,
      ownBase: host.proxyHttp?.baseUrl,
    );
  }

  /// 把「指向本应用本地 `/proxy`」的地址映射进本会话的作用域代理。
  ///
  /// 判据只看语义、**不看端口**：站点常把端口写成未绑定时的 `0`（安卓那边
  /// 写死 9978 的同一种写法）。旧实现要求 authority 与 JVM 数据面完全相等，
  /// 于是这类地址被当成外站地址原样放行，请求最终打到一个不存在的端口，
  /// 报成「网络不可达或 DNS 失败」——看起来像网络问题，其实是地址没人接。
  ///
  /// 只接管回环主机 + `/proxy` 路径 + 无凭据无片段；其它地址一律原样返回，
  /// 避免把外站地址塞进站点自己的 proxy 通道。
  static String scopeLocalProxyUrl(
    String url, {
    required Uri entryUrl,
    Uri? ownBase,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.path != '/proxy' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return url;
    }
    // 两种形态才接管：
    // 1) 本会话数据面的精确地址（既有契约，媒体改写走这条）；
    // 2) 回环主机上的「应用动作」形态 `?do=…`（安卓在 /proxy 上按 do 分发）。
    // 无 do 的本机 /proxy 可能是用户自己的本地服务，保持不劫持。
    final exactOwnRoute =
        ownBase != null &&
        uri.scheme == ownBase.scheme &&
        uri.authority == ownBase.authority;
    final appAction =
        _isLoopbackHost(uri.host) && uri.queryParameters.containsKey('do');
    if (!exactOwnRoute && !appAction) return url;
    final queryIndex = url.indexOf('?');
    return entryUrl.toString() +
        (queryIndex < 0 ? '' : url.substring(queryIndex));
  }

  static bool _isLoopbackHost(String host) {
    final value = host.trim().toLowerCase();
    return value == '127.0.0.1' ||
        value == 'localhost' ||
        value == '::1' ||
        value == '[::1]';
  }
}
