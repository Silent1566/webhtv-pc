// STYLE-SPIKE / THROWAWAY —— 液态玻璃可行性 spike 的对比画廊，不得被生产代码引用。
//
// 同一批内容渲染两遍：current 走 buildAppTheme + tokens 的真实材料，glass 用 GlassSurface。
// 三种底：hero（背景图 + BackdropScrim.hero）、page（背景图 + BackdropScrim.page）、
// solid（无背景图，纯 surface）。视口固定 1440x900，方便逐对所有像素做取证。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../backdrop_scrim.dart';
import '../tokens.dart';
import 'glass_surface.dart';

/// 背景底：仓库真实的三档画面构成。
enum SpikeBackdrop {
  /// 首屏 hero：背景图 + BackdropScrim.hero。
  hero,

  /// 页面级固定背景：背景图 + BackdropScrim.page。
  page,

  /// 无背景图，纯 surface。
  solid,
}

/// 表面材料：现状 vs 玻璃。
enum SpikeSurface { current, glass, glassDense }

const double spikeWidth = 1440;
const double spikeHeight = 900;

const Rect spikeHeaderBar = Rect.fromLTWH(24, 20, 1392, 52);
const Rect spikeLeftPanel = Rect.fromLTWH(24, 88, 460, 672);
const Rect spikeRightPanel = Rect.fromLTWH(508, 88, 908, 672);
const Rect spikePlayerBar = Rect.fromLTWH(24, 784, 1392, 92);

/// 取色探针：面板内确定没有字形的空区，贴着对应文字。
/// 对比度就是「探针平均色 vs 该处文字色」，见 test/style_spike_capture_test.dart。
const Rect spikeHeadingProbe = Rect.fromLTWH(150, 108, 150, 22);
const Rect spikeMetaProbe = Rect.fromLTWH(320, 156, 100, 18);
const Rect spikeBodyProbe = Rect.fromLTWH(528, 384, 240, 16);

/// 右面板右侧的一条空带：在对抗性底图上它落在暗半区，用来量「暗底上的暗字」。
const Rect spikeDarkProbe = Rect.fromLTWH(1150, 384, 240, 16);

/// 玻璃参数：暗色底需要更强的染底，才压得住对抗性背景。
/// 具体取值与推导见 task-1/report.md 的参数表。
double glassTintAlpha(Brightness brightness, {bool dense = false}) {
  final dark = brightness == Brightness.dark;
  if (dense) return dark ? 0.62 : 0.74;
  return dark ? 0.42 : 0.58;
}

double glassBlurSigma(Brightness brightness) =>
    brightness == Brightness.dark ? 26 : 20;

/// 对比画廊：固定 1440x900，内容与布局对两种表面完全一致。
class StyleSpikeGallery extends StatelessWidget {
  const StyleSpikeGallery({
    super.key,
    required this.backdrop,
    required this.surface,
    this.image,
  });

  final SpikeBackdrop backdrop;
  final SpikeSurface surface;

  /// hero / page 用同一张图；solid 忽略它。
  final ui.Image? image;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: spikeWidth,
      height: spikeHeight,
      child: Stack(
        children: [
          Positioned.fill(child: _backdropLayer(context)),
          Positioned.fromRect(
            rect: spikeHeaderBar,
            child: _surfaceBox(
              context,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.lg,
                vertical: AppSpace.sm,
              ),
              child: _header(theme, scheme),
            ),
          ),
          Positioned.fromRect(
            rect: spikeLeftPanel,
            child: _surfaceBox(
              context,
              padding: const EdgeInsets.all(AppSpace.lg + AppSpace.xs),
              child: _continueWatching(theme, scheme),
            ),
          ),
          Positioned.fromRect(
            rect: spikeRightPanel,
            child: _surfaceBox(
              context,
              padding: const EdgeInsets.all(AppSpace.lg + AppSpace.xs),
              child: _playbackSettings(theme, scheme),
            ),
          ),
          Positioned.fromRect(
            rect: spikePlayerBar,
            child: _surfaceBox(
              context,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
              child: _playerBar(theme, scheme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _backdropLayer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (backdrop == SpikeBackdrop.solid || image == null) {
      return ColoredBox(color: scheme.surface);
    }
    final scrim = backdrop == SpikeBackdrop.hero
        ? BackdropScrimKind.hero
        : BackdropScrimKind.page;
    return Stack(
      fit: StackFit.expand,
      children: [
        RawImage(
          image: image,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
        ),
        BackdropScrim(kind: scrim),
      ],
    );
  }

  /// 两种材料的分叉点：玻璃 vs 现状的发丝边不透明容器。
  ///
  /// 现状面不发明玻璃，只用 buildAppTheme 里真实存在的表面阶梯与 1px 发丝边。
  Widget _surfaceBox(
    BuildContext context, {
    required EdgeInsetsGeometry padding,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (surface != SpikeSurface.current) {
      final dense = surface == SpikeSurface.glassDense;
      return GlassSurface(
        blurSigma: glassBlurSigma(theme.brightness),
        tintAlpha: glassTintAlpha(theme.brightness, dense: dense),
        rimAlpha: theme.brightness == Brightness.dark ? 0.34 : 0.30,
        sheenAlpha: theme.brightness == Brightness.dark ? 0.10 : 0.14,
        saturation: theme.brightness == Brightness.dark ? 1.35 : 1.15,
        radius: AppRadius.lg,
        padding: padding,
        child: child,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(padding: padding, child: child),
    );
  }

  Widget _header(ThemeData theme, ColorScheme scheme) {
    final text = theme.textTheme;
    return Row(
      children: [
        Text(
          'WebHTV',
          style: text.titleLarge?.copyWith(letterSpacing: -0.4),
        ),
        const SizedBox(width: AppSpace.xl),
        for (final item in const ['首页', '发现', '直播', '片库'])
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.lg),
            child: Text(
              item,
              style: text.bodyMedium?.copyWith(
                color: item == '首页' ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        const Spacer(),
        Container(
          width: 300,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
            borderRadius: AppRadius.pillAll,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                '搜索片名 / 站源',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpace.md),
        CircleAvatar(
          radius: 16,
          backgroundColor: AppPalette.magnitude,
          child: Text(
            'M',
            style: text.labelLarge?.copyWith(color: const Color(0xFF1A1200)),
          ),
        ),
      ],
    );
  }

  Widget _continueWatching(ThemeData theme, ColorScheme scheme) {
    final text = theme.textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('继续观看', style: text.titleLarge),
            const Spacer(),
            Text(
              '全部 12 集',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        for (final item in _watchItems)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: SizedBox(
              height: 116,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 64,
                    height: 88,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: AppRadius.mdAll,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.movie_outlined,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                            fontWeight: AppWeight.title,
                          ),
                        ),
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          item.progress,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.sm,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.16),
                            borderRadius: AppRadius.smAll,
                          ),
                          child: Text(
                            item.magnitude,
                            style: text.labelSmall?.copyWith(
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _playbackSettings(ThemeData theme, ColorScheme scheme) {
    final text = theme.textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('播放设置', style: text.titleLarge),
        const SizedBox(height: AppSpace.sm),
        Text(
          '应用到当前剧集；单集改动会覆盖这里的默认值。',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpace.lg),
        for (final row in _settingRows)
          SizedBox(
            height: 68,
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(row.label, style: text.bodyMedium),
                            const SizedBox(height: 2),
                            Text(
                              row.hint,
                              style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        row.value,
                        style: text.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
              ],
            ),
          ),
        const SizedBox(height: AppSpace.xl),
        Text(
          '播放时会按当前选中的站源自动回退：先尝试 HDR 直通，失败再降级到 SDR 并保留色彩映射。'
          '切换站源不会重置播放进度，字幕与音轨选择会跟随剧集保存。',
          style: text.bodyMedium,
        ),
        const SizedBox(height: AppSpace.lg),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.md,
                vertical: AppSpace.xs,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
                borderRadius: AppRadius.smAll,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Text(
                    '本机 3 个站源可用',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const Spacer(),
        Row(
          children: [
            FilledButton(
              onPressed: () {},
              child: const Text('应用到全部剧集'),
            ),
            const SizedBox(width: AppSpace.md),
            TextButton(onPressed: () {}, child: const Text('恢复默认')),
          ],
        ),
      ],
    );
  }

  Widget _playerBar(ThemeData theme, ColorScheme scheme) {
    final text = theme.textTheme;
    return Row(
      children: [
        Icon(Icons.play_circle_fill_rounded, size: 36, color: scheme.primary),
        const SizedBox(width: AppSpace.lg),
        Text('00:42:18', style: text.bodySmall),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                children: [
                  Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: AppRadius.pillAll,
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: 0.72,
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: AppRadius.pillAll,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpace.md),
        Text('00:58:40', style: text.bodySmall),
        const SizedBox(width: AppSpace.xl),
        for (final icon in const [
          Icons.subtitles_outlined,
          Icons.graphic_eq_rounded,
          Icons.fullscreen_rounded,
        ])
          Padding(
            padding: const EdgeInsets.only(left: AppSpace.lg),
            child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          ),
        const SizedBox(width: AppSpace.xl),
        Text('1.0×', style: text.bodySmall),
      ],
    );
  }
}

class _WatchItem {
  const _WatchItem(this.title, this.progress, this.magnitude);

  final String title;
  final String progress;
  final String magnitude;
}

const List<_WatchItem> _watchItems = [
  _WatchItem('那一夜，我怀了社长的孩子', '第 07 集 · 42:18 / 48:00', '星等 2.1'),
  _WatchItem('夜航西飞', 'S02 E04 · 21:05 / 51:30', '星等 3.4'),
  _WatchItem('深海迷航', '第 12 集 · 已看完', '星等 1.8'),
];

class _SettingRow {
  const _SettingRow(this.label, this.hint, this.value);

  final String label;
  final String hint;
  final String value;
}

const List<_SettingRow> _settingRows = [
  _SettingRow('字幕语言', '按剧集记忆；无中文轨道时回退到英文', '中文简体'),
  _SettingRow('画面质量', 'HDR 直通失败时自动降级，不打断播放', '4K HDR'),
  _SettingRow('播放速度', '音调保持开启，不影响字幕计时', '1.0×'),
];
