/// 测试用 WebSocket 直播弹幕端点（§13.1「直播弹幕」）。
///
/// 为什么放在 Dart 侧而不是 Python fixture 服务：WebSocket 握手与帧编解码
/// 需要完整的 WS 实现，Python 标准库没有；dart:io 原生提供
/// `WebSocketTransformer.upgrade`（服务端）与 `WebSocket.connect`（客户端），
/// 与真实客户端 `web_socket_channel` 走的是同一套 WS 协议。
///
/// 用途：集成测试在进程内起一个 `HttpServer`，`/live-danmaku` 路由做 WS 升级，
/// 连接后按脚本推送固定帧（chat/superchat/online + 非法帧 + 关闭），
/// 用于验证客户端的解析、去代次与生命周期处理。
library;

import 'dart:async';
import 'dart:io';

/// 一次连接要推送的帧脚本。
const List<String> liveDanmakuFixtures = [
  '{"type":"online","data":2026}',
  '{"type":"chat","message":"第一条直播弹幕","color":"#FFFFFF"}',
  '{"type":"chat","message":"第二条直播弹幕，颜色自定义","color":"#FFAA00"}',
  '{"type":"superchat","message":"醒目弹幕","color":"#00FF00"}',
  '{"type":"online","data":2027}',
  // 非法帧：应被客户端丢弃（不影响后续）。
  'not-json',
  '{"type":"unknown","message":"x"}',
  '{"type":"chat","message":""}',
  '{"type":"chat","message":"第三条直播弹幕","color":"#123456"}',
];

/// 启动一个带 `/live-danmaku` WS 端点的本地服务。
///
/// 连接建立后推送 [liveDanmakuFixtures]，随后关闭。返回 base URL。
Future<HttpServer> startLiveDanmakuWSServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final request in server) {
      final path = request.uri.path;
      if (path == '/health') {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('ok');
        await request.response.close();
        continue;
      }
      if (path != '/live-danmaku' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('not a ws route');
        await request.response.close();
        continue;
      }
      // WS 升级。
      final socket = await WebSocketTransformer.upgrade(request);
      // 推送测试帧再关闭。
      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        for (final frame in liveDanmakuFixtures) {
          socket.add(frame);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await socket.close();
      }());
      // 消费客户端消息直到关闭（保证服务端 socket 生命周期正确）。
      // dart:io 的 WebSocket 本身是 Stream<dynamic>，可直接 await for。
      await for (final _ in socket) {
        // 忽略客户端消息；连接由客户端主动关闭。
      }
    }
  }());
  return server;
}