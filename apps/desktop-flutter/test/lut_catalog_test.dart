import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/lut.dart';

/// 内置预设目录与 .cube 解析。
///
/// 这里**不** mock 资源：assets/lut/ 是真的随包分发的文件，测试直接读它。
/// 换句话说，只要有人把某个 .cube 删了或写坏了，这条用例就会红。
void main() {
  group('内置预设目录', () {
    test('id 唯一且字段自洽', () {
      final ids = builtinLutPresets.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'id 必须唯一');
      expect(ids, isNotEmpty);
      for (final preset in builtinLutPresets) {
        expect(preset.isBundled, isTrue);
        expect(preset.name.trim(), isNotEmpty);
        expect(preset.path, startsWith(bundledLutAssetDir));
        expect(preset.path, endsWith('.cube'));
        expect(preset.size, inInclusiveRange(2, maxLutSize));
      }
    });

    test('13 个预设与安卓对齐', () {
      expect(builtinLutPresets.length, 13);
      expect(findBuiltinLut('cyberpunk')?.name, '赛博朋克');
      expect(findBuiltinLut('  '), isNull);
      expect(findBuiltinLut('nope'), isNull);
    });

    test('每个资源都在仓库里且能被 parseCube 解析', () async {
      final root = Directory.current.path;
      for (final preset in builtinLutPresets) {
        final file = File('$root/${preset.path}');
        expect(await file.exists(), isTrue, reason: '缺少资源 ${preset.path}');
        final text = await file.readAsString();
        final parsed = parseCube(text, path: preset.path, id: preset.id);
        expect(parsed.ok, isTrue, reason: '${preset.path}: ${parsed.error}');
        expect(
          parsed.preset!.size,
          preset.size,
          reason: '${preset.id} 尺寸不符',
        );
      }
    });
  });

  group('parseCube', () {
    test('接受最小 2³', () {
      final buffer = StringBuffer('LUT_3D_SIZE 2\n');
      for (var i = 0; i < 8; i++) {
        buffer.writeln('0.0 0.0 0.0');
      }
      final parsed = parseCube(buffer.toString(), path: 'x.cube');
      expect(parsed.ok, isTrue);
      expect(parsed.preset!.size, 2);
      expect(parsed.preset!.name, 'x.cube');
    });

    test('拒绝 1D', () {
      final parsed = parseCube('LUT_1D_SIZE 32\n', path: 'x.cube');
      expect(parsed.ok, isFalse);
      expect(parsed.error, contains('1D'));
    });

    test('拒绝行数不符', () {
      final parsed = parseCube('LUT_3D_SIZE 2\n0 0 0\n', path: 'x.cube');
      expect(parsed.ok, isFalse);
      expect(parsed.error, contains('行数'));
    });

    test('拒绝空路径与非数字', () {
      expect(parseCube('LUT_3D_SIZE 2\n', path: '  ').ok, isFalse);
      expect(parseCube('LUT_3D_SIZE 2\n0 0 x\n', path: 'a.cube').ok, isFalse);
    });

    test('TITLE 优先于文件名，displayName 优先于 TITLE', () {
      final body = StringBuffer('TITLE "Cinema"\nLUT_3D_SIZE 2\n');
      for (var i = 0; i < 8; i++) {
        body.writeln('0 0 0');
      }
      expect(parseCube(body.toString(), path: '/a/b.cube').preset!.name, 'Cinema');
      expect(
        parseCube(
          body.toString(),
          path: '/a/b.cube',
          displayName: '自定义',
        ).preset!.name,
        '自定义',
      );
    });
  });

  group('buildLutVfArgument', () {
    test('空路径表示清除', () {
      expect(buildLutVfArgument(null), '');
      expect(buildLutVfArgument('  '), '');
    });

    test('反斜杠转正斜杠、单引号转义', () {
      expect(
        buildLutVfArgument(r'C:\luts\a b.cube'),
        "lavfi=[lut3d=file='C:/luts/a b.cube']",
      );
      expect(
        buildLutVfArgument("/l/it's.cube"),
        r"lavfi=[lut3d=file='/l/it\'s.cube']",
      );
    });
  });

  group('LutPreset 序列化', () {
    test('往返保持字段', () {
      const preset = LutPreset(
        id: 'utopia',
        path: 'assets/lut/utopia.cube',
        name: '乌托邦',
        size: 33,
        source: LutSource.bundled,
      );
      final back = LutPreset.fromJson(preset.toJson())!;
      expect(back.id, preset.id);
      expect(back.path, preset.path);
      expect(back.name, preset.name);
      expect(back.size, preset.size);
      expect(back.source, LutSource.bundled);
      expect(back.sizeLabel, '33³');
    });

    test('非法尺寸回落 null', () {
      expect(LutPreset.fromJson({'path': 'a.cube', 'size': 1}), isNull);
      expect(LutPreset.fromJson({'path': 'a.cube', 'size': 999}), isNull);
      expect(LutPreset.fromJson({'path': '  ', 'size': 33}), isNull);
      expect(LutPreset.fromJson('nope'), isNull);
    });
  });
}
