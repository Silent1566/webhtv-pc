/// 布局密度门禁：卡片尺寸只跟**窗口短边**走，且有上下限。
///
/// 锁三件事：
/// 1. 同一短边、不同宽度 → 同一档（宽度只该决定列数，不该决定卡片多大）；
/// 2. 档位夹在 0.95–1.35，且量化到 0.05（避免 resize 时每帧抖 1px）；
/// 3. 列宽永远不会低于目标宽的 92%（原实现用 12 列硬上限，1920 宽反而
///    比 1366 宽更小——窗口越宽卡片越小）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/layout_scale.dart';

void main() {
  testWidgets('密度档只由短边决定', (tester) async {
    Future<double> scaleFor(Size size) async {
      late double scale;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              scale = LayoutScale.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return scale;
    }

    expect(await scaleFor(const Size(1280, 800)), 0.95);
    expect(await scaleFor(const Size(1920, 1080)), 1.2);
    expect(await scaleFor(const Size(2560, 1440)), 1.35);
    // 超宽屏：短边不变，档位不涨。
    expect(await scaleFor(const Size(3440, 1440)), 1.35);
    // 宽度不是输入：3440 宽但只有 800 高，仍是最小档。
    expect(await scaleFor(const Size(3440, 800)), 0.95);
  });

  test('列宽不低于目标宽的 92%', () {
    const windows = <double>[1024, 1280, 1366, 1920, 2560, 3440];
    const scales = <double>[0.95, 1.1, 1.2, 1.35];
    for (final window in windows) {
      final usable = window - 32;
      for (final scale in scales) {
        final target = 176 * scale;
        final spacing = 12 * scale;
        final columns = LayoutScale.columnsFor(usable, target, spacing);
        final width = (usable - (columns - 1) * spacing) / columns;
        expect(columns, greaterThanOrEqualTo(2));
        expect(
          width,
          greaterThanOrEqualTo(target * 0.92 - 0.01),
          reason: 'window=$window scale=$scale',
        );
      }
    }
  });
}
