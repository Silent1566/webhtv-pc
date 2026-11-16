import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/lut.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/ui/lut_menu.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';

void main() {
  late List<String> calls;
  late List<LutPreset> picked;

  setUp(() {
    calls = <String>[];
    picked = <LutPreset>[];
  });

  List<PlayerMenuItem> build({PlayerOptions options = const PlayerOptions()}) {
    return buildLutMenuItems(
      options: options,
      onOff: () => calls.add('off'),
      onPick: (preset) {
        calls.add('pick');
        picked.add(preset);
      },
      onMore: () => calls.add('more'),
    );
  }

  group('LUT 飞出子列', () {
    test('顺序固定：关闭 → 13 个内置 → 更多', () {
      final items = build();
      expect(items.length, 1 + builtinLutPresets.length + 1);
      expect(items.first.id, 'lut_off');
      expect(items.last.id, 'lut_more');
      expect(
        items.map((e) => e.id).toList(),
        [
          'lut_off',
          for (final preset in builtinLutPresets) 'lut_${preset.id}',
          'lut_more',
        ],
      );
      // 标签用中文名，不重复尺寸（尺寸在设置页那一行看）。
      expect(items[1].label, builtinLutPresets.first.name);
    });

    test('未启用时只勾「关闭 LUT」', () {
      final items = build();
      final selected = items.where((e) => e.selected).toList();
      expect(selected.length, 1);
      expect(selected.single.id, 'lut_off');
    });

    test('启用内置项时只勾它自己，且该组会有生效提示', () {
      final items = build(
        options: const PlayerOptions(
          lutPath: '/cache/lut/cyberpunk.cube',
          lutPresetId: 'cyberpunk',
        ),
      );
      final selected = items.where((e) => e.selected).toList();
      expect(selected.length, 1);
      expect(selected.single.id, 'lut_cyberpunk');
      // 父项（player_page 里）靠「任一孩子 selected」点亮提示点。
      expect(items.any((e) => e.selected), isTrue);
    });

    test('选的是用户文件（无 preset id）时，关闭与内置项都不勾', () {
      final items = build(
        options: const PlayerOptions(lutPath: 'C:/luts/mine.cube'),
      );
      expect(items.where((e) => e.selected), isEmpty);
    });
  });

  group('回调', () {
    test('关闭项触发 onOff', () {
      build().first.onSelect!();
      expect(calls, ['off']);
    });

    test('内置项把对应预设回传给 onPick', () {
      final items = build();
      final target = items[3];
      target.onSelect!();
      expect(calls, ['pick']);
      expect(picked.single.id, builtinLutPresets[2].id);
    });

    test('更多项触发 onMore', () {
      build().last.onSelect!();
      expect(calls, ['more']);
    });

    test('带子列的父项本身不发动作', () {
      // 父项由播放页拼装，这里只锁一份约定：子列里的叶子都有 onSelect。
      final items = build();
      expect(items.every((e) => e.onSelect != null), isTrue);
      expect(items.every((e) => e.children.isEmpty), isTrue);
    });
  });
}
