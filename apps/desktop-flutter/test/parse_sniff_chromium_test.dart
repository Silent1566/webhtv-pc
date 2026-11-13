/// §12.1 `type=0`/`type=4` 的真实浏览器端到端测试。
///
/// 与 `test/chromium_sniffer_test.dart` 的分工：那边用假传输穷举编排分支，
/// 这里用**真 Chromium 内核 + 真 HTTP 夹具站**证明整条链路——定位 → 启动 →
/// DevToolsActivePort → CDP flatten session → 页面脚本 → 网络事件 → 解析层。
/// 这一层无法用假实现替代：任何一环断了都只在真实进程里表现出来。
///
/// 本机没有可用浏览器时 `markTestSkipped`：这是能力探测，不是失败。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/parse_runtime.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/sniff/chromium_sniffer.dart';
import 'package:webhtv_pc/core/sniff/default_sniff_transport.dart';
import 'package:webhtv_pc/core/sniff/sniff_transport.dart';
import 'package:webhtv_pc/core/sniff/sniff_types.dart';
import 'package:webhtv_pc/services/parse_service.dart';

import 'support/sniff_fixture_server.dart';

void main() {
  BrowserCommand? browser;
  late SniffFixtureServer fixture;

  setUpAll(() async {
    // 「存在且可执行」不等于可用：本机可能只有跑不起来的 snap 包装脚本
    // （snap-confine 权限不足）。按真实可用性挑第一个，才能如实 skip 而不是假失败。
    const transport = DefaultSniffTransport();
    for (final candidate in await transport.locateAll()) {
      if (await transport.probe(candidate) == null) {
        browser = candidate;
        break;
      }
    }
  });

  setUp(() async {
    if (browser == null) return;
    fixture = await SniffFixtureServer.start();
  });

  tearDown(() async {
    if (browser == null) return;
    await fixture.close();
  });

  /// 没有浏览器内核时跳过本用例（能力缺失，不报失败）。
  bool skipWithoutBrowser() {
    if (browser != null) return false;
    markTestSkipped(
      '本机没有可用的 Chromium 内核浏览器'
      '（可用 WEBHTV_SNIFF_BROWSER 指定可执行文件）',
    );
    return true;
  }

  /// 显式离屏：测试不依赖图形会话，也不弹窗。
  ChromiumSniffEngine newEngine() => ChromiumSniffEngine(
    transport: const DefaultSniffTransport(),
    command: browser,
    headed: false,
  );

  test('引擎：/parse/xhr 的页面脚本请求被识别为 network 候选', () async {
    if (skipWithoutBrowser()) return;
    final engine = newEngine();
    SniffSession? session;
    try {
      session = await engine.start(
        SniffRequest(
          pageUrl: fixture.url('/parse/xhr'),
          timeout: const Duration(seconds: 8),
        ),
      );
      final candidate = _requireCandidate(await _traceUntilTerminal(session));
      expect(candidate.url, contains('/vod/master.m3u8'));
      expect(candidate.via, 'network');
    } finally {
      await session?.stop();
      await engine.dispose();
    }
  });

  test('click 注入：只有点击 #play 才产出 /vod/click.m3u8', () async {
    if (skipWithoutBrowser()) return;
    final engine = newEngine();
    SniffSession? session;
    try {
      session = await engine.start(
        SniffRequest(
          pageUrl: fixture.url('/parse/click'),
          timeout: const Duration(seconds: 8),
          clickScript: 'document.querySelector("#play").click()',
        ),
      );
      final candidate = _requireCandidate(await _traceUntilTerminal(session));
      expect(candidate.url, contains('/vod/click.m3u8'));
    } finally {
      await session?.stop();
      await engine.dispose();
    }
  });

  test('人机校验：先收到 SniffChallenge，随后仍拿到校验后的媒体地址', () async {
    if (skipWithoutBrowser()) return;
    final engine = newEngine();
    SniffSession? session;
    try {
      session = await engine.start(
        SniffRequest(
          pageUrl: fixture.url('/parse/challenge'),
          timeout: const Duration(seconds: 10),
          revealWindow: true,
        ),
      );
      final trace = await _traceUntilTerminal(session);
      expect(
        trace.challenges,
        isNotEmpty,
        reason: '标题/正文含校验标记时必须发出 SniffChallenge；事件轨迹：${trace.events}',
      );
      final candidate = _requireCandidate(trace);
      expect(candidate.url, contains('/vod/after-challenge.m3u8'));
    } finally {
      await session?.stop();
      await engine.dispose();
    }
  });

  test('规则 regex：无后缀地址 /hs/... 只能靠规则命中；不给规则则拿不到候选', () async {
    if (skipWithoutBrowser()) return;
    final engine = newEngine();
    SniffSession? session;
    try {
      session = await engine.start(
        SniffRequest(
          pageUrl: fixture.url('/parse/rule'),
          timeout: const Duration(seconds: 8),
          rules: const [SniffRule(regexes: ['/hs/'])],
        ),
      );
      final candidate = _requireCandidate(await _traceUntilTerminal(session));
      expect(candidate.url, contains('/hs/abcdef0123456789'));
      await _waitForRequest(fixture, '/hs/abcdef0123456789');
    } finally {
      await session?.stop();
      await engine.dispose();
    }

    // 同一页面、不给规则：短超时内拿不到候选——证明命中是规则起的作用。
    final bareEngine = newEngine();
    SniffSession? bareSession;
    try {
      bareSession = await bareEngine.start(
        SniffRequest(
          pageUrl: fixture.url('/parse/rule'),
          timeout: const Duration(seconds: 1),
        ),
      );
      final trace = await _traceUntilTerminal(bareSession);
      expect(
        trace.candidate,
        isNull,
        reason: '无后缀地址在默认后缀判定下不得成为候选；事件轨迹：${trace.events}',
      );
      expect(trace.failed, isTrue, reason: '引擎兜底超时必须结束本次嗅探');
      // 页面确实请求了该地址：证明「没有候选」是判定结果，不是页面没跑。
      await _waitForRequest(fixture, '/hs/abcdef0123456789');
    } finally {
      await bareSession?.stop();
      await bareEngine.dispose();
    }
  });

  test('请求头注入：跨 scheme 只走导航 referrer，同 scheme 落到媒体请求上', () async {
    if (skipWithoutBrowser()) return;

    // (1) 跨 scheme：配置 Referer=https，夹具页是 http。旧实现把 Referer 塞进
    // setExtraHTTPHeaders，Chromium 直接 net::ERR_BLOCKED_BY_CLIENT 拦掉导航
    // （表现为嗅探超时）；现在只通过 Page.navigate 的 referrer 传递，页面必须照常
    // 加载并产出候选，媒体请求也不得因 Referer 报错。
    final crossEngine = newEngine();
    SniffSession? crossSession;
    try {
      crossSession = await crossEngine.start(
        SniffRequest(
          pageUrl: fixture.url('/parse/xhr'),
          // 5s 的嗅探预算：若 Referer 仍拦掉导航，这里必然以失败结束而不是静默变慢。
          timeout: const Duration(seconds: 5),
          headers: const {
            'User-Agent': 'WH-PC-SNIFF/1.0',
            'Referer': 'https://ref.example/',
          },
        ),
      );
      // 计时从导航开始（start 返回）算起：浏览器冷启动耗时与被测链路无关。
      final stopwatch = Stopwatch()..start();
      final trace = await _traceUntilTerminal(crossSession);
      stopwatch.stop();
      expect(
        trace.failed,
        isFalse,
        reason: '跨 scheme 不得退化为加载失败/超时；事件轨迹：${trace.events}',
      );
      final candidate = _requireCandidate(trace);
      expect(candidate.url, contains('/vod/master.m3u8'));
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 15)),
        reason: '整条链路必须在 15s 内成功',
      );
      // 媒体请求确实发出去了（不是被 Referer 拦掉的），且 UA 注入生效。
      final crossMedia = await _waitForRequest(fixture, '/vod/master.m3u8');
      expect(crossMedia.userAgent, 'WH-PC-SNIFF/1.0');
      // 跨 scheme 的 Referer 由浏览器 referrer policy 决定是否降级/省略，不做断言。
      expect(crossMedia.url, contains('/vod/master.m3u8'));
    } finally {
      await crossSession?.stop();
      await crossEngine.dispose();
    }

    // (2) 同 scheme：Referer=http 能走 setExtraHTTPHeaders，媒体请求上必须能观测到
    // 这个值——页面默认 Referer 是页面自身地址，记录到 ref.example 就证明是注入值。
    final baseline = fixture.requestsTo('/vod/master.m3u8').length;
    final sameEngine = newEngine();
    SniffSession? sameSession;
    try {
      sameSession = await sameEngine.start(
        SniffRequest(
          pageUrl: fixture.url('/parse/xhr'),
          timeout: const Duration(seconds: 8),
          headers: const {
            'User-Agent': 'WH-PC-SNIFF/1.0',
            'Referer': 'http://ref.example/',
          },
        ),
      );
      _requireCandidate(await _traceUntilTerminal(sameSession));
      final media = await _waitForRequest(
        fixture,
        '/vod/master.m3u8',
        minCount: baseline + 1,
      );
      expect(media.userAgent, 'WH-PC-SNIFF/1.0');
      expect(media.referer, 'http://ref.example/');
    } finally {
      await sameSession?.stop();
      await sameEngine.dispose();
    }
  });

  test('ParseService type=0：解析页产出的 m3u8 成为 ParseRunResult.url', () async {
    if (skipWithoutBrowser()) return;
    final engine = newEngine();
    final service = ParseService(
      sniffEngine: engine,
      webSniffTimeout: const Duration(seconds: 3),
    );
    try {
      final entry = ParseEntry(
        name: 'fixture-xhr',
        type: 0,
        url: fixture.url('/parse/xhr'),
      );
      final result = await service.run(
        selection: ParseRuntime.select([entry]),
        entries: [entry],
        webUrl: '',
      );
      expect(result.url, contains('/vod/master.m3u8'));
      expect(result.parseKind, ParseKind.webSniff);
    } finally {
      service.close();
      await engine.dispose();
    }
  });

  test('ParseService type=0：页面不产出媒体请求时超时抛 parseSniffTimeout', () async {
    if (skipWithoutBrowser()) return;
    final engine = newEngine();
    final service = ParseService(
      sniffEngine: engine,
      webSniffTimeout: const Duration(seconds: 2),
    );
    try {
      final entry = ParseEntry(
        name: 'fixture-slow',
        type: 0,
        url: fixture.url('/parse/slow'),
      );
      await expectLater(
        service.run(
          selection: ParseRuntime.select([entry]),
          entries: [entry],
          webUrl: '',
        ),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.parseSniffTimeout,
          ),
        ),
      );
    } finally {
      service.close();
      await engine.dispose();
    }
  });

  test('ParseService type=4（Super）：坏 JSON 腿失败后 web 腿胜出', () async {
    if (skipWithoutBrowser()) return;
    final engine = newEngine();
    final service = ParseService(
      sniffEngine: engine,
      superParseTimeout: const Duration(seconds: 20),
      superWebAttemptTimeout: const Duration(seconds: 8),
    );
    try {
      final broken = ParseEntry(
        name: 'broken-json',
        type: 1,
        url: fixture.url('/json-broken'),
      );
      final web = ParseEntry(
        name: 'fixture-xhr',
        type: 0,
        url: fixture.url('/parse/xhr'),
      );
      final superEntry = ParseEntry(name: 'super', type: 4);
      final result = await service.run(
        selection: ParseSelection(entry: superEntry, kind: ParseKind.superParse),
        entries: [broken, web],
        webUrl: '',
      );
      expect(result.url, contains('/vod/master.m3u8'));
      expect(result.parseKind, ParseKind.webSniff);
    } finally {
      service.close();
      await engine.dispose();
    }
  });
}

/// 一次嗅探的事件轨迹（直到出现候选或失败）。
class _SniffTrace {
  const _SniffTrace(this.events, this.candidate);

  final List<SniffEvent> events;
  final SniffCandidate? candidate;

  bool get failed => events.any((event) => event is SniffFailed);

  List<SniffChallenge> get challenges =>
      events.whereType<SniffChallenge>().toList(growable: false);
}

/// 收集事件直到候选或失败事件；超时直接抛 [TimeoutException]。
Future<_SniffTrace> _traceUntilTerminal(
  SniffSession session, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final events = <SniffEvent>[];
  final completer = Completer<SniffCandidate?>();
  late final StreamSubscription<SniffEvent> subscription;
  subscription = session.events.listen(
    (event) {
      events.add(event);
      if (completer.isCompleted) return;
      if (event is SniffCandidate) {
        completer.complete(event);
      } else if (event is SniffFailed) {
        completer.complete(null);
      }
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    },
  );
  try {
    final candidate = await completer.future.timeout(timeout);
    return _SniffTrace(List<SniffEvent>.of(events), candidate);
  } finally {
    await subscription.cancel();
  }
}

/// 等夹具站记录到路径含 [needle] 的请求（CDP 事件先于服务端收到请求）。
Future<SniffFixtureRequest> _waitForRequest(
  SniffFixtureServer fixture,
  String needle, {
  int minCount = 1,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final matches = fixture.requestsTo(needle);
    if (matches.length >= minCount) return matches.last;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(
    '夹具站在 ${timeout.inSeconds}s 内没有收到第 $minCount 个 $needle；'
    '已记录：${fixture.requests}',
  );
}

/// 断言轨迹里有候选，否则带上事件轨迹失败（便于诊断真实浏览器行为）。
SniffCandidate _requireCandidate(_SniffTrace trace) {
  final candidate = trace.candidate;
  if (candidate == null) {
    fail('没有收到 SniffCandidate；事件轨迹：${trace.events}');
  }
  return candidate;
}
