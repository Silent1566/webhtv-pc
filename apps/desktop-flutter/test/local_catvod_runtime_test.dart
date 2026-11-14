import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'local_source_sites_test.dart' show tempPaths;

String? availablePython() {
  if (!Platform.isWindows) return null;
  final path = p.join(
    Platform.environment['LOCALAPPDATA']!,
    'Programs',
    'Python',
    'Python313',
    'python.exe',
  );
  if (!File(path).existsSync()) return null;
  return SidecarRuntimeResolver.pythonWorksForCatVod(
        SidecarCommand(executable: path, arguments: const []),
      )
      ? path
      : null;
}

void main() {
  test('launcher列表解析兼容新旧版本、默认标记与带空格路径，拒绝非解释器', () {
    expect(
      SidecarRuntimeResolver.pythonExecutablesFromLauncherOutput(
        ' -V:3.13 * C:\\Python With Spaces\\python.exe\n'
        ' -3.10-64 G:\\Python310\\python.exe\n'
        ' -V:3.13 C:\\Python With Spaces\\python.exe\n'
        ' -V:3.9 relative\\python.exe\n'
        ' -V:3.8 C:\\fake\\not-python.exe\n',
      ),
      [r'C:\Python With Spaces\python.exe', r'G:\Python310\python.exe'],
    );
  });

  test('工作目录不在仓库时仍从程序目录向上定位Python宿主', () {
    final temp = Directory.systemTemp.createTempSync('webhtv_host_location_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final host = File(
      p.join(temp.path, 'repo', 'sidecars', 'spider-host-python', 'host.py'),
    );
    host.parent.createSync(recursive: true);
    host.writeAsStringSync('# host fixture');
    expect(
      defaultSidecarHostPath(
        executableDirectory: p.join(
          temp.path,
          'repo',
          'apps',
          'desktop-flutter',
          'build',
          'windows',
          'x64',
          'runner',
          'Debug',
        ),
        workingDirectory: p.join(temp.path, 'outside'),
      ),
      host.path,
    );
  });

  tearDown(() => LocalSpiderCommand.preferPythonExecutable(null));

  test('本机launcher列出的可用CatVod解释器不能因未在PATH而遗漏', () {
    final python = availablePython();
    if (python == null) {
      markTestSkipped('本机无用于真实CatVod依赖探测的Python313');
      return;
    }
    expect(
      SidecarRuntimeResolver.pythonCandidates().map(
        (item) => p.normalize(item.executable),
      ),
      contains(p.normalize(python)),
    );
    expect(
      SidecarRuntimeResolver.firstUsablePython(
        SidecarRuntimeResolver.pythonCandidates(),
        probe: SidecarRuntimeResolver.pythonWorksForCatVod,
      ),
      isNotNull,
    );
  });

  test('先加载普通配置再导入本地CatVod也准备运行时，不下载依赖', () async {
    final python = availablePython();
    if (python == null) {
      markTestSkipped('本机无带齐依赖的Python，不运行可能联网的准备路径');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv_local_catvod_');
    LogService.logDirectoryOverride = p.join(temp.path, 'logs');
    LocalSpiderCommand.preferPythonExecutable(python);
    final state = AppState(paths: tempPaths(temp), log: LogService());
    addTearDown(() async {
      // 专用环境准备在后台 isolate 里跑：先等它落定再释放并删临时目录，
      // 否则删除会撞上仍在写入的运行时文件（errno 32）。
      await state.pythonEnvironmentIdle;
      state.dispose();
      temp.deleteSync(recursive: true);
    });
    await state.bootstrap();
    await state.importConfig('{"sites":[]}');
    final root = Directory(p.join(temp.path, 'sources'))..createSync();
    File(p.join(root.path, 'local.py')).writeAsStringSync(
      'class Spider:\n    def homeContent(self, filter):\n'
      '        return {"list":[{"vod_id":"local-vod","vod_name":"本地CatVod测试"}]}\n',
    );
    final ready = Completer<void>();
    void checkReady() {
      if (!ready.isCompleted &&
          state.log.entries.any(
            (entry) => entry.message.startsWith('Python 运行时就绪：'),
          )) {
        ready.complete();
      }
    }

    state.addListener(checkReady);
    addTearDown(() => state.removeListener(checkReady));
    final report = await state.scanLocalSources(root.path);
    expect(report.candidates.single.looksCatVod, isTrue);
    expect(
      (await state.importLocalSources(report.candidates)).importedCount,
      1,
    );
    // 导入本地 CatVod 源会触发专用环境准备（后台 isolate）：显式等它落定，
    // 才能断言「已就绪」并避免后面的临时目录清理撞上未完成的写入。
    await state.pythonEnvironmentIdle;
    checkReady();
    await ready.future.timeout(const Duration(seconds: 5));
    expect(state.siteItems.single.availability.available, isTrue);
    try {
      await state.selectSite(state.siteItems.single.site);
      expect(state.lastError, isNull);
      expect(state.homeResult!.list.single.vodName, '本地CatVod测试');
    } finally {
      await state.stopSpider('local');
    }
    expect(
      Directory(p.join(state.paths.cacheDir, 'python-runtime', 'venv'))
          .existsSync(),
      isFalse,
    );
    // 冷启动要把内置压缩包解压并真实探测解释器（实测约 40s），超过默认
    // 30s 的用例预算；这里只放大预算，断言与等待逻辑一概不动。
  }, timeout: const Timeout(Duration(minutes: 3)));
}
