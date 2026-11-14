import 'package:flutter/material.dart';

import 'common.dart';
import 'tokens.dart';

class SettingsPageHeader extends StatelessWidget {
  const SettingsPageHeader({super.key, required this.title, this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.headlineSmall),
          if (description != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              description!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    this.description,
    required this.children,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (description != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          ...children,
        ],
      ),
    );
  }
}

class SettingsActions extends StatelessWidget {
  const SettingsActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: AppSpace.md,
    runSpacing: AppSpace.sm,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: children,
  );
}

/// 一行「进入下一级」的设置入口。
///
/// 为什么需要它：设置页原来只会用「一段说明 + 一个铺满整行的 tonal 按钮」，
/// 一个类别里放三四个入口就成了一列蓝色横条，读起来全是同等权重的按钮，
/// 没有列表的扫描感。桌面设置的常规形态是**行**：图标定位、标题命名、
/// 单行摘要给出当前状态、箭头说明还有下一级。
///
/// key 落在整行上：旧测试按 `find.byKey(ValueKey('settings-…-open'))` 直接 tap，
/// 换成行以后仍然点得到。
class SettingsNavRow extends StatelessWidget {
  const SettingsNavRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleKey,
    required this.onTap,
  });

  final IconData icon;
  final String title;

  /// 一行状态摘要；过长会被截断，详细原因属于下一级页面。
  final String? subtitle;

  /// 摘要上的 key：旧测试用 `tester.widget<Text>(find.byKey(...))` 读它。
  final Key? subtitleKey;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.mdAll,
        child: Padding(
          // 水平不留内边距：同一列表里的 SwitchListTile 用 contentPadding: zero，
          // 行若再缩进 8px，分隔线与悬停面的左右边缘就会和开关错开（锯齿轮廓）。
          padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    if (subtitle != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        subtitle!,
                        key: subtitleKey,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // 与同一列表里的 SwitchListTile 副标题同号（ListTile 的
                        // 副标题是 bodyMedium）：一个列表里两种副标题字号，读起来
                        // 就是「有的行重、有的行轻」的无谓差异。
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 把若干行串成一个列表：行与行之间只有一条发丝线，行本身不带外边距。
///
/// 分隔线由这里统一画，调用点不再各自 `SizedBox(height: 8)`——同一屏里
/// 出现两种行距，是列表读起来「散」的常见原因。
class SettingsRowList extends StatelessWidget {
  const SettingsRowList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const Divider(height: 1),
        children[i],
      ],
    ],
  );
}

/// 表单字段块：小标题 + 控件 + 可选脚注。
///
/// 三级页面里同一个字段的「标题—控件—说明」节奏只在这里定义一次，
/// 避免每个调用点自己挑间距（改造前 8 / 12 / 16 三种混用）。
class SettingsField extends StatelessWidget {
  const SettingsField({
    super.key,
    required this.label,
    required this.child,
    this.hint,
    this.hintKey,
  });

  final String label;
  final Widget child;
  final String? hint;
  final Key? hintKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpace.sm),
          child,
          if (hint != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              hint!,
              key: hintKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 三级明细页的骨架：AppBar（带返回）+ 可选说明 + 限宽单列。
///
/// 为什么单独抽出来：高级设置拆成明细后会有六七个结构相同的新页面，
/// 每个页面自己写 `Scaffold + ListView + formPagePadding` 时，
/// 内边距与说明文字的位置一定会分叉。
class SettingsDetailScaffold extends StatelessWidget {
  const SettingsDetailScaffold({
    super.key,
    required this.title,
    this.description,
    required this.children,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          if (description != null) ...[
            Text(
              description!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpace.xl),
          ],
          ...children,
        ],
      ),
    );
  }
}
