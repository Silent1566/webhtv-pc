/// 严格但有界的 HTTP/1.1 容错读取器（仅用于**已核验的本机转发端点**）。
///
/// 为什么需要它：受管安卓媒体链路上，guest 的 `/proxy` 应答者（网盘系 CDN 转发）
/// 会把上游响应的分帧头逐字转发两遍（实测同一响应出现两条 `Content-Length: 1024`），
/// Dart 的 `HttpClient` 在解析阶段直接拒绝，代理只能把 502 交出去。修不了对方
/// 设备时，唯一不放松全局策略的做法是：只用一次、只对**已授权并已核验**的
/// `127.0.0.1:<转发端口>` 目标做一次严格读头重试。
///
/// 严格性边界（本文件即协议契约）：
/// - 只接受 `http://127.0.0.1:<port>`，不接受任意主机/端口/TLS；
/// - 响应头整体上限 32 KiB、最多 128 个头、必须 CRLF 分行；
/// - 单值头重复时**只有逐字节相同**才折叠：`Content-Length`、`Content-Type`、
///   `Content-Range`、`Accept-Ranges`、`ETag`、`Last-Modified`、`Cache-Control`；
///   取值不同即失败关闭；
/// - 其它头（`Set-Cookie` 等列表头）不折叠，直接丢弃——代理本来也不转发；
/// - 3xx 不跟随（调用方明确选择失败关闭）；
/// - 正文流式输出，绝不整段缓冲；无法判定的分帧（同时声明 TE 与 CL、非 chunked
///   的 TE、非法 chunk）一律失败关闭。
///
/// 所有异常消息都是固定的脱敏文案：不含 Header 取值、URL、query、凭据。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// 响应头整体字节上限（含状态行与终止 CRLF）。
const int tolerantMaxResponseHeadBytes = 32 * 1024;

/// 响应头行数上限。
const int tolerantMaxResponseHeaders = 128;

/// 单值响应头：重复时只有逐字节相同才折叠，否则失败关闭。
const Set<String> tolerantSingleValuedHeaders = {
  'content-length',
  'content-type',
  'content-range',
  'accept-ranges',
  'etag',
  'last-modified',
  'cache-control',
};

/// 严格解析拒绝「重复/冲突分帧头」这一类失败的识别与稳定文案。
///
/// 只认 `HttpException` 且消息同时点名分帧头与缺陷词：把别的网络错误
/// （连接被重置、DNS、超时）留在原来的 `请求上游失败：<类型>` 文案上。
class UpstreamFramingFailure {
  const UpstreamFramingFailure._();

  /// 面向用户的定语文案：可定位到「是哪一类不合规」，且不含任何头取值。
  static const String message = '上游响应头不合规（重复或冲突的 Content-Length）：PC 严格模式拒绝解析';

  static bool isDuplicateFraming(Object error) {
    if (error is! HttpException) return false;
    final text = error.message.toLowerCase();
    final namesFraming =
        text.contains('content-length') || text.contains('transfer-encoding');
    if (!namesFraming) return false;
    return text.contains('more than once') ||
        text.contains('duplicate') ||
        text.contains('invalid') ||
        text.contains('malformed');
  }
}

/// 容错读取失败类别；文案已脱敏，调用方据此决定给客户端的状态/文案。
enum TolerantHttpFailureKind {
  framing,
  redirect,
  protocol,
  connection,
  timeout,
}

class TolerantHttpException implements IOException {
  TolerantHttpException(this.kind, this.message);

  final TolerantHttpFailureKind kind;

  final String message;

  @override
  String toString() => message;
}

/// 解析完成的响应头 + 流式正文。
class TolerantHttpResponse {
  TolerantHttpResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.contentLength,
    required this.body,
    required this.onClose,
  });

  final int statusCode;
  final String reasonPhrase;

  /// 只包含单值头（已按规则折叠）；列表头一律不出现。
  final Map<String, String> headers;

  /// 声明的正文长度；-1 表示未知（chunked 或读到连接关闭）。
  final int contentLength;

  final Stream<List<int>> body;

  /// 释放 socket 的固定回调（由读取器注入）。
  final Future<void> Function() onClose;

  /// 释放 socket；可在正文未读完时调用（直接断开）。
  Future<void> close() => onClose();
}

/// 一次性的严格读取器；实例无状态，可复用。
class TolerantHttpReader {
  const TolerantHttpReader({
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  });

  final Duration connectTimeout;
  final Duration idleTimeout;

  Future<TolerantHttpResponse> send({
    required Uri wireTarget,
    required String method,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    if (wireTarget.scheme != 'http') {
      throw TolerantHttpException(
        TolerantHttpFailureKind.protocol,
        '容错读取只接受 http 转发端点',
      );
    }
    if (wireTarget.host != '127.0.0.1') {
      throw TolerantHttpException(
        TolerantHttpFailureKind.protocol,
        '容错读取只接受本机转发端点 127.0.0.1',
      );
    }
    if (wireTarget.userInfo.isNotEmpty) {
      throw TolerantHttpException(
        TolerantHttpFailureKind.protocol,
        '转发端点不得包含 userinfo',
      );
    }
    if (method != 'GET' && method != 'HEAD') {
      throw TolerantHttpException(
        TolerantHttpFailureKind.protocol,
        '容错读取只接受 GET/HEAD',
      );
    }

    final requestBytes = _buildRequest(wireTarget, method, headers);

    final Socket socket;
    try {
      socket = await Socket.connect(
        wireTarget.host,
        wireTarget.port,
        timeout: connectTimeout,
      ).timeout(timeout);
    } on TimeoutException {
      throw TolerantHttpException(TolerantHttpFailureKind.timeout, '连接上游超时');
    } catch (_) {
      throw TolerantHttpException(TolerantHttpFailureKind.connection, '连接上游失败');
    }

    final source = _ResponseSource(socket, idleTimeout);
    try {
      socket.add(requestBytes);
      try {
        await socket.flush().timeout(idleTimeout);
      } catch (_) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.connection,
          '发送上游请求失败',
        );
      }
      final head = await source
          .readHead(tolerantMaxResponseHeadBytes)
          .timeout(timeout);
      final parsed = _parseHead(head);
      if (_isRedirect(parsed.statusCode)) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.redirect,
          '上游在容错读取路径返回重定向：拒绝跟随',
        );
      }
      final bodyAllowed =
          method != 'HEAD' &&
          parsed.statusCode >= 200 &&
          parsed.statusCode != 204 &&
          parsed.statusCode != 304;
      final body = bodyAllowed
          ? source.body(
              chunked: parsed.chunked,
              contentLength: parsed.contentLength,
            )
          : const Stream<List<int>>.empty();
      // 无正文响应（HEAD/204/304）不会有人订阅 body：当场断开连接。
      if (!bodyAllowed) await source.dispose();
      return TolerantHttpResponse(
        statusCode: parsed.statusCode,
        reasonPhrase: parsed.reasonPhrase,
        headers: parsed.headers,
        contentLength: parsed.contentLength,
        body: body,
        onClose: source.dispose,
      );
    } catch (error) {
      await source.dispose();
      rethrow;
    }
  }

  static Uint8List _buildRequest(
    Uri wireTarget,
    String method,
    Map<String, String> headers,
  ) {
    final port = wireTarget.hasPort ? wireTarget.port : 80;
    final target = wireTarget.path.isEmpty ? '/' : wireTarget.path;
    final query = wireTarget.hasQuery ? '?${wireTarget.query}' : '';
    final buffer = StringBuffer('$method $target$query HTTP/1.1\r\n');
    buffer.write('Host: ${wireTarget.host}:$port\r\n');
    // 请求即断开：容错路径不复用连接，避免半读状态污染下一个请求。
    buffer.write('Connection: close\r\n');
    for (final entry in headers.entries) {
      final name = entry.key;
      final value = entry.value;
      final lower = name.toLowerCase();
      // 传输级必需头由本读取器决定，调用方注入的不得覆盖或重复。
      if (lower == 'host' ||
          lower == 'connection' ||
          lower == 'content-length' ||
          lower == 'transfer-encoding') {
        continue;
      }
      if (!_headerNamePattern.hasMatch(name) ||
          value.contains('\r') ||
          value.contains('\n') ||
          value.codeUnits.any((unit) => unit < 0x20 && unit != 0x09)) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '请求头包含非法字符',
        );
      }
      buffer.write('$name: $value\r\n');
    }
    buffer.write('\r\n');
    return Uint8List.fromList(latin1.encode(buffer.toString()));
  }

  static final RegExp _headerNamePattern = RegExp(
    r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$",
  );

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static _ParsedHead _parseHead(List<int> bytes) {
    final text = latin1.decode(bytes);
    if (!text.endsWith('\r\n\r\n')) {
      throw TolerantHttpException(
        TolerantHttpFailureKind.protocol,
        '上游响应头不以 CRLF 结束',
      );
    }
    final lines = text.substring(0, text.length - 4).split('\r\n');
    for (final line in lines) {
      if (line.contains('\n') || line.contains('\r')) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游响应头必须使用 CRLF 分行',
        );
      }
    }
    if (lines.isEmpty) {
      throw TolerantHttpException(
        TolerantHttpFailureKind.protocol,
        '上游响应缺少状态行',
      );
    }
    final status = _parseStatusLine(lines.first);

    final raw = <String, List<String>>{};
    var count = 0;
    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      if (line.startsWith(' ') || line.startsWith('\t')) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游响应头不支持折行',
        );
      }
      final colon = line.indexOf(':');
      if (colon <= 0) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游响应头格式非法',
        );
      }
      final name = line.substring(0, colon);
      if (!_headerNamePattern.hasMatch(name)) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游响应头名称非法',
        );
      }
      final value = line.substring(colon + 1);
      raw.putIfAbsent(name.toLowerCase(), () => <String>[]).add(value);
      count += 1;
      if (count > tolerantMaxResponseHeaders) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游响应头数量超过 $tolerantMaxResponseHeaders 上限',
        );
      }
    }

    final headers = <String, String>{};
    for (final entry in raw.entries) {
      if (!tolerantSingleValuedHeaders.contains(entry.key)) continue;
      headers[entry.key] = _collapseSingle(entry.key, entry.value);
    }

    final chunked = _framingOf(raw);
    final contentLength = chunked
        ? -1
        : headers.containsKey('content-length')
        ? _parseContentLength(headers['content-length']!)
        : -1;
    if (status >= 100 && status < 200) {
      throw TolerantHttpException(
        TolerantHttpFailureKind.protocol,
        '容错读取不接受 1xx 中间响应',
      );
    }
    return _ParsedHead(
      statusCode: status,
      reasonPhrase: _reasonOf(lines.first),
      headers: headers,
      contentLength: contentLength,
      chunked: chunked,
    );
  }

  /// 只有**逐字节相同**的重复才折叠（`Content-Length: 2` 与
  /// `Content-Length:  2` 是两个不同的声明，折叠会掩盖真实的长度分歧）；
  /// 返回值去掉 OWS 供分帧使用。
  static String _collapseSingle(String name, List<String> values) {
    final first = values.first;
    for (final value in values) {
      if (value != first) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.framing,
          '上游响应的 ${_displayName(name)} 重复且取值不一致：严格模式拒绝解析',
        );
      }
    }
    return first.trim();
  }

  static int _parseContentLength(String value) {
    try {
      return int.parse(value);
    } on FormatException {
      throw TolerantHttpException(
        TolerantHttpFailureKind.framing,
        '上游 Content-Length 取值非法：拒绝解析',
      );
    }
  }

  static String _displayName(String lower) {
    switch (lower) {
      case 'content-length':
        return 'Content-Length';
      case 'content-type':
        return 'Content-Type';
      case 'content-range':
        return 'Content-Range';
      case 'accept-ranges':
        return 'Accept-Ranges';
      case 'etag':
        return 'ETag';
      case 'last-modified':
        return 'Last-Modified';
      case 'cache-control':
        return 'Cache-Control';
    }
    return lower;
  }

  /// 判定正文分帧；出现歧义一律失败关闭（请求走私面）。
  static bool _framingOf(Map<String, List<String>> raw) {
    final te = raw['transfer-encoding'];
    final cl = raw['content-length'];
    if (te != null) {
      if (cl != null) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.framing,
          '上游同时声明 Transfer-Encoding 与 Content-Length：拒绝解析',
        );
      }
      final values = te.map((value) => value.trim().toLowerCase()).toSet();
      if (values.length > 1) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.framing,
          '上游响应的 Transfer-Encoding 重复且取值不一致：拒绝解析',
        );
      }
      // 只认单一的 chunked：gzip/deflate 等编码我们不实现解码，
      // 带多种编码的声明一律失败关闭，绝不把未解码字节当媒体正文转发。
      if (values.single == 'chunked') return true;
      throw TolerantHttpException(
        TolerantHttpFailureKind.protocol,
        '容错读取只支持 chunked 传输编码',
      );
    }
    if (cl != null) {
      for (final value in cl.map((value) => value.trim())) {
        if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
          throw TolerantHttpException(
            TolerantHttpFailureKind.framing,
            '上游 Content-Length 取值非法：拒绝解析',
          );
        }
      }
    }
    return false;
  }

  static int _parseStatusLine(String line) {
    final match = RegExp(r'^HTTP/1\.[0-9] ([0-9]{3})(?: .*)?$')
        .firstMatch(line);
    if (match == null) {
      throw TolerantHttpException(TolerantHttpFailureKind.protocol, '上游状态行非法');
    }
    return int.parse(match.group(1)!);
  }

  static String _reasonOf(String line) {
    final match = RegExp(r'^HTTP/1\.[0-9] [0-9]{3}(?: (.*))?$')
        .firstMatch(line);
    return match?.group(1) ?? '';
  }
}

class _ParsedHead {
  _ParsedHead({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.contentLength,
    required this.chunked,
  });

  final int statusCode;
  final String reasonPhrase;
  final Map<String, String> headers;
  final int contentLength;
  final bool chunked;
}

/// socket 字节源：已读未派发的字节留在待派发缓冲区，读头时不会吃掉正文。
class _ResponseSource {
  _ResponseSource(Socket socket, Duration idleTimeout)
    : _socket = socket,
      _iterator = StreamIterator<List<int>>(socket.timeout(idleTimeout));

  final Socket _socket;
  final StreamIterator<List<int>> _iterator;
  final List<int> _pending = <int>[];
  bool _eof = false;
  bool _disposed = false;

  Future<bool> _fill() async {
    if (_eof) return false;
    try {
      if (await _iterator.moveNext()) {
        _pending.addAll(_iterator.current);
        return true;
      }
    } on TimeoutException {
      throw TolerantHttpException(TolerantHttpFailureKind.timeout, '读取上游响应超时');
    } on TolerantHttpException {
      rethrow;
    } catch (_) {
      _eof = true;
      return false;
    }
    _eof = true;
    return false;
  }

  Future<List<int>> readHead(int limit) async {
    while (true) {
      final end = _indexOfHeadEnd();
      if (end > limit) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游响应头超过 32 KiB 上限',
        );
      }
      if (end > 0) {
        final head = _pending.sublist(0, end);
        _pending.removeRange(0, end);
        return head;
      }
      if (_pending.length > limit) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游响应头超过 32 KiB 上限',
        );
      }
      if (!await _fill()) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游在响应头结束前关闭连接',
        );
      }
    }
  }

  int _indexOfHeadEnd() {
    for (var index = 0; index + 3 < _pending.length; index++) {
      if (_pending[index] == 13 &&
          _pending[index + 1] == 10 &&
          _pending[index + 2] == 13 &&
          _pending[index + 3] == 10) {
        return index + 4;
      }
    }
    return -1;
  }

  Stream<List<int>> body({
    required bool chunked,
    required int contentLength,
  }) async* {
    try {
      if (chunked) {
        yield* _chunkedBody();
        return;
      }
      if (contentLength >= 0) {
        yield* _fixedBody(contentLength);
        return;
      }
      yield* _untilCloseBody();
    } finally {
      // 正文读完、出错、或被取消都要断开 socket（连接在所有路径上关闭）。
      await dispose();
    }
  }

  Stream<List<int>> _fixedBody(int length) async* {
    var remaining = length;
    while (remaining > 0) {
      final piece = await _readUpTo(remaining);
      if (piece.isEmpty) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游提前关闭连接：声明长度未满足',
        );
      }
      remaining -= piece.length;
      yield piece;
    }
  }

  Stream<List<int>> _untilCloseBody() async* {
    while (true) {
      final piece = await _readUpTo(64 * 1024);
      if (piece.isEmpty) return;
      yield piece;
    }
  }

  Stream<List<int>> _chunkedBody() async* {
    while (true) {
      final line = await _readLine(1024);
      final sizeText = line.split(';').first.trim();
      if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(sizeText)) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游 chunk 长度非法：拒绝解析',
        );
      }
      final size = int.parse(sizeText, radix: 16);
      if (size == 0) {
        // trailer：读到空行为止，条数有界。
        for (var index = 0; index < tolerantMaxResponseHeaders; index++) {
          final trailer = await _readLine(8 * 1024);
          if (trailer.isEmpty) return;
        }
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游 chunk trailer 超过上限',
        );
      }
      var remaining = size;
      while (remaining > 0) {
        final piece = await _readUpTo(remaining);
        if (piece.isEmpty) {
          throw TolerantHttpException(
            TolerantHttpFailureKind.protocol,
            '上游 chunk 数据不完整',
          );
        }
        remaining -= piece.length;
        yield piece;
      }
      final terminator = await _readLine(8);
      if (terminator.isNotEmpty) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游 chunk 结束符非法',
        );
      }
    }
  }

  Future<List<int>> _readUpTo(int max) async {
    while (_pending.isEmpty) {
      if (!await _fill()) return const <int>[];
    }
    final take = math.min(max, _pending.length);
    final piece = _pending.sublist(0, take);
    _pending.removeRange(0, take);
    return piece;
  }

  Future<String> _readLine(int limit) async {
    while (true) {
      for (var index = 0; index + 1 < _pending.length; index++) {
        if (_pending[index] == 13 && _pending[index + 1] == 10) {
          final line = latin1.decode(_pending.sublist(0, index));
          _pending.removeRange(0, index + 2);
          return line;
        }
      }
      if (_pending.length > limit) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游 chunk 行超过上限',
        );
      }
      if (!await _fill()) {
        throw TolerantHttpException(
          TolerantHttpFailureKind.protocol,
          '上游在 chunk 行结束前关闭连接',
        );
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _iterator.cancel();
    } catch (_) {}
    try {
      _socket.destroy();
    } catch (_) {}
  }
}
