/// 共享的区块级组件。
///
/// 为什么需要这一层：改造前的盘点发现**同一个视觉模式被反复重写**——
/// 区块标题有两份几乎一样的私有实现（`tmdb_detail_view.dart` 的
/// `_SectionHeader` 与 `spider_page.dart` 的 `_SectionTitle`）外加约 20 处
/// 内联裸 `Text`；loading 有 23 处、4 种不同风格（strokeWidth 默认/2/2.4，
/// minHeight 2/3）；空态 3 个 widget + 10 处内联；错误态 3 个 widget + 8 处内联。
///
/// 这里先把**区块标题**与**加载态**收敛成一份，其余按同一模式继续收敛。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 区块标题。
///
/// 与原 `_SectionHeader` 的行为差异只有两点，都是修正而非改版：
///
/// 1. **留白节奏**：原实现只有 `bottom: 8`、**上方为零**，于是区块之间没有
///    分隔感，整页读起来是平的。这里改成上方 [AppSpace.xl]、下方 10——
///    "标题上方的留白大于下方"是层级最省力的来源。
/// 2. **字重**：原实现用 `w600`，而微软雅黑没有真 Medium，会走合成加粗
///    （笔画粘连、小字号发糊）。这里直接用主题的 `titleMedium`，它已经是
///    真实存在的 `w700`。
///
/// [keyValue] 仍然落在同一个 `Padding` 上：现有测试用
/// `find.byKey(ValueKey('tmdb-section-…'))` 定位它，key 所在的 widget 不能换。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.keyValue,
    this.trailing,
  });

  final String title;

  /// 测试定位用的 key（例如 `tmdb-section-photos`）。
  final String? keyValue;

  /// 标题右侧的操作位（例如"正序/列表"切换）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final value = keyValue;
    return Padding(
      key: value == null ? null : ValueKey(value),
      padding: const EdgeInsets.only(top: AppSpace.xl, bottom: 10),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 加载态：一处定义，全站同一个圈。
///
/// 收敛前有 **4 种风格**（`strokeWidth` 默认 / 2 / 2.4，`minHeight` 2 / 3）
/// 散在约 18 处，没有一个是刻意的——它们只是不同时间写的。
///
/// **默认值刻意是"布局中性"的**：[padding] 为 0、[size] 为 36（Material 的
/// `CircularProgressIndicator` 默认直径）。这样把
/// `Center(child: CircularProgressIndicator())` 换成 `LoadingBlock()` 不会移动
/// 任何盒子，只统一描边宽度。需要呼吸区的地方显式传 [padding]。
///
/// [center] 为 false 时不套 `Center`：内联在 `Row`/`SizedBox` 里的加载态
/// 需要这个形态——在 `Row` 里塞一个 `Center` 会改变布局。
class LoadingBlock extends StatelessWidget {
  const LoadingBlock({
    super.key,
    this.padding = EdgeInsets.zero,
    this.size = 36,
    this.center = true,
  });

  final EdgeInsetsGeometry padding;
  final double size;
  final bool center;

  /// 描边宽度**随直径缩放**，不是一个固定值。
  ///
  /// 为什么：16–18px 的按钮内加载态用 2.4 会显得过粗（就像图标描边不随字号
  /// 缩放就会失衡）。所以这里统一的是**规则**而不是数值——收敛前那 4 种风格
  /// （默认 / 2 / 2.4）的问题正是"没有规则，只是不同时间写的"。
  double get _strokeWidth => size <= 20 ? 2.0 : 2.4;

  @override
  Widget build(BuildContext context) {
    final indicator = Padding(
      padding: padding,
      child: SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(strokeWidth: _strokeWidth),
      ),
    );
    return center ? Center(child: indicator) : indicator;
  }
}

/// 空态：一处定义，全站同一个"这里什么都没有"的样子。
///
/// 收敛前有三种具名实现（`browse_pages.dart` 的 `_EmptyHint`、
/// `live_page.dart` 的 `_LiveEmptyState`、`browse_pages.dart` 的
/// `_UnsupportedSiteHint`）**外加约 10 处内联裸 `Center(child: Text(...))`**——
/// 有的带图标和结构，有的只有一行字，用户看到的是"每页各不相同"。
///
/// 顺带修掉一个 craft-floor 违规：原 `_EmptyHint` 的图标用
/// `Theme.of(context).disabledColor`，那是框架的灰，不属于本设计系统。
/// 这里改成从底色色相染出的 `onSurfaceVariant`。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final String? message;
  final IconData icon;

  /// 空态下的唯一出路（例如「历史页当前来源为空，但别的源有记录」时
  /// 直接给一个切到全部来源的按钮）。默认没有——多数空态确实无事可做。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = message;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (note != null) ...[
              const SizedBox(height: AppSpace.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  note,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpace.sm),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 标签（chip）：一处定义，全站同一个形状。
///
/// 收敛前有**三套几乎一样的私有实现**（`browse_pages.dart` 的 `_FilterChip`、
/// `app.dart` 的 `_GroupChip`、`tmdb_detail_view.dart` 的 `_Chip`），
/// 圆角都是写死的 14，但内边距是 11/5、12/6、10/4 三种，底色三种，
/// 文字色两种——用户看得出来的那种"每处都差一点"。
///
/// 另外两处是真实缺陷，顺带修掉：
/// - `_FilterChip` / `_GroupChip` 用 `w600` 当选中字重，而微软雅黑没有真 Medium
///   → 合成加粗、笔画粘连；这里改用主题的 `title`（真实 `w700`）。
/// - 它们硬编码 `fontSize: 13` / `height: 1.2`，绕过了字体阶梯；这里回到 `bodySmall`。
///
/// [keyValue] 仍然落在**装饰容器**上（与原 `_Chip` 一致），因为详情页的测试
/// 用 `find.byKey(ValueKey('tmdb-detail-year'))` 定位它；[super.key] 供
/// 站点分组那类调用点使用。
/// 表单页的**内容列最大宽度**。
///
/// 为什么需要：桌面窗口 1440px 起，`ListTile` / `SwitchListTile` 会把控件钉在
/// 最右边，于是**标签与它的开关相距约 1300px**——关联断了，眼睛要横跨整屏才能
/// 把"启用 TMDB 增强"和那个开关对上（截图复核时发现，2026-10-11）。
/// 桌面应用的标准做法是给表单一个**可读的内容列**，而不是让输入框铺满窗口。
///
/// 为什么是 900：中文正文在 900px 列宽下每行约 40–50 字，是舒适区间；
/// 再宽就开始丢行（读者找不到下一行的开头）。
const double kFormMaxWidth = 900;

/// 表单页的水平内边距：把内容收进 [kFormMaxWidth] 的**居中列**。
///
/// 为什么用内边距而不是给整棵子树套一层 `ConstrainedBox`：调用点只要换掉一个
/// `EdgeInsets` 就行，不必动括号结构——"包一层"的改动最容易把括号配错，
/// 而效果完全一样（内容居中、限宽），`AppBar` 也仍然铺满整窗。
///
/// 只给**表单页**用（设置 / 配置 / TMDB 设置）。内容网格、播放器、海报墙
/// 这类"越宽越好"的表面**不要**用——那会把画面缩成中间一条。
EdgeInsets formPagePadding(BuildContext context, {double base = 16}) {
  final width = MediaQuery.sizeOf(context).width;
  final extra = width > kFormMaxWidth ? (width - kFormMaxWidth) / 2 : 0.0;
  return EdgeInsets.symmetric(horizontal: base + extra, vertical: base);
}

/// **区块级**空态：一行说明 + 小图标，左对齐，**不居中、不占满**。
///
/// 与 [EmptyState] 的分工：
/// - [EmptyState] 用于"整页什么都没有"（居中、大图标、可带说明段）；
/// - [SectionEmpty] 用于"这一块暂时是空的，但页面上还有别的内容"——
///   在 `ListView` 里塞一个居中大空态会把页面撑得很怪。
///
/// 为什么需要它：Spider 页的两处区块空态原本是**裸 `Text`**，而全站其他空态
/// 都带图标——同一页里两种空态写法并存（截图复核时发现，2026-10-11）。
///
/// [title] 必须保持**单个 `Text`**：`phase2_spider_page_test.dart:166` 用
/// `find.text('本次会话还没有站点启动过 Spider 运行时。')` 精确匹配它。
class SectionEmpty extends StatelessWidget {
  const SectionEmpty({
    super.key,
    required this.title,
    this.icon = Icons.inbox_outlined,
  });

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // 与首行文字视觉对齐（图标比行高矮一点，靠上留一点余量）。
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              icon,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.keyValue,
    this.icon,
    this.selected = false,
    this.emphasized = false,
    this.onTap,
    this.selectable = false,
  });

  final String label;
  final String? keyValue;
  final IconData? icon;

  /// 选中态（只在 [selectable] 时有意义）。
  final bool selected;

  /// 强调态（静态标签用：底色换成 `primaryContainer`）。
  final bool emphasized;

  /// 为 null 时不可点。
  final VoidCallback? onTap;

  /// 这是不是一个**可选择的控件**（筛选 chip、站点分组 chip）。
  ///
  /// 为什么必须与 [onTap] 分开：`onTap == null` 有**两种完全不同的含义**——
  /// ① 静态标签（详情页的年份/时长胶囊，从来不可点）；
  /// ② 可选控件但**当前禁用**（筛选请求在途时）。
  ///
  /// 初版把两者当成一回事，于是筛选条在 `enabled == false` 时整排 chip 掉进
  /// 静态分支：**选中态被抹掉**，一排 chip 长得一模一样，`InkWell` 也没了。
  /// 用户看到的就是「筛选按钮貌似全是选中状态，点击也没反应」
  /// （用户反馈 2026-10-11）。**禁用应该降低强调，而不是抹掉状态。**
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final value = keyValue;
    final disabled = selectable && onTap == null;

    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: selectable
            ? (selected ? scheme.primary : scheme.onSurfaceVariant)
            : scheme.onSurface,
        fontWeight: selected ? AppWeight.title : AppWeight.body,
      ),
    );

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: scheme.primary),
            const SizedBox(width: AppSpace.xs),
          ],
          text,
        ],
      ),
    );

    // ---- 可选控件：选中态**永远**渲染，禁用时只降强调 ----
    if (selectable) {
      return Padding(
        padding: const EdgeInsets.only(right: AppSpace.xs),
        child: Opacity(
          // 禁用态用整体降透明度表达：用户一眼能看出「现在点不动」，
          // 而不是面对一排看不出差别的 chip 反复点击。
          opacity: disabled ? 0.5 : 1,
          child: Material(
            key: value == null ? null : ValueKey(value),
            // 未选中用**透明**而不是填充色：筛选条上有十几个维度、上百个 chip，
            // 全部填色会变成一片色块，选中项反而淹没在里面
            // （这也是原 `_FilterChip` 的做法）。
            color: selected
                ? scheme.primary.withValues(alpha: dark ? 0.22 : 0.12)
                : Colors.transparent,
            borderRadius: AppRadius.pillAll,
            child: InkWell(
              onTap: onTap,
              borderRadius: AppRadius.pillAll,
              hoverColor: scheme.primary.withValues(alpha: dark ? 0.10 : 0.06),
              child: content,
            ),
          ),
        ),
      );
    }

    // ---- 静态标签：不可点，用填充底把它和可选控件区分开 ----
    return Container(
      key: value == null ? null : ValueKey(value),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: emphasized
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: AppRadius.pillAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: scheme.primary),
            const SizedBox(width: AppSpace.xs),
          ],
          text,
        ],
      ),
    );
  }
}

/// 数值滑块对话框（对齐上游安卓「默影视」`SliderNumberDialog`）。
///
/// 为什么抽到共享层：搜索页的「相似度」与设置页的「搜索线程」是同一个交互形态
/// （0~100 这类有界整数、步进 1、大号数值 + 一行说明 + 无刻度滑块），
/// 上游也是同一个 `SliderNumberDialog` 服务两处。两份实现必然分叉。
///
/// [keyPrefix] 决定内部控件的 widget key（`<prefix>-value` / `-slider` / `-confirm`），
/// 让 widget 测试能精确定位某一次调用的控件而不是靠文案猜。
///
/// 返回用户确认的整数；取消时返回 null（调用方据此不做任何写入）。
Future<int?> showNumberSliderDialog(
  BuildContext context, {
  required String title,
  required int current,
  required int minValue,
  required int maxValue,
  String suffix = '',
  String? hint,
  String keyPrefix = 'number-slider',
}) {
  if (maxValue < minValue) return Future.value(null);
  final divisions = maxValue - minValue;
  var value = current.clamp(minValue, maxValue).toDouble();
  return showDialog<int>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${value.round()}$suffix',
                key: ValueKey('$keyPrefix-value'),
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: AppSpace.sm),
              if (hint != null) ...[
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpace.sm),
              ],
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  // 上游显式关掉了刻度线（`setTickVisible(false)`）；
                  // 100 分割的刻度线在视觉上就是一条灰带。
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                ),
                child: Slider(
                  key: ValueKey('$keyPrefix-slider'),
                  value: value,
                  min: minValue.toDouble(),
                  max: maxValue.toDouble(),
                  divisions: divisions > 0 ? divisions : null,
                  label: '${value.round()}$suffix',
                  onChanged: (next) => setLocal(() => value = next),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: ValueKey('$keyPrefix-confirm'),
            onPressed: () => Navigator.of(context).pop(value.round()),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}
