import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/services/subtitle_asset_store.dart';

List<int> zipOf(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subtitle_store_test_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  SubtitleAssetStore store(
    http.Client client, {
    int maxFiles = 100,
    int maxDownloadBytes = 1 << 20,
  }) => SubtitleAssetStore(
    cacheDir: '${temp.path}/subtitles',
    client: client,
    maxFiles: maxFiles,
    maxDownloadBytes: maxDownloadBytes,
  );

  Matcher resolveError(String code) => throwsA(
    isA<SubtitleResolveException>().having((e) => e.code, 'code', code),
  );

  test('纯文本下载：按 URL 扩展名落盘，内容不丢', () async {
    // 中文必须走 bytes：http.Response 的字符串构造按 latin1 编码，会直接抛。
    final client = MockClient(
      (request) async => http.Response.bytes(
        utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n你好\n'),
        200,
      ),
    );
    final asset = await store(
      client,
    ).download(url: 'https://x.test/a.srt', nameHint: '剧名 第一集');
    expect(asset.format, 'srt');
    expect(asset.path, endsWith('.srt'));
    expect(await File(asset.path).readAsString(), contains('你好'));
  });

  test('ZIP：.ass 优先于 .srt，format 由最终扩展名决定（D1）', () async {
    final client = MockClient(
      (request) async => http.Response.bytes(
        zipOf({'a.srt': 'srt text', 'b.ass': '[Script Info]'}),
        200,
      ),
    );
    final asset = await store(
      client,
    ).download(url: 'https://x.test/dl', nameHint: 'x', fallbackFormat: 'srt');
    expect(asset.format, 'ass');
    expect(await File(asset.path).readAsString(), contains('[Script Info]'));
  });

  test('ZIP 内无字幕条目 → zip_no_subtitle（D2：绝不把 ZIP 交给播放器）', () async {
    final client = MockClient(
      (request) async =>
          http.Response.bytes(zipOf({'readme.txt': 'nothing'}), 200),
    );
    await expectLater(
      store(client).download(url: 'https://x.test/dl', nameHint: 'x'),
      resolveError('zip_no_subtitle'),
    );
  });

  test('ZIP 路径穿越条目被拒绝', () async {
    final client = MockClient(
      (request) async =>
          http.Response.bytes(zipOf({'../evil.srt': 'x'}), 200),
    );
    await expectLater(
      store(client).download(url: 'https://x.test/dl', nameHint: 'x'),
      resolveError('zip_traversal'),
    );
  });

  test('ZIP 单条目超过上限被拒绝', () async {
    final client = MockClient(
      (request) async => http.Response.bytes(zipOf({'big.srt': 'x' * 32}), 200),
    );
    final guarded = SubtitleAssetStore(
      cacheDir: '${temp.path}/subtitles',
      client: client,
      maxEntryBytes: 8,
    );
    await expectLater(
      guarded.download(url: 'https://x.test/dl', nameHint: 'x'),
      resolveError('zip_entry_too_large'),
    );
  });

  test('下载超过上限 → too_large，不写半截文件', () async {
    final client = MockClient(
      (request) async => http.Response.bytes(Uint8List(64), 200),
    );
    await expectLater(
      store(client, maxDownloadBytes: 8).download(
        url: 'https://x.test/a.srt',
        nameHint: 'x',
      ),
      resolveError('too_large'),
    );
  });

  test('非 2xx → http_404', () async {
    final client = MockClient((request) async => http.Response('', 404));
    await expectLater(
      store(client).download(url: 'https://x.test/a.srt', nameHint: 'x'),
      resolveError('http_404'),
    );
  });

  test('缓存目录为空时显式失败（不写当前工作目录）', () async {
    final client = MockClient((request) async => http.Response('x', 200));
    final broken = SubtitleAssetStore(cacheDir: '', client: client);
    await expectLater(
      broken.download(url: 'https://x.test/a.srt', nameHint: 'x'),
      resolveError('no_cache_dir'),
    );
  });

  test('缓存裁剪：超过 maxFiles 时保留最新的一批', () async {
    final dir = Directory('${temp.path}/subtitles');
    await dir.create(recursive: true);
    for (var i = 0; i < 5; i++) {
      final file = File('${dir.path}/old_$i.srt');
      await file.writeAsString('old');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final client = MockClient(
      (request) async => http.Response('new subtitle', 200),
    );
    await store(client, maxFiles: 2).download(
      url: 'https://x.test/new.srt',
      nameHint: 'new',
    );
    final remaining = await dir
        .list()
        .where((entity) => entity is File)
        .length;
    expect(remaining, 3, reason: '裁剪到 2 个旧文件 + 1 个新文件');
  });
}
