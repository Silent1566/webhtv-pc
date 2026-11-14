/// AI 补全客户端（`docs/phase6/design/04` §5）。
///
/// 上游对应实现是 `AiCompletionClient`。**请求规格构造与发送分离**：
/// `buildAiRequestSpec` 是纯函数，可在无网络环境下断言请求形态
/// （对齐 Phase 5 的「L2 用请求捕获断言请求形态」纪律）。
library;

import 'dart:async';

import 'log_service.dart';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/ai_config.dart';

/// 一次补全请求的规格。
class AiRequestSpec {
  const AiRequestSpec({
    required this.url,
    required this.body,
    required this.headers,
  });

  final String url;
  final Map<String, Object?> body;
  final Map<String, String> headers;
}

/// 输出 token 上限（对齐上游 `MAX_OUTPUT_TOKENS`）。
const int aiMaxOutputTokens = 4096;

/// Anthropic 的 API 版本头（对齐上游）。
const String aiAnthropicVersion = '2023-06-01';

/// 构造请求规格（`docs/phase6/design/04` §5.1）。
AiRequestSpec buildAiRequestSpec(AiConfig config, String prompt) {
  final safe = config.sanitized();
  final body = <String, Object?>{};
  final headers = <String, String>{'Content-Type': 'application/json'};

  switch (safe.protocol) {
    case AiProtocol.openAiChat:
      body['model'] = safe.model;
      body['messages'] = [
        {'role': 'user', 'content': prompt},
      ];
      headers['Authorization'] = 'Bearer ${safe.apiKey}';
    case AiProtocol.anthropicMessages:
      body['model'] = safe.model;
      body['max_tokens'] = aiMaxOutputTokens;
      body['messages'] = [
        {'role': 'user', 'content': prompt},
      ];
      headers['x-api-key'] = safe.apiKey;
      headers['anthropic-version'] = aiAnthropicVersion;
    case AiProtocol.geminiNative:
      body['contents'] = [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
          ],
        },
      ];
      body['generationConfig'] = {'maxOutputTokens': aiMaxOutputTokens};
      headers['x-goog-api-key'] = safe.apiKey;
    default:
      body['model'] = safe.model;
      body['input'] = prompt;
      body['max_output_tokens'] = aiMaxOutputTokens;
      headers['Authorization'] = 'Bearer ${safe.apiKey}';
  }

  final userAgent = _sanitizeUserAgent(safe.customUserAgent);
  if (userAgent.isNotEmpty) headers['User-Agent'] = userAgent;

  return AiRequestSpec(url: safe.completionUrl, body: body, headers: headers);
}

/// 用户代理清洗：含控制字符时整串丢弃（对齐上游 `sanitizeUserAgent`）。
String _sanitizeUserAgent(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  for (final code in value.codeUnits) {
    if ((code < 0x20 && code != 0x09) || code == 0x7F) return '';
  }
  return value;
}

/// 从响应体里抽取补全文本（`docs/phase6/design/04` §5.2）。
///
/// 按协议各一套，**且交叉兜底**：中转站常返回与所选协议不符的结构，
/// 兜底让"配置填得不够准"也能工作。
String extractAiCompletionText(String body, AiConfig config) {
  if (body.trim().isEmpty) return '';
  if (const LineSplitter()
      .convert(body)
      .any((line) => line.startsWith('data:'))) {
    return _sseText(body, config);
  }
  final safe = config.sanitized();

  String byProtocol() => switch (safe.protocol) {
    AiProtocol.openAiChat => _openAiChatText(body),
    AiProtocol.anthropicMessages => _anthropicText(body),
    AiProtocol.geminiNative => _geminiText(body),
    _ => _openAiResponsesText(body),
  };

  final primary = byProtocol();
  if (primary.isNotEmpty) return primary;

  // 交叉兜底：依次试其余三种。
  for (final text in [
    _openAiResponsesText(body),
    _openAiChatText(body),
    _anthropicText(body),
    _geminiText(body),
  ]) {
    if (text.isNotEmpty) return text;
  }
  return '';
}

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

Map<String, Object?>? _asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

List<Object?> _asList(Object? value) => value is List ? value : const [];

/// `output_text` → `output[].content[].text`。
String _openAiResponsesText(String body) {
  final root = _asMap(_decode(body));
  if (root == null) return '';
  final direct = root['output_text'];
  if (direct is String && direct.trim().isNotEmpty) return direct.trim();
  final buffer = StringBuffer();
  for (final item in _asList(root['output'])) {
    final map = _asMap(item);
    if (map == null) continue;
    _appendContent(buffer, map['content']);
  }
  return buffer.toString().trim();
}

/// `choices[].message.content` / `choices[].delta.content` / `choices[].text`。
String _openAiChatText(String body) {
  final root = _asMap(_decode(body));
  if (root == null) return '';
  final buffer = StringBuffer();
  for (final choice in _asList(root['choices'])) {
    final map = _asMap(choice);
    if (map == null) continue;
    _appendContent(buffer, _asMap(map['message'])?['content']);
    _appendContent(buffer, _asMap(map['delta'])?['content']);
    final text = map['text'];
    if (text is String && text.trim().isNotEmpty) {
      _appendLine(buffer, text);
    }
  }
  return buffer.toString().trim();
}

/// `completion` → `content[].text`。
String _anthropicText(String body) {
  final root = _asMap(_decode(body));
  if (root == null) return '';
  final buffer = StringBuffer();
  final completion = root['completion'];
  if (completion is String && completion.trim().isNotEmpty) {
    _appendLine(buffer, completion);
  }
  for (final item in _asList(root['content'])) {
    final map = _asMap(item);
    if (map != null) {
      _appendText(map, buffer);
      continue;
    }
    if (item is String && item.trim().isNotEmpty) _appendLine(buffer, item);
  }
  return buffer.toString().trim();
}

/// `text` → `candidates[].content.parts[].text`。
String _geminiText(String body) {
  final root = _asMap(_decode(body));
  if (root == null) return '';
  final buffer = StringBuffer();
  final text = root['text'];
  if (text is String && text.trim().isNotEmpty) _appendLine(buffer, text);
  for (final candidate in _asList(root['candidates'])) {
    final map = _asMap(candidate);
    if (map == null) continue;
    final content = _asMap(map['content']);
    if (content == null) continue;
    for (final part in _asList(content['parts'])) {
      final partMap = _asMap(part);
      if (partMap != null) {
        _appendText(partMap, buffer);
        continue;
      }
      if (part is String && part.trim().isNotEmpty) _appendLine(buffer, part);
    }
  }
  return buffer.toString().trim();
}

/// Android `appendText`（`AiCompletionClient.java:423–433`）的字段顺序：
/// 先在 `text/output_text/value/arguments` 里取**第一个有效直接字符串**，
/// 再递归非原始 `text`/`output_text`，最后 `content` 与 `parts`。
///
/// 返回**未清洗**的叶子文本：段落式抽取交给 `_paragraph` 清洗，原生增量
/// 分片交给 `_increment` 逐字保真——两种语义不共用同一层 trim。
List<String> _textLeaves(Map<String, Object?> map, {bool keepBlank = false}) {
  final leaves = <String>[];
  for (final key in const ['text', 'output_text', 'value', 'arguments']) {
    final value = map[key];
    // 段落语义取「首个有效直接字符串」；原生增量分片里纯空白也是内容。
    if (value is String && (keepBlank ? value.isNotEmpty : value.trim().isNotEmpty)) {
      leaves.add(value);
      break;
    }
  }
  for (final key in const ['text', 'output_text']) {
    final value = map[key];
    if (value is! String) {
      leaves.addAll(_contentLeaves(value, keepBlank: keepBlank));
    }
  }
  leaves.addAll(_contentLeaves(map['content'], keepBlank: keepBlank));
  leaves.addAll(_contentLeaves(map['parts'], keepBlank: keepBlank));
  return leaves;
}

/// Android `appendContent`（`:435–450`）：字符串原样、对象递归、数组逐项。
List<String> _contentLeaves(Object? content, {bool keepBlank = false}) {
  if (content == null) return const [];
  if (content is String) return [content];
  final map = _asMap(content);
  if (map != null) return _textLeaves(map, keepBlank: keepBlank);
  final leaves = <String>[];
  for (final item in _asList(content)) {
    final itemMap = _asMap(item);
    if (itemMap != null) {
      leaves.addAll(_textLeaves(itemMap, keepBlank: keepBlank));
      continue;
    }
    if (item is String) leaves.add(item);
  }
  return leaves;
}

/// 结构化段落：逐段 trim 后以换行连接（Android `appendTextValue`）。
String _paragraph(Object? content) => _contentLeaves(content)
    .map((text) => text.trim())
    .where((text) => text.isNotEmpty)
    .join('\n');

/// 原生增量分片：逐字拼接，不 trim、不加分隔符（跨事件空白必须保真）。
String _increment(Object? content) =>
    _contentLeaves(content, keepBlank: true).join();

/// Chat 代理：字符串分片原样，结构化包装走段落语义。
String _chatContent(Object? content) =>
    content is String ? content : _paragraph(content);

void _appendText(Map<String, Object?> map, StringBuffer buffer) {
  for (final leaf in _textLeaves(map)) {
    _appendLine(buffer, leaf);
  }
}

void _appendContent(StringBuffer buffer, Object? content) {
  for (final leaf in _contentLeaves(content)) {
    _appendLine(buffer, leaf);
  }
}

void _appendLine(StringBuffer buffer, String text) {
  final value = text.trim();
  if (value.isEmpty) return;
  if (buffer.isNotEmpty) buffer.write('\n');
  buffer.write(value);
}

/// 一次补全的结果。
class AiCompletionResult {
  const AiCompletionResult({
    required this.ok,
    required this.statusCode,
    required this.text,
    required this.message,
    this.detail = '',
  });

  final bool ok;
  final int statusCode;
  final String text;

  /// 失败原因（用户可读）；成功时为空。
  final String message;

  /// 失败的技术细节（异常类型/内容类型/结构轮廓），**只进日志不进 UI**。
  final String detail;

  static const AiCompletionResult configIncomplete = AiCompletionResult(
    ok: false,
    statusCode: 0,
    text: '',
    message: 'AI 服务未配置完成（需要启用、端点、API Key、模型）',
  );
}

class AiCancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

class AiCompletionClient {
  AiCompletionClient({http.Client? client, this.log})
    : _client = client ?? http.Client();
  final http.Client _client;

  /// 可选日志：给了就为**每一次** AI 调用记一条脱敏记录（任务/协议/host/
  /// 模型/超时/耗时/状态/输出字符数）。不记 prompt 正文、不记 API Key。
  final LogService? log;

  /// 进程级默认日志：AppState 启动时注入一次。
  ///
  /// 存在的理由：AI 调用散落在推荐/片名/季集/字幕等多个服务里，逐个构造点
  /// 传 `log` 很容易漏（漏了就"这条调用没有任何日志"）。给一个默认 sink，
  /// 让**所有** `AiCompletionClient` 调用默认都留痕；显式传入仍优先。
  static LogService? defaultLog;

  LogService? get resolvedLog => log ?? defaultLog;
  static const Duration defaultTimeout = Duration(seconds: 105);

  /// 统一入口：**先记录本次调用的日志**，再执行协议请求。
  Future<AiCompletionResult> complete({
    required AiConfig config,
    required String prompt,
    Duration? timeout,
    AiCancellationToken? cancellationToken,
    String task = 'ai',
  }) async {
    final started = DateTime.now();
    final result = await _send(
      config: config,
      prompt: prompt,
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    final summary =
        'ai[$task] ${_describe(config)} '
        'status=${result.statusCode} ok=${result.ok} '
        'ms=${DateTime.now().difference(started).inMilliseconds} '
        'chars=${result.text.length}'
        '${result.ok ? '' : ' message=${result.message}'}'
        '${result.detail.isEmpty ? '' : ' detail=${result.detail}'}';
    if (result.ok) {
      resolvedLog?.info(summary, scope: 'ai');
    } else {
      // 失败用 warning，便于在日志页按级别过滤出"哪一次 AI 调用挂了、为什么"。
      resolvedLog?.warning(summary, scope: 'ai');
    }
    return result;
  }

  /// 日志用的脱敏描述：只带协议/host/模型/超时，不含端点路径、Key 与正文。
  String _describe(AiConfig config) {
    final safe = config.sanitized();
    final host = Uri.tryParse(safe.endpoint)?.host ?? '';
    return 'protocol=${safe.protocol} host=$host model=${safe.model} '
        'timeout=${safe.timeout.inSeconds}s';
  }

  Future<AiCompletionResult> _send({
    required AiConfig config,
    required String prompt,
    Duration? timeout,
    AiCancellationToken? cancellationToken,
  }) async {
    final safe = config.sanitized();
    // 未显式给超时就用配置里的值（默认 5 分钟，用户可在 AI 设置里改）。
    final effectiveTimeout = timeout ?? safe.timeout;
    if (!safe.isReady) return AiCompletionResult.configIncomplete;
    if (cancellationToken?.isCancelled ?? false) return _failure('请求已取消');
    final abort = Completer<void>();
    void abortRequest() {
      if (!abort.isCompleted) abort.complete();
    }

    final deadline = Completer<AiCompletionResult>();
    final timer = Timer(effectiveTimeout, () {
      abortRequest();
      deadline.complete(_failure('请求超时'));
    });
    try {
      final spec = buildAiRequestSpec(safe, prompt);
      final request =
          http.AbortableRequest(
              'POST',
              Uri.parse(spec.url),
              abortTrigger: abort.future,
            )
            ..headers.addAll(spec.headers)
            ..body = jsonEncode(spec.body);
      final responseFuture = () async {
        final streamed = await _client.send(request);
        final response = await http.Response.fromStream(streamed);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return _failure('HTTP ${response.statusCode}', response.statusCode);
        }
        final body = utf8.decode(response.bodyBytes, allowMalformed: true);
        final contentType = response.headers['content-type'] ?? '';
        if (_hasAiError(body)) {
          return _failure(
            'AI 接口返回错误',
            response.statusCode,
            'content-type=$contentType shape=${describeAiBodyShape(body)}',
          );
        }
        final text = extractAiCompletionText(body, safe);
        if (text.isEmpty) {
          // 最常见的真实原因：中转返回 HTML 错误页 / SSE / 另一套协议结构。
          // 把形状写进日志，用户不必再猜"端点与协议"。
          return _failure(
            '接口已响应但没有解析到 AI 输出（协议=${safe.protocol}，'
            '响应 ${describeAiBodyShape(body)}）',
            response.statusCode,
            'content-type=$contentType shape=${describeAiBodyShape(body)} '
                'protocol=${safe.protocol}',
          );
        }
        return AiCompletionResult(
          ok: true,
          statusCode: response.statusCode,
          text: text,
          message: '',
        );
      }();
      return await Future.any([
        responseFuture,
        deadline.future,
        if (cancellationToken != null)
          cancellationToken.whenCancelled.then((_) {
            abortRequest();
            return _failure('请求已取消');
          }),
      ]);
    } on http.RequestAbortedException {
      return _failure(
        cancellationToken?.isCancelled == true ? '请求已取消' : '请求超时',
      );
    } on TimeoutException {
      abortRequest();
      return _failure('请求超时');
    } on SocketException catch (error) {
      return _failure(
        '网络错误，请检查网络与端点',
        0,
        'SocketException: ${error.message}',
      );
    } on FormatException catch (error) {
      return _failure(
        '响应格式不符合所选协议，可尝试切换协议（Chat / Responses / Anthropic / Gemini）',
        0,
        'FormatException: ${error.message}',
      );
    } catch (error) {
      // 以前这里吞掉了真实异常，用户只看到"请检查端点与协议"，日志里也没有
      // 任何细节——按"AI 调用必须留痕"的要求，异常类型与消息必须落到日志。
      return _failure(
        '请求失败，请检查端点与协议',
        0,
        '${error.runtimeType}: $error',
      );
    } finally {
      timer.cancel();
    }
  }

  void close() => _client.close();
}

AiCompletionResult _failure(String message, [int code = 0, String detail = '']) =>
    AiCompletionResult(
      ok: false,
      statusCode: code,
      text: '',
      message: message,
      detail: detail,
    );

/// 响应体的**结构轮廓**（只描述形状，不含正文）：区分 HTML 错误页、SSE、
/// JSON 顶层键，用于失败日志定位"端点/协议不匹配"。
String describeAiBodyShape(String body) {
  final text = body.trimLeft();
  if (text.isEmpty) return 'empty';
  if (text.startsWith('<')) return 'html(len=${body.length})';
  if (text.startsWith('data:') || text.contains('\ndata:')) {
    return 'sse(len=${body.length})';
  }
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      final keys = decoded.keys.take(6).map((k) => '$k').join(',');
      return 'json(keys=[$keys],len=${body.length})';
    }
    return 'json(${decoded.runtimeType},len=${body.length})';
  } catch (_) {
    return 'text(len=${body.length})';
  }
}

Iterable<String> _ssePayloads(String body) sync* {
  final data = <String>[];
  for (final line in const LineSplitter().convert(body)) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield data.join('\n');
      data.clear();
    } else if (line.startsWith('data:')) {
      final value = line.substring(5);
      data.add(value.startsWith(' ') ? value.substring(1) : value);
    }
  }
  if (data.isNotEmpty) yield data.join('\n');
}

bool _hasAiError(String body) {
  bool isError(Object? value) {
    final root = _asMap(value);
    if (root == null) return false;
    final type = root['type'];
    return root['error'] != null ||
        type == 'error' ||
        type == 'response.failed' ||
        type == 'response.incomplete';
  }

  return isError(_decode(body)) ||
      _ssePayloads(body).any((payload) {
        if (payload.trim() == '[DONE]') return false;
        final decoded = _decode(payload);
        return decoded is! Map || isError(decoded);
      });
}

String _sseText(String body, AiConfig config) {
  if (_hasAiError(body)) return '';
  final chunks = StringBuffer();
  String snapshot = '';
  for (final payload in _ssePayloads(body)) {
    if (payload.trim() == '[DONE]') break;
    final root = _asMap(_decode(payload));
    if (root == null) continue;
    final type = root['type'];
    if (type == 'response.output_text.delta') {
      chunks.write(_increment(root['delta']));
    } else if (type == 'response.output_text.done') {
      snapshot = _paragraph(root['text']);
    } else if (type == 'response.completed') {
      snapshot = extractAiCompletionText(jsonEncode(root['response']), config);
    } else if (type == 'content_block_delta') {
      final delta = _asMap(root['delta']);
      if (delta?['type'] == 'text_delta') {
        chunks.write(_increment(delta?['text']));
      }
    } else if (type == 'content_block_start') {
      final block = _asMap(root['content_block']);
      if (block?['type'] == 'text') chunks.write(_increment(block?['text']));
    } else if (root['choices'] is List) {
      for (final choice in _asList(root['choices'])) {
        final map = _asMap(choice);
        final delta = _asMap(map?['delta']);
        final message = _asMap(map?['message']);
        if (delta != null) chunks.write(_chatContent(delta['content']));
        if (message != null) snapshot = _chatContent(message['content']);
        if (map?['text'] is String) chunks.write(map!['text']);
      }
    } else if (root['candidates'] is List) {
      for (final candidate in _asList(root['candidates'])) {
        chunks.write(_increment(_asMap(candidate)?['content']));
      }
    } else {
      final complete = extractAiCompletionText(jsonEncode(root), config);
      if (complete.isNotEmpty) chunks.write(complete);
    }
  }
  return (snapshot.isNotEmpty ? snapshot : chunks.toString()).trim();
}

/// 拉取模型列表（`docs/phase6/design/04` §7.6）。
///
/// OpenAI 兼容端点走 `/v1/models`，Gemini 走 `/v1beta/models`。
/// **失败返回空列表**（不是错误）：模型名可以手填，拉列表只是便利。
Future<List<String>> fetchAiModelList(
  AiConfig config, {
  AiCancellationToken? cancellationToken,
  Duration timeout = const Duration(seconds: 30),
  http.Client? client,
}) async {
  final safe = config.sanitized();
  if (!safe.isModelFetchReady) return const [];
  final base = cleanBaseEndpoint(safe.endpoint);
  final url = safe.protocol == AiProtocol.geminiNative
      ? '${_geminiModelsBase(base)}/models'
      : '${_openAiModelsBase(base)}/models';

  if (cancellationToken?.isCancelled == true) return const [];
  final ownedClient = client ?? http.Client();
  final abort = Completer<void>();
  void cancel() {
    if (!abort.isCompleted) abort.complete();
  }

  final timer = Timer(timeout, cancel);
  try {
    final request = http.AbortableRequest(
      'GET',
      Uri.parse(url),
      abortTrigger: abort.future,
    )..headers.addAll(_modelFetchHeaders(safe));
    final work = () async {
      final response = await http.Response.fromStream(
        await ownedClient.send(request),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return <String>[];
      }
      return _parseModelList(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    }();
    return await Future.any([
      work,
      abort.future.then((_) => <String>[]),
      if (cancellationToken != null)
        cancellationToken.whenCancelled.then((_) {
          cancel();
          return <String>[];
        }),
    ]);
  } catch (_) {
    return const [];
  } finally {
    timer.cancel();
    if (client == null) ownedClient.close();
  }
}

Map<String, String> _modelFetchHeaders(AiConfig config) {
  if (config.protocol == AiProtocol.geminiNative) {
    return {'x-goog-api-key': config.apiKey};
  }
  final headers = {'Authorization': 'Bearer ${config.apiKey}'};
  if (config.protocol == AiProtocol.anthropicMessages) {
    headers['x-api-key'] = config.apiKey;
    headers['anthropic-version'] = aiAnthropicVersion;
  }
  final userAgent = _sanitizeUserAgent(config.customUserAgent);
  if (userAgent.isNotEmpty) headers['User-Agent'] = userAgent;
  return headers;
}

/// 模型列表基址：把完整补全端点退回其 `/v1` 父级。
String _openAiModelsBase(String base) {
  if (base.endsWith('/v1')) return base;
  for (final suffix in const ['/responses', '/chat/completions', '/messages']) {
    if (base.endsWith(suffix)) {
      return base.substring(0, base.length - suffix.length);
    }
  }
  return '$base/v1';
}

String _geminiModelsBase(String base) {
  if (base.endsWith('/models')) {
    return base.substring(0, base.length - '/models'.length);
  }
  final marker = base.indexOf('/models/');
  if (marker >= 0) return base.substring(0, marker);
  if (endsWithVersionSegment(base)) return base;
  return '$base/v1beta';
}

List<String> _parseModelList(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final result = <String>[];
    for (final key in const ['data', 'models']) {
      final list = decoded[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id'] ?? item['name'] ?? item['baseModelId'];
        if (id is String && id.trim().isNotEmpty) {
          result.add(
            id.startsWith('models/')
                ? id.substring('models/'.length)
                : id.trim(),
          );
        }
      }
    }
    result.sort();
    return result;
  } catch (_) {
    return const [];
  }
}
