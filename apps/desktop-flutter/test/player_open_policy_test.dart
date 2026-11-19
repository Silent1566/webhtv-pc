// 迭代 2 Wave 1：打开策略（预取 / 失败回退）的消费者与失败分类。
//
// 三组断言，对应三件必须成立的事：
// 1. 不传策略时行为与历史一致（超时失败只原地重试一次、诊断照样累积）；
// 2. 传策略后预取**先于** open 发生，探测失败/非 http 地址不阻断开播；
// 3. 失败分类把「换地址能解决的」与「换地址也白搭的」分开。

// ignore_for_file: invalid_use_of_protected_member

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/playback_diagnostics.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

import 'support/player_navigation_fixture.dart';

/// 正常起播的假引擎：每次 open 都上报时长与播放状态，并按顺序记录事件。
class _RecordingIO extends NavigationMediaIO {
  _RecordingIO(this.events);

  final List<String> events;
  int opens = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    events.add('open');
    await super.open(playable, play: play);
  }
}

/// 永不报告进度的假引擎：让 `open()` 走超时失败（§10.4 的重试分支）。
class _SilentIO extends NavigationMediaIO {
  _SilentIO(this.events);

  final List<String> events;
  int opens = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    events.add('open');
  }
}

PlayerController _controller(PlatformPlayer io) {
  final controller = PlayerController(player: Player(platformPlayer: io));
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('不传策略：超时失败只原地重试一次，重试阶段记进同一份诊断', () async {
    final events = <String>[];
    final io = _SilentIO(events);
    final controller = _controller(io);

    final outcome = await controller.openWithRetry(
      'https://fixture.test/hanging',
      timeout: const Duration(milliseconds: 40),
    );

    expect(outcome.succeeded, false);
    expect(outcome.failureKind, PlayerFailureKind.timeout);
    // 首次 + 一次重试，一个不多。
    expect(io.opens, 2);
    expect(events, ['open', 'open']);
    expect(
      controller.diagnostics?.timings.map((timing) => timing.stage),
      contains(PlaybackStage.retry),
    );
  });

  test('回退关闭时一次都不重试，但仍如实给出失败分类', () async {
    final io = _SilentIO(<String>[]);
    final controller = _controller(io);

    final outcome = await controller.openWithRetry(
      'https://fixture.test/hanging',
      timeout: const Duration(milliseconds: 40),
      policy: const PlaybackOpenPolicy(fallbackOnFailure: false),
    );

    expect(outcome.failureKind, PlayerFailureKind.timeout);
    expect(io.opens, 1);
    // 分类是只读事实：超时可回退，只是这次不允许回退。
    expect(controller.lastFailureClass, PlaybackFailureClass.recoverable);
  });

  test('策略给的重试上限被真正执行', () async {
    final io = _SilentIO(<String>[]);
    final controller = _controller(io);

    await controller.openWithRetry(
      'https://fixture.test/hanging',
      timeout: const Duration(milliseconds: 40),
      policy: const PlaybackOpenPolicy(retryLimit: 2),
    );

    expect(io.opens, 3);
  });

  test('开启预取：探测请求先于 open，且带同一份 Header', () async {
    final events = <String>[];
    final io = _RecordingIO(events);
    final controller = _controller(io);
    String? probedUrl;
    Map<String, String>? probedHeaders;
    final headers = <String, String>{'Referer': 'https://site.test/'};

    final outcome = await controller.openWithRetry(
      'https://fixture.test/video.m3u8',
      headers: headers,
      policy: PlaybackOpenPolicy(
        preload: true,
        prefetch: (url, sent) async {
          events.add('prefetch');
          probedUrl = url;
          probedHeaders = sent;
        },
      ),
    );

    expect(outcome.succeeded, true);
    // 顺序是契约：预取先发，再开播。
    expect(events, ['prefetch', 'open']);
    expect(probedUrl, 'https://fixture.test/video.m3u8');
    expect(probedHeaders, headers);
    expect(controller.lastPrefetchError, isNull);
    expect(controller.lastFailureClass, isNull);
  });

  test('关闭预取时不发探测请求', () async {
    final events = <String>[];
    final io = _RecordingIO(events);
    final controller = _controller(io);

    final outcome = await controller.openWithRetry(
      'https://fixture.test/video.m3u8',
      policy: PlaybackOpenPolicy(
        prefetch: (url, sent) async => events.add('prefetch'),
      ),
    );

    expect(outcome.succeeded, true);
    expect(events, ['open']);
  });

  test('探测失败只记一笔，不阻断开播', () async {
    final events = <String>[];
    final io = _RecordingIO(events);
    final controller = _controller(io);

    final outcome = await controller.openWithRetry(
      'https://fixture.test/video.m3u8',
      policy: PlaybackOpenPolicy(
        preload: true,
        prefetch: (url, sent) async {
          events.add('prefetch');
          throw const PlaybackPrefetchException('探测返回 HTTP 404', statusCode: 404);
        },
      ),
    );

    expect(events, ['prefetch', 'open']);
    expect(outcome.succeeded, true);
    expect(controller.lastPrefetchError, contains('404'));
  });

  test('非 http(s) 地址不做预取探测', () async {
    final events = <String>[];
    final io = _RecordingIO(events);
    final controller = _controller(io);

    await controller.openWithRetry(
      'file:///tmp/fixture.mkv',
      policy: PlaybackOpenPolicy(
        preload: true,
        prefetch: (url, sent) async => events.add('prefetch'),
      ),
    );

    expect(events, ['open']);
  });

  test('失败分类：解析/线路/网络可回退，解码器与格式不可回退', () {
    expect(
      classifyPlaybackFailureClass(PlayerFailureKind.notFound),
      PlaybackFailureClass.recoverable,
    );
    expect(
      classifyPlaybackFailureClass(PlayerFailureKind.unauthorized),
      PlaybackFailureClass.recoverable,
    );
    expect(
      classifyPlaybackFailureClass(PlayerFailureKind.network),
      PlaybackFailureClass.recoverable,
    );
    expect(
      classifyPlaybackFailureClass(PlayerFailureKind.timeout),
      PlaybackFailureClass.recoverable,
    );
    expect(
      classifyPlaybackFailureClass(PlayerFailureKind.unsupportedFormat),
      PlaybackFailureClass.nonRecoverable,
    );
    expect(
      classifyPlaybackFailureClass(PlayerFailureKind.loadFailed),
      PlaybackFailureClass.nonRecoverable,
    );

    // 引擎原文 → 分类 → 回退结论，这条链路是调用方真正用到的。
    final codec = classifyPlayerError('Could not open codec: codec not found');
    expect(codec, PlayerFailureKind.unsupportedFormat);
    expect(
      classifyPlaybackFailureClass(codec),
      PlaybackFailureClass.nonRecoverable,
    );
    expect(
      classifyPlaybackFailureClass(classifyPlayerError('HTTP 403 Forbidden')),
      PlaybackFailureClass.recoverable,
    );
    expect(
      classifyPlaybackFailureClass(classifyPlayerError('Connection refused')),
      PlaybackFailureClass.recoverable,
    );
    // 不可回退的失败，硬回退也没用：策略直接说不该走阶梯。
    expect(
      const PlaybackOpenPolicy.defaults().allowsFallback(codec),
      false,
    );
  });

  test('设置页两个开关翻成策略；默认值与历史行为逐项一致', () {
    final defaults = const PlayerOptions.defaults().openPolicy;
    expect(defaults.preload, false);
    expect(defaults.fallbackOnFailure, true);
    expect(defaults.retryLimit, 1);
    // 历史重试判据：只有超时与网络，403/404 不在其中。
    expect(defaults.shouldRetryInPlace(PlayerFailureKind.timeout), true);
    expect(defaults.shouldRetryInPlace(PlayerFailureKind.network), true);
    expect(defaults.shouldRetryInPlace(PlayerFailureKind.notFound), false);
    expect(defaults.shouldRetryInPlace(null), false);
    // 回退阶梯：403/404 恰恰是最该换线路的一类。
    expect(defaults.allowsFallback(PlayerFailureKind.notFound), true);

    expect(const PlayerOptions(preloadNext: true).openPolicy.preload, true);

    final off = const PlayerOptions(
      failureFallback: PlayerFailureFallback.off,
    ).openPolicy;
    expect(off.fallbackOnFailure, false);
    expect(off.shouldRetryInPlace(PlayerFailureKind.timeout), false);
    expect(off.allowsFallback(PlayerFailureKind.network), false);
  });

  test('内置探测只发 HEAD，4xx 判失败、405 视为地址可用', () async {
    // flutter_test 默认用 HttpOverrides.global 把所有出网请求挡成 400
    // （防止单测误连外网）。这条用例要打本机 loopback，所以临时摘掉，用完还原。
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    final paths = <String>[];
    final referers = <String?>[];
    server.listen((request) async {
      methods.add(request.method);
      referers.add(request.headers.value('referer'));
      final path = request.uri.path;
      paths.add(path);
      request.response.statusCode = path == '/missing'
          ? HttpStatus.notFound
          : path == '/nohead'
          ? HttpStatus.methodNotAllowed
          : HttpStatus.ok;
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';

    final results = <String>[];
    Future<void> probe(String path, [Map<String, String> headers = const {}]) async {
      try {
        await httpPlaybackPrefetchProbe('$base$path', headers);
        results.add('$path -> ok');
      } catch (error) {
        results.add('$path -> $error');
      }
    }

    await probe('/ok', {'Referer': 'https://site.test/'});
    await probe('/nohead');
    await probe('/missing');
    expect(
      results,
      [
        '/ok -> ok',
        '/nohead -> ok',
        startsWith('/missing -> PlaybackPrefetchException'),
      ],
      reason: 'paths=$paths methods=$methods',
    );

    expect(methods, ['HEAD', 'HEAD', 'HEAD']);
    expect(referers.first, 'https://site.test/');
    // 非 http(s) 地址不该被当成「探测失败」之外的任何东西。
    await expectLater(
      httpPlaybackPrefetchProbe('file:///tmp/fixture.mkv', const {}),
      throwsA(isA<PlaybackPrefetchException>()),
    );
  });
}
