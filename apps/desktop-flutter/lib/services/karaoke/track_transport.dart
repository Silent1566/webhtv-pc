import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/karaoke/ultrastar_parser.dart';

abstract class KaraokeTransport {
  Future<KaraokeResponse> get(Uri uri);
  Future<KaraokeResponse> post(Uri uri, Map<String, String> form);
}

abstract class KaraokeRequestTransport implements KaraokeTransport {
  Future<KaraokeResponse> request(
    Uri uri, {
    String method = 'GET',
    Map<String, String> form = const {},
    Map<String, String> headers = const {},
    KaraokeCancellation? cancellation,
  });
}

class KaraokeCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const KaraokeCancelled();
  }
}

class KaraokeResponse {
  const KaraokeResponse({
    required this.status,
    required this.body,
    this.contentType = '',
  });
  final int status;
  final String body, contentType;
  bool get ok => status >= 200 && status < 300;
  String checkedText({int maxBytes = 512 * 1024, bool allowTrackBody = false}) {
    if (!ok) throw KaraokeTrackException('http $status');
    if (utf8.encode(body).length > maxBytes)
      throw const KaraokeTrackException('track too large');
    final type = contentType.toLowerCase();
    if (type.isNotEmpty &&
        !['text', 'html', 'xml', 'json'].any(type.contains)) {
      var validTrack = false;
      if (allowTrackBody && UltraStarParser.looksLikeUltraStar(body)) {
        try {
          validTrack = UltraStarParser.parseStrict(body).hasScoredNotes;
        } catch (_) {}
      }
      if (!validTrack) throw const KaraokeTrackException('not text');
    }
    return body;
  }
}

class KaraokeTrackException implements Exception {
  const KaraokeTrackException(this.message);
  final String message;
  @override
  String toString() => message;
}

class KaraokeCancelled implements Exception {
  const KaraokeCancelled();
  @override
  String toString() => 'cancelled';
}

class CheckedKaraokeTransport implements KaraokeTransport {
  CheckedKaraokeTransport(
    this.inner, {
    this.cancellation,
    this.cookie = '',
    this.cookieHost = '',
    this.allowTrackBody = false,
  });
  final KaraokeTransport inner;
  final KaraokeCancellation? cancellation;
  final String cookie, cookieHost;
  final bool allowTrackBody;
  Future<KaraokeResponse> _request(
    Uri uri,
    String method,
    Map<String, String> form,
  ) async {
    cancellation?.throwIfCancelled();
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty)
      throw const KaraokeTrackException('invalid url');
    final headers = <String, String>{
      if (cookie.isNotEmpty && uri.host == cookieHost) 'Cookie': cookie,
    };
    final future = inner is KaraokeRequestTransport
        ? (inner as KaraokeRequestTransport).request(
            uri,
            method: method,
            form: form,
            headers: headers,
            cancellation: cancellation,
          )
        : method == 'POST'
        ? inner.post(uri, form)
        : inner.get(uri);
    final response = await Future.any<KaraokeResponse>([
      future,
      if (cancellation != null)
        cancellation!.whenCancelled.then((_) => throw const KaraokeCancelled()),
    ]);
    cancellation?.throwIfCancelled();
    response.checkedText(allowTrackBody: allowTrackBody);
    return response;
  }

  @override
  Future<KaraokeResponse> get(Uri uri) => _request(uri, 'GET', const {});
  @override
  Future<KaraokeResponse> post(Uri uri, Map<String, String> form) =>
      _request(uri, 'POST', form);
}

class HttpKaraokeTransport implements KaraokeRequestTransport {
  HttpKaraokeTransport({
    this.timeout = const Duration(seconds: 20),
    http.Client? client,
  }) : _client = client ?? http.Client();
  final Duration timeout;
  final http.Client _client;
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WebHTV-PC/0.1';
  @override
  Future<KaraokeResponse> get(Uri uri) => request(uri);
  @override
  Future<KaraokeResponse> post(Uri uri, Map<String, String> form) =>
      request(uri, method: 'POST', form: form);
  @override
  Future<KaraokeResponse> request(
    Uri uri, {
    String method = 'GET',
    Map<String, String> form = const {},
    Map<String, String> headers = const {},
    KaraokeCancellation? cancellation,
  }) async {
    final abort = Completer<void>();
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    cancellation?.whenCancelled.then((_) {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      cancellation?.throwIfCancelled();
      var current = uri;
      var currentMethod = method;
      for (var hop = 0; hop <= 5; hop++) {
        cancellation?.throwIfCancelled();
        if (!['http', 'https'].contains(current.scheme) ||
            current.host.isEmpty ||
            current.userInfo.isNotEmpty)
          throw const KaraokeTrackException('invalid redirect url');
        final request = http.AbortableRequest(
          currentMethod,
          current,
          abortTrigger: abort.future,
        )..followRedirects = false;
        request.headers['User-Agent'] = userAgent;
        for (final entry in headers.entries) {
          final sensitive = [
            'cookie',
            'authorization',
          ].contains(entry.key.toLowerCase());
          if (!sensitive ||
              current.host == uri.host && current.scheme == uri.scheme)
            request.headers[entry.key] = entry.value;
        }
        if (currentMethod == 'POST') request.bodyFields = form;
        final response = await _client.send(request);
        final location = response.headers['location'];
        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            location != null) {
          await response.stream.drain<void>();
          if (hop == 5) throw const KaraokeTrackException('redirect limit');
          current = current.resolve(location);
          if (response.statusCode == 303 ||
              currentMethod == 'POST' &&
                  [301, 302].contains(response.statusCode))
            currentMethod = 'GET';
          continue;
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          cancellation?.throwIfCancelled();
          if (bytes.length + chunk.length > 512 * 1024) {
            if (!abort.isCompleted) abort.complete();
            throw const KaraokeTrackException('track too large');
          }
          bytes.addAll(chunk);
        }
        return KaraokeResponse(
          status: response.statusCode,
          body: utf8.decode(bytes, allowMalformed: false),
          contentType: response.headers['content-type'] ?? '',
        );
      }
      throw const KaraokeTrackException('redirect limit');
    } on http.RequestAbortedException {
      if (cancellation?.isCancelled ?? false) throw const KaraokeCancelled();
      throw const KaraokeTrackException('request timeout');
    } finally {
      timer.cancel();
    }
  }

  void close() => _client.close();
}
