import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/model_catalog.dart';
import 'package:webhtv_pc/services/audio_ai/audio_model_manager.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late AudioModelManager manager;
  late RealtimeModelSpec spec;
  late List<int> content;
  final requests = <String?>[];
  bool corrupt = false;
  bool slow = false;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('audio_ai_models_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    manager = AudioModelManager(root: root);
    content = List.generate(2048, (i) => i % 251);
    final file = RealtimeModelFile(
      relativePath: 'model.onnx',
      url: 'http://127.0.0.1:${server.port}/model',
      size: content.length,
      sha256: sha256.convert(content).toString(),
    );
    spec = RealtimeModelSpec(
      id: 'fixture',
      name: 'fixture',
      directory: 'fixture',
      engine: RealtimeSpeechEngine.onlineTransducer,
      minRamMb: 1,
      needsVad: false,
      files: [file],
    );
    requests.clear();
    corrupt = false;
    slow = false;
    server.listen((request) async {
      final range = request.headers.value('range');
      requests.add(range);
      final offset = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (offset > 0) {
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes $offset-${content.length - 1}/${content.length}',
        );
      }
      final data = corrupt ? List<int>.filled(content.length, 5) : content;
      if (slow) {
        for (var i = offset; i < data.length; i += 64) {
          request.response.add(data.sublist(i, (i + 64).clamp(0, data.length)));
          try {
            await request.response.flush();
          } catch (_) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      } else {
        request.response.add(data.sublist(offset));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    manager.close();
    await server.close(force: true);
    await root.delete(recursive: true);
  });
  test('真实本地HTTP下载并整包校验', () async {
    final progress = <double>[];
    await manager.download(spec, onProgress: (p) => progress.add(p.value));
    expect(await manager.verify(spec), isEmpty);
    expect(manager.isReadySync(spec), isTrue);
    expect(progress.last, 1);
    expect(await manager.fileOf(spec, spec.files.first).readAsBytes(), content);
  });
  test('Range断点续传保留已有字节', () async {
    final part = manager.partialOf(spec, spec.files.first);
    await part.parent.create(recursive: true);
    await part.writeAsBytes(content.sublist(0, 512));
    await manager.download(spec);
    expect(requests.single, 'bytes=512-');
    expect(await manager.verify(spec), isEmpty);
  });
  test('同尺寸坏hash拒绝安装', () async {
    corrupt = true;
    await expectLater(
      manager.download(spec),
      throwsA(isA<ModelIntegrityException>()),
    );
    expect(manager.isReadySync(spec), isFalse);
    expect(await manager.fileOf(spec, spec.files.first).exists(), isFalse);
  });
  test('取消保留part，下一次下载续传且不激活坏包', () async {
    slow = true;
    var cancel = false;
    await expectLater(
      manager.download(
        spec,
        isCancelled: () => cancel,
        onProgress: (p) {
          if (p.fileBytes >= 128) cancel = true;
        },
      ),
      throwsA(isA<ModelDownloadCancelled>()),
    );
    final part = manager.partialOf(spec, spec.files.first);
    expect(await part.exists(), isTrue);
    expect(await part.length(), greaterThan(0));
    expect(manager.isReadySync(spec), isFalse);
    cancel = false;
    slow = false;
    await manager.download(spec);
    expect(requests.last, startsWith('bytes='));
    expect(await manager.verify(spec), isEmpty);
  });
  test('本地导入校验：坏hash不替换已经有效模型', () async {
    await manager.download(spec);
    final imported = File('${root.path}/import.onnx');
    await imported.writeAsBytes(content);
    await manager.importLocal(spec, {'model.onnx': imported.path});
    expect(await manager.verify(spec), isEmpty);
    await imported.writeAsBytes(List.filled(content.length, 0));
    await expectLater(
      manager.importLocal(spec, {'model.onnx': imported.path}),
      throwsA(isA<ModelIntegrityException>()),
    );
    expect(await manager.verify(spec), isEmpty);
  });
  test('verify发现磁盘同尺寸损坏，不将大小就绪误当可信hash', () async {
    await manager.download(spec);
    await manager
        .fileOf(spec, spec.files.first)
        .writeAsBytes(List.filled(content.length, 0));
    expect(await manager.verify(spec), contains('model.onnx: sha256 mismatch'));
  });
  test('描述包含固定来源hash，删除移除模型', () async {
    await manager.download(spec);
    final description = await manager.describe(spec);
    expect(description['ready'], isTrue);
    expect(jsonEncode(description), contains(spec.files.first.sha256));
    await manager.delete(spec);
    expect(manager.isReadySync(spec), isFalse);
  });
}
