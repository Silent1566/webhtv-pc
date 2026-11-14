import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

void main() {
  test('播放器画面模式映射到真实 Video fit/aspectRatio', () {
    expect(PlayerVideoFitMode.contain.fit, BoxFit.contain);
    expect(PlayerVideoFitMode.contain.aspectRatio, isNull);
    expect(PlayerVideoFitMode.cover.fit, BoxFit.cover);
    expect(PlayerVideoFitMode.fill.fit, BoxFit.fill);
    expect(PlayerVideoFitMode.ratio16x9.fit, BoxFit.contain);
    expect(PlayerVideoFitMode.ratio16x9.aspectRatio, closeTo(16 / 9, 0.001));
    expect(PlayerVideoFitMode.ratio4x3.aspectRatio, closeTo(4 / 3, 0.001));
  });

  test('播放器画面模式提供可直接用于设置菜单的中文名称', () {
    expect(
      PlayerVideoFitMode.values.map((mode) => mode.label),
      ['原始比例', '裁切铺满', '拉伸填充', '固定 16:9', '固定 4:3'],
    );
  });

  test('播放器手势与桌面播放器一致：单击播放/暂停，双击全屏', () {
    // 上游安卓控制层是「单击显隐控制栏、双击全屏/播放」；桌面播放器
    // （PotPlayer / VLC）把单击让给传输控制（`design/01` §4.6）。
    // 这个差异是**产品决策**，不是疏漏——这里锁的就是新语义。
    expect(
      resolvePlayerGesture(doubleClick: false),
      PlayerGestureAction.togglePlayback,
    );
    expect(
      resolvePlayerGesture(doubleClick: true),
      PlayerGestureAction.togglePlaybackAndFullscreen,
    );
  });

  test('字幕默认透明底并保留描边，样式参数映射到 media-kit 配置', () {
    const defaults = PlayerSubtitleStyle();
    expect(defaults.configuration.style.backgroundColor, Colors.transparent);
    expect(defaults.configuration.style.shadows, isNotEmpty);
    expect(defaults.configuration.padding.bottom, 24);

    final custom = defaults.copyWith(
      backgroundOpacity: 0.5,
      textScale: 1.5,
      bottomPadding: 72,
      outlineWidth: 0,
    );
    expect(custom.configuration.style.backgroundColor?.a, closeTo(0.5, 0.01));
    expect(custom.configuration.style.fontSize, 48);
    expect(custom.configuration.style.shadows, isEmpty);
    expect(custom.configuration.padding.bottom, 72);
  });
}
