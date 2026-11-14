/// webHome 页面桥（PC 侧 v1 最小契约）。
///
/// 安卓的 `HomeWebController` 会向页面注入 `fm` / `fongmiNative` 对象，
/// 由 `HomeWebBridge` 分派 `net.request`、`vod.home`、`vod.category`、
/// `player.playUrl` 等方法（`app/src/main/java/com/fongmi/android/tv/web/HomeWebController.java`、
/// `HomeWebBridge.java`）。PC 侧先只实现**不依赖站源绑定**的那一部分：
///
/// - `app.info`：宿主标识，供页面判断能力；
/// - `net.request` / `request`：宿主代理 HTTP 请求（绕开浏览器 CORS，页面自己解析
///   数据 —— 这是 HTML 源最常见的用法）；
/// - `player.playUrl`：把可播地址交给 PC 播放器。
///
/// `vod.home` / `vod.category` / `vod.detail` 需要「HTML 源 ↔ 站点」绑定，
/// 尚未实现，一律返回明确的 `unsupported` 错误，不假装成功。
///
/// 纪律：本类只做参数校验与转发，不解析业务；页面是不受信代码，所以
/// - 只允许 http(s) 请求；
/// - 响应体与超时都有上限；
/// - 未知方法返回 `unsupported: <method>`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'log_service.dart';

/// 页面发起播放时的回调（由 UI 层接到 PC 播放器）。
typedef WebHomePlayHandler =
    Future<void> Function(String url, Map<String, String> headers, String title);

/// 桥接器：一条消息进，一条消息出。
class WebHomeBridge {
  WebHomeBridge({
    required this.sourceKey,
    this.log,
    this.playHandler,
    http.Client? client,
    this.maxResponseBytes = 2 * 1024 * 1024,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  /// 当前页面对应的源 key（日志与错误信息用）。
  final String sourceKey;
  final LogService? log;
  final WebHomePlayHandler? playHandler;
  final int maxResponseBytes;
  final Duration timeout;

  final http.Client _client;

  /// 处理一条来自页面的消息，返回要回投给页面的 JSON 字符串。
  ///
  /// 消息格式：`{"id":"r1","method":"net.request","params":{...}}`。
  /// 无法解析的消息返回 null（不回投，避免噪声）。
  Future<String?> handleMessage(String raw) async {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      log?.warning('webHome 消息不是合法 JSON（source=$sourceKey）', scope: 'webhome');
      return null;
    }
    if (decoded is! Map) return null;
    final id = decoded['id'];
    if (id == null) return null;
    final method = '${decoded['method'] ?? ''}';
    final params = decoded['params'] is Map
        ? (decoded['params'] as Map).cast<Object?, Object?>()
        : const <Object?, Object?>{};

    try {
      final result = await _dispatch(method, params);
      return jsonEncode({'id': id, 'result': result});
    } catch (error) {
      log?.warning(
        'webHome 调用失败 method=$method source=$sourceKey $error',
        scope: 'webhome',
      );
      return jsonEncode({'id': id, 'error': '$error'});
    }
  }

  Future<Object?> _dispatch(String method, Map<Object?, Object?> params) async {
    switch (method) {
      case 'app.info':
        return {
          'name': 'WebHTV PC',
          'runtime': 'webhtv-webhome-v1',
          'version': 1,
          'source': sourceKey,
        };
      case 'net.request':
      case 'request':
        return _request(params);
      case 'player.playUrl':
        return _play(params);
      default:
        throw UnsupportedError('unsupported: $method');
    }
  }

  Future<Map<String, Object?>> _request(Map<Object?, Object?> params) async {
    final rawUrl = '${params['url'] ?? ''}'.trim();
    if (rawUrl.isEmpty) throw ArgumentError('缺少 url');
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError('只允许 http(s) 请求');
    }
    final method = '${params['method'] ?? 'GET'}'.toUpperCase();
    final headers = <String, String>{};
    final rawHeaders = params['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (key != null && value != null) headers['$key'] = '$value';
      });
    }
    final body = params['body'];

    final http.Response response;
    switch (method) {
      case 'POST':
        response = await _client
            .post(
              uri,
              headers: headers,
              body: body is String ? body : (body == null ? null : jsonEncode(body)),
            )
            .timeout(timeout);
      case 'GET':
        response = await _client.get(uri, headers: headers).timeout(timeout);
      default:
        throw ArgumentError('不支持的 method=$method');
    }

    if (response.bodyBytes.length > maxResponseBytes) {
      throw StateError(
        '响应超过上限 ${response.bodyBytes.length}>$maxResponseBytes 字节',
      );
    }
    return {
      'code': response.statusCode,
      'headers': response.headers,
      'body': response.body,
    };
  }

  Future<Map<String, Object?>> _play(Map<Object?, Object?> params) async {
    final url = '${params['url'] ?? ''}'.trim();
    if (url.isEmpty) throw ArgumentError('缺少 url');
    final handler = playHandler;
    if (handler == null) throw UnsupportedError('当前界面未接入播放器');
    final headers = <String, String>{};
    final rawHeaders = params['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (key != null && value != null) headers['$key'] = '$value';
      });
    }
    final title = '${params['title'] ?? params['name'] ?? sourceKey}';
    await handler(url, headers, title);
    return {'ok': true};
  }

  void dispose() => _client.close();
}

/// 注入到页面里的 JS 前置脚本：把 `chrome.webview` 适配成安卓同形的
/// `fongmiNative` / `fm` 对象（Promise 化 + id 关联回调）。
///
/// 页面作者按安卓 webHome 的写法调用 `fm.request(...)` 即可；PC 侧缺哪一类方法
/// 会收到明确的 `unsupported` 拒绝，而不是静默挂起。
const String webHomeBridgeScript = r'''
(function(){
  if (window.fongmiNative && window.fongmiNative.__webhtvPc) return;
  var seq = 0;
  var pending = {};
  function resolveOne(msg){
    var data = msg;
    if (typeof data === 'string'){
      try { data = JSON.parse(data); } catch(e){ return; }
    }
    if (!data || !data.id) return;
    var item = pending[data.id];
    if (!item) return;
    delete pending[data.id];
    if (data.error) item.reject(new Error(data.error));
    else item.resolve(data.result);
  }
  try {
    window.chrome.webview.addEventListener('message', function(e){ resolveOne(e.data); });
  } catch (e) {}
  function call(method, params){
    return new Promise(function(resolve, reject){
      var id = 'r' + (++seq);
      pending[id] = { resolve: resolve, reject: reject };
      try {
        window.chrome.webview.postMessage(JSON.stringify({
          id: id, method: method, params: params || {}
        }));
      } catch (err) {
        delete pending[id];
        reject(err);
      }
    });
  }
  window.fongmiNative = {
    __webhtvPc: true,
    version: 1,
    request: call,
    info: function(){ return call('app.info', {}); },
    playUrl: function(url, title){ return call('player.playUrl', { url: url, title: title }); },
    resolve: function(){},
    reject: function(){}
  };
  window.fm = window.fongmiNative;
})();
''';
