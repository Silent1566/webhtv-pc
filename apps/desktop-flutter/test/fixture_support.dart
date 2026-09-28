/// 测试 fixture 读取与断言辅助。
///
/// fixture 位于仓库 `packages/test-fixtures`，与 UI 语言无关，Phase 0 与产品
/// 阶段共用同一份数据（设计文档 §19 要求 fixture 与预期结果不能分叉）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 仓库根目录：从测试进程工作目录向上查找 `packages/test-fixtures`。
Directory get repositoryRoot {
  var current = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    final candidate = Directory(p.join(current.path, 'packages', 'test-fixtures'));
    if (candidate.existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  throw StateError(
    '未找到 packages/test-fixtures，当前目录为 ${Directory.current.path}',
  );
}

String fixturePath(String relative) =>
    p.join(repositoryRoot.path, 'packages', 'test-fixtures', relative);

String readFixture(String relative) =>
    File(fixturePath(relative)).readAsStringSync();

/// fixture 服务基地址（默认端口 18080，与 `tools/fixture_server` 一致）。
String get fixtureBaseUrl =>
    Platform.environment['WEBHTV_FIXTURE_BASE'] ?? 'http://127.0.0.1:18080';

String get fixtureMediaUrl => '$fixtureBaseUrl/media/sample.m3u8';

String get fixtureMp4Url => '$fixtureBaseUrl/media/sample.mp4';

/// 播放 fixture 服务要求的 Header（缺失时返回 403）。
const Map<String, String> fixtureMediaHeaders = {
  'Referer': 'http://127.0.0.1:18080/',
  'User-Agent': 'WebHTV-PC/0.1 (Windows)',
};
