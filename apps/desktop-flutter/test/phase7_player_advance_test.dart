/// Phase 7 · 连播防重入与失败回滚（`docs/phase7/design/03` §4.1/§4.3、`design/04` R7–R15）。
///
/// **为什么这些用例必须以源码级断言为主**：连播闸门住在
/// `_PlayerPageState` 里，而它 `late final PlayerController _controller`
/// 在 `initState` 构造；`PlayerController` 的构造会触
/// `MediaKit.ensureInitialized()`，在 `flutter test`（无 libmpv）里必然抛
/// `Exception: MediaKit.ensureInitialized must be called before using any API
/// from package:media_kit.`。
///
/// 因此本文件分两层：
/// 1. **行为断言**（能真跑的）：`PlayerController.clearCompleted()` 的语义、
///    `PlaybackRequest.copyWith` 的回滚形态、`isGenuineEnd` 闸门；
/// 2. **源码级接线锁**：连播必须由 `_onControllerChanged` 事件驱动、
///    必须带 `_advanceInFlight` 守卫、失败路径必须回滚 `_request` 并调
///    `clearCompleted()`、恢复路径不得调 `_playNext()`。
///
/// 源码断言前**剥掉注释行**，避免「把语句注释掉」也能通过。
/// 端到端行为（真实窗口 + 提前 EOF）由 `integration_test/phase7_resume_flow_test.dart`
/// 覆盖（L3，T13）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/ui/player_page.dart';

/// 读取源码并剥掉注释行（`//` 与 `///`）。
///
/// 只剥整行注释，不处理行尾注释——本仓库的注释都是整行风格，
/// 且行尾注释里出现被断言的语句会带来误判。
String _readSourceCode(String relative) {
  final raw = File(relative).readAsLinesSync();
  return raw
      .where((line) {
        final trimmed = line.trimLeft();
        return !trimmed.startsWith('//');
      })
      .join('\n');
}

void main() {
  final pageSource = _readSourceCode('lib/ui/player_page.dart');
  final controllerSource = _readSourceCode('lib/ui/player_controller.dart');

  group('R7/R8 · 连播防重入（design/03 §4.1 D1，反向验证 #2 靶子）', () {
    test('连播由 _onControllerChanged 事件驱动，不再由 build() 直接触发', () {
      // D1 的根因：旧实现在 build() 里排 postFrameCallback，
      // 任何一次 setState 都会重排一次 _onCompleted()。
      expect(
        pageSource.contains('_maybeAdvanceOnGenuineEnd();'),
        isTrue,
        reason: '连播必须由控制器通知驱动',
      );
      // build() 里不得再出现「直接调 _onCompleted」的形态。
      expect(
        pageSource.contains('if (mounted) _onCompleted();'),
        isFalse,
        reason: 'build() 里不得直接触发连播（D1 的根因）',
      );
      // _onCompleted 已被移除（它只是 _playNext 的无守卫包装）。
      expect(
        pageSource.contains('void _onCompleted()'),
        isFalse,
        reason: '无守卫的 _onCompleted 入口必须删除，否则会绕开闸门',
      );
    });

    test('R8 · 闸门第一道就是 _advanceInFlight 守卫', () {
      expect(
        pageSource.contains('if (_advanceInFlight) return;'),
        isTrue,
        reason: '单次守卫必须存在',
      );
      // 守卫必须在 `_advanceInFlight = true` 之前生效（顺序不能反）。
      final guardIndex = pageSource.indexOf('if (_advanceInFlight) return;');
      final setIndex = pageSource.indexOf('_advanceInFlight = true;');
      expect(guardIndex, greaterThan(0));
      expect(setIndex, greaterThan(guardIndex));
    });

    test('R8 · 守卫在连播完成后复位（含失败路径）', () {
      // whenComplete 里必须复位，否则一次失败会永久堵死后续连播。
      expect(pageSource.contains('_advanceInFlight = false;'), isTrue);
      // 复位必须发生在 whenComplete 内（而不是 await 之后），
      // 这样即使 _playNext 抛异常也会复位。
      expect(pageSource.contains('.whenComplete(() {'), isTrue);
    });

    test('闸门第二、三道：isCompleted 与真播完判定', () {
      expect(
        pageSource.contains('if (!_controller.isCompleted) return;'),
        isTrue,
      );
      expect(pageSource.contains('if (!_isGenuineEnd()) return;'), isTrue);
      // 闸门顺序：守卫 → isCompleted → 真播完。
      final guard = pageSource.indexOf('if (_advanceInFlight) return;');
      final completed = pageSource.indexOf(
        'if (!_controller.isCompleted) return;',
      );
      final genuine = pageSource.indexOf('if (!_isGenuineEnd()) return;');
      expect(guard, lessThan(completed));
      expect(completed, lessThan(genuine));
    });

    test('R15 · 连播收尾必须复位 completed（末集 next<0 的残留）', () {
      // 末集时 _playNext() 直接返回，_completed 仍为 true；
      // 不复位会让下一次重建再跑一遍闸门。
      expect(
        pageSource.contains('if (mounted) _controller.clearCompleted();'),
        isTrue,
        reason: '连播收尾必须清 completed（含末集与失败两条路径）',
      );
    });

    test('真播完判定复用 core 的 isGenuineEnd（三处口径同源）', () {
      expect(
        pageSource.contains('isGenuineEndDuration('),
        isTrue,
        reason: '不得在 UI 层重新实现一份阈值',
      );
      // 余量不得在 UI 层就地硬编码：`_isGenuineEnd` 的方法体里不能出现
      // 数字字面量形式的毫秒余量（5000）或 Duration 字面量。
      // 注意必须**限定到方法体**：文件里别处有 `Duration(seconds: 5)`
      // （进度保存定时器），全局搜索会误命中。
      final start = pageSource.indexOf('bool _isGenuineEnd() =>');
      expect(start, greaterThan(0), reason: '闸门必须委托给 core');
      final end = pageSource.indexOf('Future<void> _load() async {');
      expect(end, greaterThan(start));
      final body = pageSource.substring(start, end);
      expect(body.contains('5000'), isFalse, reason: '余量必须来自 core 常量');
      // 不得就地构造 Duration 字面量。
      // 注意：不能用 `body.contains('Duration(')` —— `isGenuineEndDuration(`
      // 本身就包含这个子串，会恒真。必须匹配带参数的构造形态。
      expect(
        body.contains('Duration(seconds:') ||
            body.contains('Duration(milliseconds:'),
        isFalse,
        reason: '余量必须来自 core 常量，不得就地构造 Duration',
      );
    });
  });

  group('R9/R10/R11 · 失败回滚（design/03 §4.3 D3）', () {
    test('R9 · 失败路径把 _request 回滚到本次加载前的意图', () {
      // 必须先在加载前捕获意图。
      expect(
        pageSource.contains('final intent = _request;'),
        isTrue,
        reason: '加载前必须捕获意图，否则无从回滚',
      );
      // 回滚必须发生在**失败分支内**，且早于该分支的 clearCompleted。
      // 注意：`_controller.clearCompleted();` 在文件里出现两次
      // （连播收尾 + 失败分支），因此必须限定到失败分支片段，
      // 否则会与连播收尾的那一处比较，得到无意义的顺序结论。
      final failureStart = pageSource.indexOf('if (!outcome.succeeded) {');
      final failureEnd = pageSource.indexOf('await _configureSubtitles();');
      expect(failureStart, greaterThan(0));
      expect(failureEnd, greaterThan(failureStart));
      final failureBlock = pageSource.substring(failureStart, failureEnd);

      final rollback = failureBlock.indexOf('_request = intent;');
      final clear = failureBlock.indexOf('_controller.clearCompleted();');
      expect(rollback, greaterThan(0), reason: '失败分支必须回滚 _request（D3）');
      expect(clear, greaterThan(rollback), reason: '回滚后再清 completed');
    });

    test('R10 · 失败路径调用 clearCompleted', () {
      expect(
        pageSource.contains('_controller.clearCompleted();'),
        isTrue,
        reason: '失败路径必须清 completed，否则重建会再次连播',
      );
    });

    test('R11 · 失败路径不触发连播', () {
      // 失败分支内不得出现 _playNext / _maybeAdvanceOnGenuineEnd。
      final failureStart = pageSource.indexOf('if (!outcome.succeeded) {');
      expect(failureStart, greaterThan(0));
      // 取失败分支到「字幕装配」之间的片段。
      final afterFailure = pageSource.indexOf('await _configureSubtitles();');
      expect(afterFailure, greaterThan(failureStart));
      final failureBlock = pageSource.substring(failureStart, afterFailure);
      expect(failureBlock.contains('_playNext('), isFalse);
      expect(failureBlock.contains('_maybeAdvanceOnGenuineEnd'), isFalse);
    });

    test('失败路径记录 nearEnd 诊断（design/03 §4.6）', () {
      expect(pageSource.contains('nearEnd='), isTrue, reason: '缓存耗尽在 PC 侧必须可见');
      expect(pageSource.contains('buffered='), isTrue);
    });
  });

  group('R12/R13/R14 · 恢复路径与三出口（design/03 §4.4/§4.5）', () {
    test('R12 · 恢复路径不触发连播', () {
      final start = pageSource.indexOf(
        'Future<void> _resumeFromLatestProgress()',
      );
      expect(start, greaterThan(0), reason: '恢复入口必须存在');
      final end = pageSource.indexOf('Future<void> _playNext()');
      expect(end, greaterThan(start));
      final resumeBlock = pageSource.substring(start, end);
      expect(
        resumeBlock.contains('_playNext('),
        isFalse,
        reason: '恢复路径必须不调 _playNext（P5）',
      );
      expect(resumeBlock.contains('_maybeAdvanceOnGenuineEnd'), isFalse);
    });

    test('R13 · 恢复路径重新查库拿最新进度', () {
      final start = pageSource.indexOf(
        'Future<void> _resumeFromLatestProgress()',
      );
      final end = pageSource.indexOf('Future<void> _playNext()');
      final resumeBlock = pageSource.substring(start, end);
      expect(
        resumeBlock.contains('resumePositionFor('),
        isTrue,
        reason: '必须重新查库（失败期间进度仍在写入）',
      );
      expect(
        resumeBlock.contains('startPosition: latest'),
        isTrue,
        reason: '必须用查到的最新值重建 _request',
      );
    });

    test('R14 · 失败态三个出口都存在且可点', () {
      for (final key in [
        'player-error-retry',
        'player-error-resume',
        'player-error-next',
      ]) {
        expect(
          pageSource.contains("ValueKey('$key')"),
          isTrue,
          reason: '缺少出口 $key',
        );
      }
    });

    test('三出口各自接到正确的回调', () {
      expect(pageSource.contains('onRetry: _load,'), isTrue);
      expect(
        pageSource.contains('onResume: _resumeFromLatestProgress,'),
        isTrue,
      );
      expect(pageSource.contains('onNext: _playNext,'), isTrue);
    });

    test('恢复查不到进度时退化为重试本集（不能静默无动作）', () {
      final start = pageSource.indexOf(
        'Future<void> _resumeFromLatestProgress()',
      );
      final end = pageSource.indexOf('Future<void> _playNext()');
      final resumeBlock = pageSource.substring(start, end);
      expect(resumeBlock.contains('if (latest == null)'), isTrue);
      expect(resumeBlock.contains('await _load();'), isTrue);
    });
  });

  group('行为断言：控制器与请求的可测部分', () {
    test('clearCompleted 的语义由源码契约锁定', () {
      // PlayerController 无法在 flutter test 里构造（MediaKit 未初始化），
      // 因此这里锁「存在性 + 幂等 + 通知」三条契约。
      expect(
        controllerSource.contains('bool clearCompleted()'),
        isTrue,
        reason: '失败/回滚路径需要显式清除入口',
      );
      // 幂等断言不绑死整行字面量：beta 的播放器生命周期改造在同一个
      // 提前返回里补了 `_disposed` 保护（`if (_disposed || !_completed)
      // return false;`），语义仍是「已完成才清、否则不产生通知」。
      // 这里锁的是「以 `_completed` 短路提前返回」这个契约本身。
      expect(
        RegExp(r'if \(\s*(?:_disposed \|\| )?!_completed\s*\)\s*return false;')
            .hasMatch(controllerSource),
        isTrue,
        reason: '必须幂等（重复调用不产生多余通知）',
      );
      expect(controllerSource.contains('_completed = false;'), isTrue);
      expect(controllerSource.contains('notifyListeners();'), isTrue);
      // 只清 completed，不得顺手清 position/duration（那会让 UI 跳回 0）。
      final start = controllerSource.indexOf('bool clearCompleted()');
      final end = controllerSource.indexOf('double get volume');
      final block = controllerSource.substring(start, end);
      expect(block.contains('_position ='), isFalse);
      expect(block.contains('_duration ='), isFalse);
    });

    test('R9 形态 · copyWith 能把 startPosition 换成最新值', () {
      // 恢复路径依赖这个语义：用最新进度重建请求。
      const request = PlaybackRequest(
        url: 'https://cdn.example.com/ep01.m3u8',
        title: '扫毒风暴',
        siteKey: 'CupFox',
        vodId: '/video/104339.html',
        vodName: '扫毒风暴',
        episodeName: '第01集',
        flag: '线路1',
        startPosition: Duration(seconds: 10),
      );
      final updated = request.copyWith(
        startPosition: const Duration(seconds: 300),
      );
      expect(updated.startPosition, const Duration(seconds: 300));
      // 其余身份字段不得被动过（回滚/续播都不能换集）。
      expect(updated.episodeName, request.episodeName);
      expect(updated.episodeIndex, request.episodeIndex);
      expect(updated.episodeTarget, request.episodeTarget);
    });

    test('R9 形态 · copyWith 不带 startPosition 时保留原值（回滚语义）', () {
      const request = PlaybackRequest(
        url: 'u',
        title: 't',
        siteKey: 's',
        vodId: 'v',
        vodName: 'n',
        episodeName: 'e',
        flag: 'f',
        startPosition: Duration(seconds: 42),
      );
      // 失败回滚是「整体赋回 intent」，因此这里锁的是 copyWith 的默认保留语义。
      final same = request.copyWith();
      expect(same.startPosition, const Duration(seconds: 42));
      expect(same.episodeTarget, request.episodeTarget);
    });

    test('R1–R4 复核 · 闸门公式与 UI 判定一致', () {
      // UI 的 _isGenuineEnd 委托给 isGenuineEndDuration；
      // 这里直接验证该函数的边界，确认 UI 拿到的是同一套语义。
      expect(
        isGenuineEndDuration(duration: Duration.zero, position: Duration.zero),
        isFalse,
      );
      const duration = Duration(minutes: 45);
      expect(
        isGenuineEndDuration(
          duration: duration,
          position: duration - const Duration(seconds: 6),
        ),
        isFalse,
      );
      expect(
        isGenuineEndDuration(
          duration: duration,
          position: duration - const Duration(seconds: 5),
        ),
        isTrue,
      );
    });
  });
}
