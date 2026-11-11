import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';

/// `probeWritable` 是「目录存在但写不进去」的唯一探针（2026-10-20 现场故障：
/// exe 因所在目录带 Low 完整性标签而以 Low IL 启动，AppData 全部只读，
/// 而 DACL 看起来完全正常）。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-writeprobe');
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('可写目录返回 null，且不留下探针文件', () async {
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );
    expect(await paths.ensureDirectories(), isEmpty);

    expect(await paths.probeWritable(paths.dataDir), isNull);
    expect(await paths.probeWritable(paths.configDir), isNull);
    expect(
      Directory(paths.dataDir).listSync().where(
            (entity) => entity.path.endsWith('.write-probe.tmp'),
          ),
      isEmpty,
    );
  });

  test('目标被同名文件占住时返回错误而不是抛出', () async {
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );
    // 让 `probeWritable` 的目标「目录」其实是一个文件：创建必然失败。
    File(paths.dataDir).writeAsStringSync('not a directory');

    final error = await paths.probeWritable(paths.dataDir);
    expect(error, isNotNull);
    expect(error, isNotEmpty);
  });
}
