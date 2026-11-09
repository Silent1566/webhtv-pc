/// 深色/浅色主题（§17.4 支持深色模式、中文优先）。
///
/// 世界：**星等星表**（impeccable 方向轮 seed `707d94ea`）。
/// 它只借四样东西——字体、配色、密度、一个 signature move；
/// 导航与控件保持平台标准（Material 3），世界不重写它们。
///
/// 两条与改造前不同的关键决定：
///
/// 1. **不再用 `ColorScheme.fromSeed`**。种子算法产出的是一组与主题无关的中性灰阶，
///    也就是"灰底加一个强调色"——那正是这一类产品的默认值，不是克制。
///    星等星表的表面是从深靛底色**按色相偏移**出来的三级阶梯，必须显式给出。
///
/// 2. **中文字重修对**。微软雅黑只有 Light/Regular/Bold 三个真实字重，没有真 Medium；
///    改造前全站 18 处用 `w600` 当标题字重，会走合成加粗（笔画粘连、小字号发糊）。
///    这里标题统一映射到真实存在的 `w700`，层级差靠字号与颜色拉开。
library;

import 'package:flutter/material.dart';

import 'app_motion.dart';
import 'tokens.dart';

/// 中文字体优先的字体族回退链。
///
/// Windows 使用微软雅黑，Linux 使用 Noto Sans CJK，macOS 使用苹方；
/// 这样既满足“中文优先”，又避免在缺少字体的机器上出现方块字。
const List<String> _fontFallback = [
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'PingFang SC',
  'Segoe UI',
  'Roboto',
];

// ---------------------------------------------------------------------------
// 配色方案
// ---------------------------------------------------------------------------

/// 星等星表的 `ColorScheme`。
///
/// 全部角色显式给出：`surface` 三级阶梯从底色按色相偏移，
/// `primary` 是星等琥珀（唯一强调色），四个状态色挂在 `AppSemanticColors` 上。
ColorScheme _scheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  if (dark) {
    return const ColorScheme(
      brightness: Brightness.dark,
      // 星等琥珀：唯一强调色，只用在真正是"星等"的地方。
      primary: AppPalette.magnitude,
      onPrimary: Color(0xFF1A1200),
      primaryContainer: Color(0xFF3A2A00),
      onPrimaryContainer: Color(0xFFFFE9B8),
      // 次级用同一色相的低饱和版本，而不是另一支色系。
      secondary: Color(0xFF8FA0C8),
      onSecondary: Color(0xFF0B0E1A),
      secondaryContainer: Color(0xFF243052),
      onSecondaryContainer: Color(0xFFD6DEF2),
      tertiary: Color(0xFF9BB8E0),
      onTertiary: Color(0xFF0B0E1A),
      tertiaryContainer: Color(0xFF1E2C46),
      onTertiaryContainer: Color(0xFFCFE0F7),
      error: AppPalette.statusFailed,
      onError: Color(0xFF2B0009),
      errorContainer: Color(0xFF4A1020),
      onErrorContainer: Color(0xFFFFD9E0),
      // 三级表面阶梯：从深靛底色色相偏移，不是中性灰。
      surface: AppPalette.nightGround,
      onSurface: AppPalette.nightInk,
      onSurfaceVariant: AppPalette.nightInkMuted,
      surfaceContainerLowest: Color(0xFF070911),
      surfaceContainerLow: AppPalette.nightSurface1,
      surfaceContainer: AppPalette.nightSurface2,
      surfaceContainerHigh: AppPalette.nightSurface3,
      surfaceContainerHighest: Color(0xFF2C3654),
      // 分隔线用底色的提亮，不用灰。
      outline: Color(0xFF3A4560),
      outlineVariant: AppPalette.nightLine,
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: AppPalette.nightInk,
      onInverseSurface: AppPalette.nightGround,
      inversePrimary: AppPalette.magnitudeOnLight,
    );
  }
  return const ColorScheme(
    brightness: Brightness.light,
    // 亮色底上琥珀压深才能达到 4.5:1；亮色不是暗色的自动反转。
    primary: AppPalette.magnitudeOnLight,
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFFFE7B0),
    onPrimaryContainer: Color(0xFF2A1C00),
    secondary: Color(0xFF44557A),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFDCE4F5),
    onSecondaryContainer: Color(0xFF111B33),
    tertiary: Color(0xFF3C5A82),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFD8E5F8),
    onTertiaryContainer: Color(0xFF0F1F35),
    error: AppPalette.statusFailedOnLight,
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDADF),
    onErrorContainer: Color(0xFF40000D),
    surface: AppPalette.dayGround,
    onSurface: AppPalette.dayInk,
    onSurfaceVariant: AppPalette.dayInkMuted,
    // 外壳比内容退后一档（比底色更冷更深），卡片才是纯白。
    // 第一版把外壳也写成纯白，导致外壳与卡片同级、阶梯塌陷。
    surfaceContainerLowest: AppPalette.dayChrome,
    surfaceContainerLow: AppPalette.daySurface1,
    surfaceContainer: AppPalette.daySurface2,
    surfaceContainerHigh: AppPalette.daySurface3,
    surfaceContainerHighest: Color(0xFFCBD4E6),
    outline: Color(0xFF97A3BC),
    outlineVariant: AppPalette.dayLine,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: AppPalette.dayInk,
    onInverseSurface: AppPalette.dayGround,
    inversePrimary: AppPalette.magnitude,
  );
}

// ---------------------------------------------------------------------------
// 字体阶梯
// ---------------------------------------------------------------------------

/// 中文优先的字体阶梯。
///
/// **保留 Material 3 的字号与行高度量，只改字重与颜色。**
///
/// 为什么不动度量——这是实测出来的，不是保守起见：
/// 96 个测试文件里有大量 `tester.tap` **不带 `ensureVisible`**
/// （例如 `phase5_sync_ui_test.dart:210` 的 `tapIo(tester, find.text('接入设备'))`），
/// 任何净高度变化都会把控件挤出 800×600 视口，点击打空、后续断言连锁失败。
/// 实测把 `bodySmall` 行高从 M3 的 1.33 提到 1.65，`phase5_sync_ui_test.dart`
/// 会挂 3 个用例；把 `theme.dart` 还原成原始版本后该文件全绿（+26）。
///
/// 而**字重是度量中性的**：同一字族的 Light/Regular/Bold 字宽一致，
/// 所以把 `w600` 换成真实存在的 `w700` 不会移动任何盒子，却修掉了
/// 雅黑上没有真 Medium 导致的合成加粗（笔画粘连、小字号发糊）。
/// 这正是本次要拿的收益，且零布局风险。
///
/// 结论：字号/行高的"中文更大行高"改进被测试约束挡住，已记录在
/// `.impeccable/surfaces/lib-ui-app-dart.md` 的「未决」里，需要单独一轮
/// 连同测试的 `ensureVisible` 一起改，不能夹在主题层里悄悄改。
TextTheme _textTheme(ThemeData base) {
  final t = base.textTheme.apply(fontFamilyFallback: _fontFallback);
  return t.copyWith(
    displaySmall: t.displaySmall?.copyWith(fontWeight: AppWeight.display),
    headlineMedium: t.headlineMedium?.copyWith(fontWeight: AppWeight.display),
    headlineSmall: t.headlineSmall?.copyWith(fontWeight: AppWeight.display),
    titleLarge: t.titleLarge?.copyWith(fontWeight: AppWeight.title),
    titleMedium: t.titleMedium?.copyWith(fontWeight: AppWeight.title),
    titleSmall: t.titleSmall?.copyWith(fontWeight: AppWeight.title),
    bodyLarge: t.bodyLarge?.copyWith(fontWeight: AppWeight.body),
    bodyMedium: t.bodyMedium?.copyWith(fontWeight: AppWeight.body),
    bodySmall: t.bodySmall?.copyWith(fontWeight: AppWeight.body),
    labelLarge: t.labelLarge?.copyWith(fontWeight: AppWeight.label),
    labelMedium: t.labelMedium?.copyWith(fontWeight: AppWeight.label),
    labelSmall: t.labelSmall?.copyWith(fontWeight: AppWeight.label),
  );
}

// ---------------------------------------------------------------------------
// 主题
// ---------------------------------------------------------------------------

/// 构造应用主题。
///
/// 表面一律用**发丝边 + 表面阶梯**表达层级，不用阴影堆叠：
/// 这是星等星表的世界（一片平坦的场），阴影会把点阵场的平度破坏掉。
ThemeData buildAppTheme(Brightness brightness) {
  final scheme = _scheme(brightness);
  final semantic = defaultSemanticColors(brightness);
  final hairline = scheme.outlineVariant.withValues(alpha: 0.72);

  // 先建 M3 基线，再从它派生字体阶梯——保证度量与 M3 完全一致（见 _textTheme）。
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    extensions: <ThemeExtension<dynamic>>[semantic],
    // 交互态从调色板取色，不用框架默认的黑/白叠加。这些都是非布局属性。
    focusColor: scheme.primary.withValues(alpha: 0.16),
    hoverColor: scheme.onSurface.withValues(alpha: 0.045),
    splashColor: scheme.primary.withValues(alpha: 0.09),
    highlightColor: scheme.primary.withValues(alpha: 0.06),
    dividerColor: hairline,
  );
  final text = _textTheme(base);

  return base.copyWith(
    pageTransitionsTheme: appPageTransitionsTheme(),
    textTheme: text,
    primaryTextTheme: text.apply(fontFamilyFallback: _fontFallback),
    // ---- 顶栏：与内容同底，靠发丝线分隔，不靠 elevation ----
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleMedium,
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 20),
    ),

    // ---- 卡片：发丝边 + 表面阶梯 ----
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
    ),

    // ---- 侧栏：世界在这里"拥有整片区域"——用表面阶梯与星等指示器 ----
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.surfaceContainerHigh,
      indicatorShape: const RoundedRectangleBorder(
        borderRadius: AppRadius.mdAll,
      ),
      selectedIconTheme: IconThemeData(color: semantic.magnitude, size: 21),
      unselectedIconTheme: IconThemeData(
        color: scheme.onSurfaceVariant,
        size: 21,
      ),
      selectedLabelTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 11.5,
        fontWeight: AppWeight.title,
        fontFamilyFallback: _fontFallback,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: 11.5,
        fontWeight: AppWeight.label,
        fontFamilyFallback: _fontFallback,
      ),
      useIndicator: true,
    ),

    listTileTheme: ListTileThemeData(
      dense: false,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      selectedColor: scheme.onSurface,
      selectedTileColor: scheme.surfaceContainerHigh,
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      labelStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        textStyle: text.labelLarge?.copyWith(fontWeight: AppWeight.title),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        foregroundColor: scheme.onSurface,
        textStyle: text.labelLarge,
        side: BorderSide(color: hairline),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        textStyle: text.labelLarge,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        highlightColor: scheme.primary.withValues(alpha: 0.10),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
      ),
    ),

    // ---- 标签：胶囊形，选中态用星等琥珀 ----
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainer,
      selectedColor: scheme.primary.withValues(alpha: 0.18),
      side: BorderSide(color: hairline),
      labelStyle: text.labelLarge?.copyWith(color: scheme.onSurface),
      secondaryLabelStyle: text.labelLarge?.copyWith(color: scheme.onSurface),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
      ),
      showCheckmark: false,
    ),

    dividerTheme: DividerThemeData(
      space: 1,
      thickness: 1,
      color: hairline,
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: text.bodyMedium,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      elevation: 0,
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: hairline),
      ),
      textStyle: text.bodySmall,
      waitDuration: const Duration(milliseconds: 400),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearMinHeight: 3,
      linearTrackColor: scheme.surfaceContainerHigh,
      circularTrackColor: Colors.transparent,
    ),

    // ---- 框架自带的表面也要按调色板上色 ----
    // 滚动条、选区、光标、焦点环是最便宜也最容易被跳过的一环：
    // 它们不属于任何设计系统，默认值是框架的灰。
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(9),
      radius: const Radius.circular(5),
      crossAxisMargin: 2,
      thumbColor: WidgetStateProperty.resolveWith((states) {
        final dragging = states.contains(WidgetState.dragged) ||
            states.contains(WidgetState.hovered);
        return scheme.onSurfaceVariant.withValues(alpha: dragging ? 0.62 : 0.34);
      }),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    textSelectionTheme: TextSelectionThemeData(
      selectionColor: scheme.primary.withValues(alpha: 0.28),
      cursorColor: scheme.primary,
      selectionHandleColor: scheme.primary,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdAll,
        side: BorderSide(color: hairline),
      ),
      textStyle: text.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.onPrimary;
        return scheme.onSurfaceVariant;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return scheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return hairline;
      }),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.14),
      trackHeight: 3,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primary.withValues(alpha: 0.18),
        selectedForegroundColor: scheme.onSurface,
        foregroundColor: scheme.onSurfaceVariant,
        side: BorderSide(color: hairline),
        textStyle: text.labelMedium,
      ),
    ),
  );
}
