import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';

void main() {
  test('cate is a non-null marker and survives roundtrip unchanged', () {
    for (final value in [
      false,
      0,
      '',
      '原样值',
      <String, Object?>{'nested': 1},
      <Object>[],
    ]) {
      final vod = Vod.fromJson({
        'vod_id': 'plain',
        'vod_name': '目录',
        'cate': value,
      })!;
      expect(vod.isFolder, isTrue, reason: 'cate=$value 非空指针即目录，不按真假判断');
      expect(vod.toJson()['cate'], value);
      expect(Vod.fromJson(vod.toJson())!.isFolder, isTrue);
    }
    expect(
      Vod.fromJson({'vod_id': 'plain', 'vod_name': '文件', 'cate': null})!
          .isFolder,
      isFalse,
    );
  });

  test('explicit folder survives roundtrip without URL or name guessing', () {
    final vod = Vod.fromJson({
      'vod_id': '/a/b',
      'vod_name': '文件夹',
      'vod_tag': 'folder',
    })!;
    expect(vod.isFolder, isTrue);
    expect(Vod.fromJson(vod.toJson())!.isFolder, isTrue);
    for (final id in [
      'https://alist.example/folder',
      'alist:/root',
      '/files',
    ]) {
      expect(Vod(vodId: id, vodName: 'AList 网盘').isFolder, isFalse);
    }
    expect(Vod(vodId: 'atvp_detail:123', vodName: '历史记录').isFolder, isTrue);
    expect(
      Vod(vodId: 'atvp_resume:123', vodName: '播放记录', vodTag: 'file').isFolder,
      isFalse,
    );
  });
}
