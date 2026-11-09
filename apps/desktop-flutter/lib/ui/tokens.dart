/// 设计 token 层。
///
/// 为什么需要这一层：改造前 `theme.dart` 只有 `ColorScheme.fromSeed` 的默认值微调，
/// 于是全站散出 **16 个间距值、11 个圆角值、7 个字号值**，每个页面各自拍脑袋定节奏
/// （盘点证据：`EdgeInsets.*` 100 处 / 165 个数值 token，`BorderRadius.circular` 38 处，
/// 裸 `TextStyle(` 21 处分布在 10 个文件里）。
///
/// 这里把那些散值收敛成标度，并补上 Material 3 没有的三类东西：
/// 语义状态色（站源健康是产品的核心信息）、中文字重映射、动效标度。
///
/// 世界：**星等星表**（impeccable 方向轮 seed `707d94ea`，assigned index 4）。
/// 它只借四样东西——字体、配色、密度、一个 signature move；导航与控件保持平台标准。
library;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// 标度
// ---------------------------------------------------------------------------

/// 间距标度（4 的倍数）。
///
/// 收敛前的高频值是 8/12/16，但混着 5/7/11/18/44 这种一次性值，
/// 且 `SizedBox` 的宽高在小步长上互相矛盾（宽从不用 2/18，高从不用 20）。
abstract final class AppSpace {
  /// 4 —— 图标与文字之间的贴合间距。
  static const double xs = 4;

  /// 8 —— 同一组内的行间距。
  static const double sm = 8;

  /// 12 —— 组内的常规间距。
  static const double md = 12;

  /// 16 —— 卡片内边距、区块内的标准间距。
  static const double lg = 16;

  /// 24 —— 区块之间的分隔。
  static const double xl = 24;

  /// 32 —— 页面级留白。
  static const double xxl = 32;

  /// 48 —— 空状态与页面顶部的呼吸区。
  static const double huge = 48;
}

/// 圆角标度。
///
/// 收敛前 8 是事实上的默认（15 次），12 只在 `theme.dart` 里被命名过一次，
/// 另有 7/10/14/16/20 等 8 个散值。
abstract final class AppRadius {
  /// 6 —— 内联元素：标签、徽标、错误横幅。
  static const double sm = 6;

  /// 10 —— 常规容器：卡片、输入框、按钮。
  static const double md = 10;

  /// 14 —— 大容器：海报框、面板、对话框。
  static const double lg = 14;

  /// 胶囊。
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));

  /// 胶囊：标签、徽标一类"两端全圆"的形状。
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// 动效标度。
///
/// 一个作品化的时刻，不是每处都撒一遍入场动画。
/// 缓动是**指数缓出**：从"已经可见"的默认状态出发——入场动画藏起来的内容
/// 会被读成"元素缺失"，然后在截图里被当成缺陷修掉，这是个真实的坑。
///
/// [base] 与 [ease] 用于源场选中环和外壳内容归位；
/// [slow] 与 [fast] 分别用于桌面路由进入与退出。
/// [emphasized] 仅保留给 signature move，不用于常规页面切换。
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);

  /// 指数缓出（近似 `easeOutExpo`）。
  static const Curve ease = Cubic(0.16, 1, 0.3, 1);

  /// 状态切换用的轻微过冲，只给 signature move。
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);
}

// ---------------------------------------------------------------------------
// 中文字重映射
// ---------------------------------------------------------------------------

/// 中文字重映射。
///
/// **关键事实**：微软雅黑只有 Light(300) / Regular(400) / Bold(700) 三个真实字重，
/// **没有真 Medium**。改造前全站 18 处拿 `w600` 当标题字重，4 处用 `w500`——
/// 在雅黑上这些不是真实字重，会走合成加粗（笔画粘连、小字号发糊），
/// 而在 Linux/macOS 上又落到另一支字体、观感不一致。
///
/// 因此标题统一映射到真实存在的 `w700`，正文与标签用 `w400`，
/// 层级差靠**字号与颜色**拉开，而不是靠不存在的中间字重。
abstract final class AppWeight {
  /// 正文。
  static const FontWeight body = FontWeight.w400;

  /// 标签、次要信息（靠颜色降级，不靠字重）。
  static const FontWeight label = FontWeight.w400;

  /// 区块标题、卡片标题。
  static const FontWeight title = FontWeight.w700;

  /// 页面标题、播放器数字。
  static const FontWeight display = FontWeight.w700;
}

// ---------------------------------------------------------------------------
// 配色：星等星表
// ---------------------------------------------------------------------------

/// 星等星表的原始色值。
///
/// 选色策略是 **Committed**：深靛夜空底占满整个表面，星等琥珀是唯一的强调色，
/// 并且只用在真正是"星等"的地方（源场里的基准星、当前剧集、选中态）。
/// 四个状态色**承担真实工作**——站源健康是产品的核心信息，不是装饰。
///
/// 暗色是主身份（用户确认："影院感暗色为主 + 认真设计的亮色"）。
/// 亮色是独立设计的"昼间星表"，不是 `fromSeed` 的副产物。
abstract final class AppPalette {
  // ---- 暗色：夜间，坐在电脑前 ----
  static const Color nightGround = Color(0xFF0B0E1A);
  static const Color nightSurface1 = Color(0xFF141A2E);
  static const Color nightSurface2 = Color(0xFF1B2238);
  static const Color nightSurface3 = Color(0xFF232C46);
  static const Color nightInk = Color(0xFFE8ECF7);
  /// 副文本**从底色色相染色**，不是灰——灰会从整个世界里掉出来。
  static const Color nightInkMuted = Color(0xFFA8B2CC);
  static const Color nightLine = Color(0xFF232C46);

  // ---- 亮色：昼间星表 ----
  static const Color dayGround = Color(0xFFF4F6FB);
  /// 卡片/容器（`surfaceContainerLow`）：纯白，在浅底上"浮起来"。
  static const Color daySurface1 = Color(0xFFFFFFFF);
  static const Color daySurface2 = Color(0xFFEAEEF7);
  static const Color daySurface3 = Color(0xFFDDE3F0);
  /// 外壳（`surfaceContainerLowest`：顶栏与侧栏）。
  ///
  /// 比页面底色**更冷更深**，而不是更白——与暗色主题同一个逻辑：
  /// 外壳比内容**退后**一档。第一版把外壳也做成纯白，于是外壳与卡片撞成
  /// 同一级、层级全靠发丝线撑着（此缺陷由 DESIGN.md 的 documenter 复核发现）。
  static const Color dayChrome = Color(0xFFEDF1F9);
  static const Color dayInk = Color(0xFF101427);
  static const Color dayInkMuted = Color(0xFF4E5A75);
  static const Color dayLine = Color(0xFFD3DAE8);

  // ---- 星等（唯一强调色）----
  /// 星等琥珀。暗色底上用亮琥珀，亮色底上压深以保证对比度。
  static const Color magnitude = Color(0xFFF0B429);
  static const Color magnitudeOnLight = Color(0xFF8A5B00);

  // ---- 语义状态色：站源健康 ----
  /// 可用。
  static const Color statusOk = Color(0xFF3DD68C);
  /// 降级（间歇超时）。
  static const Color statusDegraded = Color(0xFFF5A623);
  /// 失效。
  static const Color statusFailed = Color(0xFFF0526B);
  /// 未知（未测过 / 运行时不支持）。
  static const Color statusUnknown = Color(0xFF6B7A99);

  /// 亮色底上的状态色需要压深才能达到 4.5:1。
  static const Color statusOkOnLight = Color(0xFF12734A);
  static const Color statusDegradedOnLight = Color(0xFF8A5300);
  static const Color statusFailedOnLight = Color(0xFFA3122C);
  static const Color statusUnknownOnLight = Color(0xFF4E5A75);
}

/// 世界专属的语义色角色，挂在 `ThemeExtension` 上供全站取用。
///
/// 为什么不用 `ColorScheme` 硬塞：M3 的 `ColorScheme` 没有"站源健康"这个角色，
/// 而它恰恰是本产品最核心的信息。塞进 `tertiary` 之类会造成语义漂移。
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.magnitude,
    required this.statusOk,
    required this.statusDegraded,
    required this.statusFailed,
    required this.statusUnknown,
    required this.wallpaperVeil,
    required this.wallpaperVeilStrong,
  });

  /// 星等琥珀：基准星、当前剧集、选中态。
  final Color magnitude;

  /// 站源可用。
  final Color statusOk;

  /// 站源降级。
  final Color statusDegraded;

  /// 站源失效。
  final Color statusFailed;

  /// 站源状态未知。
  final Color statusUnknown;

  /// 配置壁纸之上的一层纱。
  ///
  /// 用户确认「配置提供的 `wallpaper` 必须真的生效」，而配置里的壁纸是任意图片，
  /// 深浅不可预知。内容必须始终可读，所以壁纸之上永远有一层由底色染出的纱，
  /// 它的不透明度是设计决定，不是图片的属性。
  final Color wallpaperVeil;

  /// 壁纸之上的强纱：用于承载正文的卡片，保证 4.5:1。
  final Color wallpaperVeilStrong;

  @override
  AppSemanticColors copyWith({
    Color? magnitude,
    Color? statusOk,
    Color? statusDegraded,
    Color? statusFailed,
    Color? statusUnknown,
    Color? wallpaperVeil,
    Color? wallpaperVeilStrong,
  }) {
    return AppSemanticColors(
      magnitude: magnitude ?? this.magnitude,
      statusOk: statusOk ?? this.statusOk,
      statusDegraded: statusDegraded ?? this.statusDegraded,
      statusFailed: statusFailed ?? this.statusFailed,
      statusUnknown: statusUnknown ?? this.statusUnknown,
      wallpaperVeil: wallpaperVeil ?? this.wallpaperVeil,
      wallpaperVeilStrong: wallpaperVeilStrong ?? this.wallpaperVeilStrong,
    );
  }

  @override
  AppSemanticColors lerp(
    covariant ThemeExtension<AppSemanticColors>? other,
    double t,
  ) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      magnitude: Color.lerp(magnitude, other.magnitude, t)!,
      statusOk: Color.lerp(statusOk, other.statusOk, t)!,
      statusDegraded: Color.lerp(statusDegraded, other.statusDegraded, t)!,
      statusFailed: Color.lerp(statusFailed, other.statusFailed, t)!,
      statusUnknown: Color.lerp(statusUnknown, other.statusUnknown, t)!,
      wallpaperVeil: Color.lerp(wallpaperVeil, other.wallpaperVeil, t)!,
      wallpaperVeilStrong:
          Color.lerp(wallpaperVeilStrong, other.wallpaperVeilStrong, t)!,
    );
  }
}

/// 星等星表的语义色角色（默认值，按亮度取）。
///
/// 亮色底上的状态色需要压深版本才能满足对比度，所以这里按亮度分派，
/// 不是简单反转。
AppSemanticColors defaultSemanticColors(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return AppSemanticColors(
    magnitude: dark ? AppPalette.magnitude : AppPalette.magnitudeOnLight,
    statusOk: dark ? AppPalette.statusOk : AppPalette.statusOkOnLight,
    statusDegraded:
        dark ? AppPalette.statusDegraded : AppPalette.statusDegradedOnLight,
    statusFailed:
        dark ? AppPalette.statusFailed : AppPalette.statusFailedOnLight,
    statusUnknown:
        dark ? AppPalette.statusUnknown : AppPalette.statusUnknownOnLight,
    // 配置壁纸之上永远有一层纱：壁纸深浅不可预知，内容必须始终可读。
    // 纱由底色染出，不透明度是设计决定，不是图片的属性。
    wallpaperVeil: dark
        ? AppPalette.nightGround.withValues(alpha: 0.86)
        : AppPalette.dayGround.withValues(alpha: 0.90),
    wallpaperVeilStrong: dark
        ? AppPalette.nightGround.withValues(alpha: 0.94)
        : AppPalette.dayGround.withValues(alpha: 0.96),
  );
}

/// 便捷取用：`context.semanticColors.statusOk`。
extension AppSemanticColorsX on BuildContext {
  /// 世界的语义色角色。
  ///
  /// **扩展缺失时按当前亮度回落到默认值，而不是抛异常。**
  ///
  /// 为什么必须回落：测试大量用裸 `MaterialApp(home: ...)`（不传 `theme:`）
  /// 来 pump 单个页面（例如 `test/phase3_poster_badge_test.dart:177`），
  /// 此时主题扩展根本不存在。一个用 `!` 硬断言的取色器会让所有页面级测试
  /// 直接崩掉——实测就是这么崩的——而它本来只是"取个颜色"。
  AppSemanticColors get semanticColors {
    final theme = Theme.of(this);
    return theme.extension<AppSemanticColors>() ??
        defaultSemanticColors(theme.brightness);
  }
}

// ---------------------------------------------------------------------------
// 数字
// ---------------------------------------------------------------------------

/// 数字用等宽字形。
///
/// 星等星表里数字承担真实工作（星等、集数、时长、站点计数）。比例字形在
/// 逐行对齐时会让数字左右跳动，读一列数据时很累。只在**数字成列**的地方套用，
/// 不给正文全局开启——中文夹数字时等宽字形会显得松散。
const List<FontFeature> kTabularFigures = [FontFeature.tabularFigures()];

/// 给样式加上表格数字。
TextStyle tabular(TextStyle style) =>
    style.copyWith(fontFeatures: kTabularFigures);
