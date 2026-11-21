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
    final uri = Uri.tryParse(url);
    final base = host.proxyHttp!.baseUrl;
    if (uri == null ||
        uri.scheme != base.scheme ||
        uri.authority != base.authority ||
        uri.path != '/proxy' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return url;
    }
    final queryIndex = url.indexOf('?');
    return entryUrl.toString() +
        (queryIndex < 0 ? '' : url.substring(queryIndex));
  }
}
