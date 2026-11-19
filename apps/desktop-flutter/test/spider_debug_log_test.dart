/// 爬虫 IPC 详细调试日志（入参/出参）测试。
///
/// 覆盖三件事：
/// - 默认关闭时**不产生**任何入参/出参日志行（既有日志量不变）；
/// - 打开后入参/出参全量打印（不截断），且落盘前脱敏；
/// - 日志单文件上限档位 2MB ↔ 20MB 随开关切换，并持久化到 `settings.json`
///   的 `ui.spiderDebugLog`。
///
/// 为什么不在这里拉起真实 sidecar：入参/出参日志挂在 [SidecarProcess] 的帧出口
/// 与响应入口，两者的格式化、脱敏与开关语义都在 [SpiderDebugLog] 这一层可测；
/// 真实子进程链路由 `phase2_ipc_test.dart` 覆盖。
@Tags(['external'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  // ---------------------------------------------------------------------------
  // 开关语义
  // ---------------------------------------------------------------------------
  group('详细调试日志开关', () {
    test('默认关闭时不打印任何入参/出参', () {
      final log = LogService();
      final debug = SpiderDebugLog(log: log);
      expect(debug.enabled, isFalse);

      debug.outbound(
        IpcEnvelope.request(id: 'site-1', method: 'search', deadlineMs: 30000),
      );
      debug.inboundOk('search', 'site-1', {'list': []});
      debug.inboundError(
        'search',
        'site-1',
        SpiderError(code: SpiderErrorCode.timeout, message: '超时'),
      );

      expect(log.entries, isEmpty);
    });

    test('打开后入参/出参全量打印，不按长度截断', () {
      final log = LogService();
      final debug = SpiderDebugLog(log: log, enabled: true);
      // 远大于任何常规截断阈值的长字段：截断会在这里暴露。
      final longText = 'x' * 8000;
      final params = <String, Object?>{
        'wd': longText,
        'page': 2,
        'filters': {'year': '2024', 'area': '国产'},
      };
      final result = <String, Object?>{
        'list': [
          {'vod_id': '1', 'vod_name': longText},
        ],
      };

      debug.outbound(
        IpcEnvelope.request(
          id: 'site-1-7',
          method: 'search',
          params: params,
          deadlineMs: 30000,
        ),
      );
      debug.inboundOk('search', 'site-1-7', result);

      expect(log.entries, hasLength(2));
      expect(log.entries.every((entry) => entry.scope == 'spider'), isTrue);
      expect(log.entries.every((entry) => entry.level == LogLevel.debug), isTrue);

      final request = log.entries.first.message;
      expect(request, contains('method=search'));
      expect(request, contains('id=site-1-7'));
      expect(request, contains(longText));
      expect(request, contains(jsonEncode(params)));

      final response = log.entries.last.message;
      expect(response, contains('method=search'));
      expect(response, contains('id=site-1-7'));
      expect(response, contains('result='));
      expect(response, contains(longText));
      expect(response, contains(jsonEncode(result)));
    });

    test('出参失败时带错误码与 message', () {
      final log = LogService();
      final debug = SpiderDebugLog(log: log, enabled: true);

      debug.inboundError(
        'detail',
        'site-2-3',
        SpiderError(
          code: SpiderErrorCode.httpError,
          message: '站点返回 502',
          details: {'status': 502},
        ),
      );

      final line = log.entries.single.message;
      expect(line, contains('method=detail'));
      expect(line, contains('id=site-2-3'));
      expect(line, contains('code=${SpiderErrorCode.httpError}'));
      expect(line, contains('message=站点返回 502'));
      expect(line, contains('502'));
    });

    test('入参与出参落盘前脱敏（Cookie / token / 签名 query）', () {
      final log = LogService();
      final debug = SpiderDebugLog(log: log, enabled: true);

      debug.outbound(
        IpcEnvelope.request(
          id: 'site-3-1',
          method: 'play',
          params: {
            'headers': {
              'Cookie': 'sid=abc123',
              'Authorization': 'Bearer ef4f56',
              'Referer': 'https://example.com/',
            },
            'url': 'https://example.com/p.m3u8?sign=deadbeef&t=1',
          },
          deadlineMs: 30000,
        ),
      );
      debug.inboundOk('play', 'site-3-1', {
        'url': 'https://cdn.example.com/a.m3u8?token=feedface',
        'Cookie': 'sid=abc123',
      });

      final request = log.entries.first.message;
      expect(request, contains('<redacted>'));
      expect(request, isNot(contains('abc123')));
      expect(request, isNot(contains('ef4f56')));
      expect(request, isNot(contains('deadbeef')));
      // 非敏感信息保留，否则日志失去诊断价值。
      expect(request, contains('https://example.com/'));

      final response = log.entries.last.message;
      expect(response, isNot(contains('feedface')));
      expect(response, isNot(contains('abc123')));
    });

    test('没有日志服务时打开也不抛（日志是旁路）', () {
      final debug = SpiderDebugLog(enabled: true);
      debug.outbound(IpcEnvelope.cancel('site-1'));
      debug.inboundOk('search', 'site-1', null);
      debug.inboundError(
        'search',
        'site-1',
        SpiderError(code: SpiderErrorCode.crashed, message: '崩溃'),
      );
    });

    test('取消帧只记目标 id', () {
      final log = LogService();
      final debug = SpiderDebugLog(log: log, enabled: true);

      debug.outbound(IpcEnvelope.cancel('site-4-9'));

      final line = log.entries.single.message;
      expect(line, contains('target='));
      expect(line, contains('site-4-9'));
    });
  });

  // ---------------------------------------------------------------------------
  // 单文件上限档位
  // ---------------------------------------------------------------------------
  group('日志单文件上限档位', () {
    test('默认 2MB，详细调试日志 20MB，可运行时切换', () {
      final log = LogService();
      expect(log.maxFileBytes, LogService.standardMaxFileBytes);
      expect(LogService.standardMaxFileBytes, 2 * 1024 * 1024);

      // 与 `AppState.applySpiderDebugLog` 同一条映射。
      log.maxFileBytes = LogService.maxFileBytesFor(verbose: true);
      expect(log.maxFileBytes, LogService.verboseMaxFileBytes);
      expect(LogService.verboseMaxFileBytes, 20 * 1024 * 1024);

      log.maxFileBytes = LogService.maxFileBytesFor(verbose: false);
      expect(log.maxFileBytes, 2 * 1024 * 1024);
    });

    test('构造参数仍可指定自定义上限（既有调用点不变）', () {
      expect(LogService(maxFileBytes: 1024).maxFileBytes, 1024);
    });
  });

  // ---------------------------------------------------------------------------
  // 运行期轮转：单份上限必须在运行中真实生效
  // ---------------------------------------------------------------------------
  group('运行期轮转', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-log-rotate');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Windows 上偶发目录占用：清理失败不影响用例结论。
      }
    });

    test('写入超过上限时轮转出 .1，主文件被削回阈值内', () async {
      final log = LogService(maxFileBytes: 1024);
      await log.open(tempDir.path);
      final main = File(p.join(tempDir.path, 'webhtv-pc.log'));

      // 每条约 240 字节：逐条 flush 才能让每次落盘都看到当前长度。
      for (var i = 0; i < 12; i++) {
        log.info('line-$i ${'y' * 200}');
        log.flush();
      }

      expect(main.existsSync(), isTrue);
      expect(
        File('${main.path}.1').existsSync(),
        isTrue,
        reason: '超过 maxFileBytes 应轮转为 .1',
      );
      expect(main.lengthSync(), lessThan(1024));
      await log.dispose();
    });

    test('运行中把上限改小，下一条 flush 立即按新阈值轮转', () async {
      // 起始档位取「详细调试日志」的 20MB：此时不可能轮转。
      final log = LogService(maxFileBytes: LogService.verboseMaxFileBytes);
      await log.open(tempDir.path);
      final main = File(p.join(tempDir.path, 'webhtv-pc.log'));
      for (var i = 0; i < 3; i++) {
        log.info('line-$i ${'z' * 200}');
        log.flush();
      }
      expect(File('${main.path}.1').existsSync(), isFalse);
      expect(main.lengthSync(), greaterThan(500));

      // 模拟开关回落：档位在运行中从 20MB 改成 512B。
      log.maxFileBytes = 512;
      log.info('after-tighten ${'z' * 100}');
      log.flush();

      expect(
        File('${main.path}.1').existsSync(),
        isTrue,
        reason: '新档位必须在下一条 flush 立即生效',
      );
      expect(main.lengthSync(), lessThan(512));
      await log.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------
  group('开关持久化（settings.json 的 ui 段）', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-spider-debug');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Windows 上偶发目录占用：清理失败不影响用例结论。
      }
    });

    test('缺省为关闭，切换后写入并通过 load 恢复', () async {
      final path = p.join(tempDir.path, 'settings.json');
      final store = UiPreferencesStore(path: path);
      expect(store.spiderDebugLog, isFalse);
      expect(store.hasExplicitSpiderDebugLog, isFalse);

      expect(await store.rememberSpiderDebugLog(true), isTrue);

      final decoded = jsonDecode(await File(path).readAsString());
      expect(decoded, isA<Map>());
      final ui = (decoded as Map)['ui'];
      expect(ui, isA<Map>());
      expect((ui as Map)['spiderDebugLog'], isTrue);

      final reloaded = UiPreferencesStore(path: path);
      await reloaded.load();
      expect(reloaded.spiderDebugLog, isTrue);

      // 显式关掉也要写盘（true → false 可被下次启动读到）。
      expect(await store.rememberSpiderDebugLog(false), isTrue);
      final reloadedOff = UiPreferencesStore(path: path);
      await reloadedOff.load();
      expect(reloadedOff.spiderDebugLog, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 停止时的现场保留（dispose 默认删工作目录，而 stderr.log 就在目录里）
  // ---------------------------------------------------------------------------
  group('停止时保留 sidecar 现场日志', () {
    late Directory tempDir;
    String? savedOverride;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-sidecar-scene');
      savedOverride = LogService.logDirectoryOverride;
      // 缺省不落盘：是否需要保留由用例显式指定目录，避免读到上一个用例的残留。
      LogService.logDirectoryOverride = null;
    });

    tearDown(() async {
      LogService.logDirectoryOverride = savedOverride;
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Windows 上偶发目录占用：清理失败不影响用例结论。
      }
    });

    test('把 stderr.log 与轮转文件按时间顺序合并成一个文件', () async {
      final workDir = p.join(tempDir.path, 'work', 'site-a');
      await Directory(workDir).create(recursive: true);
      final logFile = p.join(workDir, 'stderr.log');
      await File('$logFile.2').writeAsString('oldest\n');
      await File('$logFile.1').writeAsString('older\n');
      await File(logFile).writeAsString('newest\n');

      final out = await SidecarProcess.preserveStderrLog(
        logFile: logFile,
        siteKey: 'site-a',
        directory: p.join(tempDir.path, 'logs'),
      );

      expect(out, isNotNull);
      expect(
        p.basename(out!.path),
        matches(RegExp(r'^sidecar-site-a-\d{8}-\d{6}-\d{3}\.log$')),
      );
      expect(await out.readAsString(), 'oldest\nolder\nnewest\n');
    });

    test('每个站点只保留最近 10 份，其它站点的现场不受影响', () async {
      final logDir = p.join(tempDir.path, 'logs');
      await Directory(logDir).create(recursive: true);
      for (var i = 0; i < 12; i++) {
        final name = 'sidecar-site-a-20240101-0000'
            '${i.toString().padLeft(2, '0')}-000.log';
        await File(p.join(logDir, name)).writeAsString('old-$i\n');
      }
      await File(
        p.join(logDir, 'sidecar-site-b-20240101-000000-000.log'),
      ).writeAsString('other\n');

      final workDir = p.join(tempDir.path, 'work', 'site-a');
      await Directory(workDir).create(recursive: true);
      final logFile = p.join(workDir, 'stderr.log');
      await File(logFile).writeAsString('fresh\n');

      await SidecarProcess.preserveStderrLog(
        logFile: logFile,
        siteKey: 'site-a',
        directory: logDir,
      );

      final names = Directory(logDir)
          .listSync()
          .whereType<File>()
          .map((file) => p.basename(file.path))
          .where((name) => name.startsWith('sidecar-site-a-'))
          .toList()
        ..sort();
      expect(names, hasLength(SidecarProcess.preservedStderrKeepFiles));
      expect(
        names,
        isNot(contains('sidecar-site-a-20240101-000000-000.log')),
        reason: '最旧的现场必须被清掉',
      );
      expect(names, contains('sidecar-site-a-20240101-000003-000.log'));
      expect(
        File(p.join(logDir, 'sidecar-site-b-20240101-000000-000.log'))
            .existsSync(),
        isTrue,
        reason: '清理只能作用于本站点的文件',
      );
    });

    test('日志目录未就绪时跳过保留，源文件原样留着', () async {
      final logFile = p.join(tempDir.path, 'work', 'site-a', 'stderr.log');
      await Directory(p.dirname(logFile)).create(recursive: true);
      await File(logFile).writeAsString('x\n');

      final out = await SidecarProcess.preserveStderrLog(
        logFile: logFile,
        siteKey: 'site-a',
      );

      expect(out, isNull);
      expect(File(logFile).existsSync(), isTrue);
    });

    test('siteKey 含穿越字符时落点仍在日志目录内', () async {
      final logDir = p.join(tempDir.path, 'logs');
      final logFile = p.join(tempDir.path, 'work', 'site-a', 'stderr.log');
      await Directory(p.dirname(logFile)).create(recursive: true);
      await File(logFile).writeAsString('x\n');

      final out = await SidecarProcess.preserveStderrLog(
        logFile: logFile,
        siteKey: '../../escape',
        directory: logDir,
      );

      expect(out, isNotNull);
      expect(p.dirname(out!.path), logDir);
    });

    test('dispose 先留现场再删工作目录', () async {
      // 用 /bin/sh 造一个真实子进程：dispose 的删除顺序只有端到端才看得见。
      if (Platform.isWindows) return;
      final workDir = p.join(tempDir.path, 'work', 'scene-fixture');
      final logFile = p.join(workDir, 'stderr.log');
      final logDir = p.join(tempDir.path, 'logs');
      LogService.logDirectoryOverride = logDir;

      final process = await SidecarProcess.start(
        SidecarLaunchSpec(
          siteKey: 'scene-fixture',
          executable: '/bin/sh',
          arguments: const ['-c', 'echo scene >&2; exit 0'],
          workingDirectory: workDir,
          logFile: logFile,
        ),
      );
      await process.done.timeout(const Duration(seconds: 10));
      // 退出后补一行确定的标记：stderr 是异步送达的，不能拿它当断言依据。
      await File(logFile).writeAsString('scene-marker\n', mode: FileMode.append);

      await process.dispose();

      expect(Directory(workDir).existsSync(), isFalse, reason: '工作目录照旧删除');
      final kept = Directory(logDir)
          .listSync()
          .whereType<File>()
          .where(
            (file) => p.basename(file.path).startsWith('sidecar-scene-fixture-'),
          )
          .toList();
      expect(kept, hasLength(1));
      expect(await kept.single.readAsString(), contains('scene-marker'));
    });
  });

  // ---------------------------------------------------------------------------
  // 路径段净化（工作目录/缓存目录共用）
  // ---------------------------------------------------------------------------
  group('路径段净化', () {
    test('把分隔符与穿越段压成单个安全段', () {
      expect(sanitizePathSegment('site-a'), 'site-a');
      expect(sanitizePathSegment('a/../../b'), 'a_.._.._b');
      expect(sanitizePathSegment(r'a\b'), 'a_b');
      expect(sanitizePathSegment('..'), '_');
      expect(sanitizePathSegment('.'), '_');
      expect(sanitizePathSegment(''), '_');

      final root = p.join(Directory.systemTemp.path, 'work');
      expect(p.isWithin(root, p.join(root, sanitizePathSegment('../evil'))), isTrue);
    });
  });
}
