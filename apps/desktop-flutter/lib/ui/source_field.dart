/// 源场：星等星表的 signature move。
///
/// 每一个站源是天上的一颗星，**星等就是它的实测成功率**——点越大越亮，
/// 颜色是健康状态。这不是装饰：它一眼回答"哪个源现在还能用"，
/// 而这正是本产品真正的焦虑（对外只承诺"单个站源能否使用以实测为准"）。
///
/// 数据是**真实测量**的，不是估的：`site_health` 表按动作累计的
/// `*_ok` / `*_total`（`services/storage.dart:1074` 的 `recordHealth`，
/// 由 `services/site_service.dart:77` 在每次站点调用后写入）。
/// 没有采样记录的站点星等为**未知**——不假装它是好的。
library;

import 'package:flutter/material.dart';

import '../services/storage.dart';
import '../state/app_state.dart';
import 'tokens.dart';

/// 站源健康状态。四态都是真实可判定的。
enum SourceStatus {
  /// 有采样且成功率达标。
  ok,

  /// 有采样但成功率偏低（间歇超时一类）。
  degraded,

  /// 有采样但一次都没成功，或运行时不支持——两者都是"确实用不了"。
  failed,

  /// 没有采样记录。**未知不等于好**，因此单独一态，不并入"可用"。
  unknown,
}

/// 成功率低于此值算「降级」。
///
/// 0.8 是个产品判断而非物理常数：单次超时就会把 1/1 打到 0，样本少时抖动大，
/// 所以判级同时看样本量（见 [buildMagnitudes]）。
const double kDegradedBelow = 0.8;

/// 样本量少于这个数时，即使成功率为 0 也只算「降级」不算「失效」。
///
/// 理由：一次失败不足以判定一个源死了。宁可显示"降级"让用户自己试，
/// 也不要把一次网络抖动说成"失效"。
const int kMinSamplesForFailed = 3;

/// 一个站源的星等。
@immutable
class SiteMagnitude {
  const SiteMagnitude({
    required this.siteKey,
    required this.name,
    required this.status,
    required this.rate,
    required this.samples,
    required this.latencyMs,
    this.note,
  });

  final String siteKey;
  final String name;
  final SourceStatus status;

  /// 实测成功率 `0..1`；无采样时为 `null`。
  final double? rate;

  /// 采样总数（四个动作相加）。
  final int samples;

  /// 平均延迟（毫秒）。无采样时为 0。
  final int latencyMs;

  /// 不可用原因：运行时不支持的原因，或最近一次错误。
  final String? note;

  /// 点直径：星等越大点越大。
  ///
  /// 尺度是**刻意放大**的：第一版用 5–14px，实测截图里整片场缩成左上角一条
  /// 50px 的带子，读起来像附注而不是这个产品的 signature move
  /// （正是方向卡上自陈的风险："点阵场一旦画得太小或太稀，就退化成装饰"）。
  /// 现在 7–22px，一片场才有"场"的样子。
  ///
  /// 无采样时给最小的中性尺寸，让"未知"看得见但不抢眼。
  double get diameter => rate == null ? 7.0 : 7.0 + rate! * 15.0;
}

/// 把站点清单与实测健康数据合成星等。
///
/// 纯函数：不碰数据库、不碰 widget，便于单测锁定判级规则。
/// 返回按星等降序排列——源场因此读起来是"从最亮到最暗"的一片场。
List<SiteMagnitude> buildMagnitudes({
  required List<SiteListItem> items,
  required Map<String, SiteHealth> health,
}) {
  final result = <SiteMagnitude>[];
  for (final item in items) {
    final key = item.site.key;
    final record = health[key];
    final samples = record == null
        ? 0
        : record.homeTotal +
              record.categoryTotal +
              record.detailTotal +
              record.playTotal;
    final okCount = record == null
        ? 0
        : record.homeOk + record.categoryOk + record.detailOk + record.playOk;
    final rate = SiteHealth.rate(okCount, samples);

    final SourceStatus status;
    String? note;
    if (!item.availability.available) {
      // 运行时不支持：这是"确实用不了"，与"没测过"是两件事。
      status = SourceStatus.failed;
      note = item.availability.reason ?? '运行时不支持';
    } else if (rate == null) {
      status = SourceStatus.unknown;
      note = '尚无实测记录';
    } else if (rate >= kDegradedBelow) {
      status = SourceStatus.ok;
    } else if (rate > 0 || samples < kMinSamplesForFailed) {
      status = SourceStatus.degraded;
      note = record?.lastError;
    } else {
      status = SourceStatus.failed;
      note = record?.lastError;
    }

    result.add(
      SiteMagnitude(
        siteKey: key,
        name: item.site.name,
        status: status,
        rate: rate,
        samples: samples,
        latencyMs: record?.avgLatencyMs ?? 0,
        note: note,
      ),
    );
  }
  // 亮的在前：源场按星等排序，最可用的一眼就在左上。
  result.sort((a, b) {
    final ra = a.rate ?? -1;
    final rb = b.rate ?? -1;
    final byRate = rb.compareTo(ra);
    if (byRate != 0) return byRate;
    return a.name.compareTo(b.name);
  });
  return result;
}

/// 状态对应的颜色。颜色**只**从 `AppSemanticColors` 取，不写死。
Color sourceStatusColor(BuildContext context, SourceStatus status) {
  final semantic = context.semanticColors;
  switch (status) {
    case SourceStatus.ok:
      return semantic.statusOk;
    case SourceStatus.degraded:
      return semantic.statusDegraded;
    case SourceStatus.failed:
      return semantic.statusFailed;
    case SourceStatus.unknown:
      return semantic.statusUnknown;
  }
}

/// 状态的用户可见名称。
String sourceStatusLabel(SourceStatus status) {
  switch (status) {
    case SourceStatus.ok:
      return '可用';
    case SourceStatus.degraded:
      return '降级';
    case SourceStatus.failed:
      return '失效';
    case SourceStatus.unknown:
      return '未知';
  }
}

/// 源场：一片按星等排布的点，颜色即健康状态。
///
/// 密度是刻意的——画的是**真实的全量站源**，不是三个装饰点。
/// 一百多个点在桌面上一眼扫完，比一列带图标的列表快得多。
class SourceField extends StatelessWidget {
  const SourceField({
    super.key,
    required this.magnitudes,
    this.selectedKey,
    this.onSelect,
    this.maxDotRows = 3,
  });

  final List<SiteMagnitude> magnitudes;

  /// 当前选中站点的 key（画成基准星：琥珀色环）。
  final String? selectedKey;

  final ValueChanged<String>? onSelect;

  /// 点阵最多显示几行，超出部分用一行汇总说明。
  ///
  /// 为什么要封顶：站源数量取决于用户配置（实测有 163 个），
  /// 不封顶会让首页第一屏被源场吃掉。3 行是"有存在感但不喧宾夺主"的取值。
  final int maxDotRows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final counts = <SourceStatus, int>{
      for (final status in SourceStatus.values) status: 0,
    };
    for (final item in magnitudes) {
      counts[item.status] = counts[item.status]! + 1;
    }

    // 一片"场"需要一个自己的面：第一版把点直接画在页面底色上，
    // 读不出这是一块区域，只是几粒散点。
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.lgAll,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.72),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '站源健康',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                '${magnitudes.length} 个',
                style: tabular(
                  theme.textTheme.bodySmall!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          // 图例即计数：一行读完"多少源现在能用"。
          Wrap(
            spacing: AppSpace.lg,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final status in SourceStatus.values)
                _LegendCount(status: status, count: counts[status]!),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          _DotField(
            magnitudes: magnitudes,
            selectedKey: selectedKey,
            onSelect: onSelect,
            maxDotRows: maxDotRows,
          ),
          if (magnitudes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Text(
                '当前配置没有可用站点',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LegendCount extends StatelessWidget {
  const _LegendCount({required this.status, required this.count});

  final SourceStatus status;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = sourceStatusColor(context, status);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          sourceStatusLabel(status),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          '$count',
          style: tabular(
            theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: AppWeight.title,
            ),
          ),
        ),
      ],
    );
  }
}

class _DotField extends StatelessWidget {
  const _DotField({
    required this.magnitudes,
    required this.selectedKey,
    required this.onSelect,
    required this.maxDotRows,
  });

  final List<SiteMagnitude> magnitudes;
  final String? selectedKey;
  final ValueChanged<String>? onSelect;
  final int maxDotRows;

  @override
  Widget build(BuildContext context) {
    if (magnitudes.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 每个点占的横向槽位 = 最大点径 + 间隙。按可用宽度估算一行能放几个，
        // 从而决定截断数量——避免 Wrap 撑出不可控的高度。
        const slot = 34.0;
        final perRow = (constraints.maxWidth / slot).floor().clamp(1, 400);
        final capacity = perRow * maxDotRows;
        final visible = magnitudes.length <= capacity
            ? magnitudes
            : magnitudes.sublist(0, capacity);
        final hidden = magnitudes.length - visible.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final item in visible)
                  _Star(
                    item: item,
                    selected: item.siteKey == selectedKey,
                    onSelect: onSelect,
                  ),
              ],
            ),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Text(
                  '另有 $hidden 个较暗的源未在此展开',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Star extends StatelessWidget {
  const _Star({
    required this.item,
    required this.selected,
    required this.onSelect,
  });

  final SiteMagnitude item;
  final bool selected;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    final semantic = context.semanticColors;
    final color = sourceStatusColor(context, item.status);
    final size = item.diameter;
    final rate = item.rate;

    final tooltip = StringBuffer('${item.name} · ${sourceStatusLabel(item.status)}');
    if (rate != null) {
      tooltip.write(' · 成功率 ${(rate * 100).round()}%（${item.samples} 次）');
      if (item.latencyMs > 0) tooltip.write(' · 平均 ${item.latencyMs}ms');
    } else {
      tooltip.write(' · 尚无实测记录');
    }
    if (item.note != null && item.note!.isNotEmpty) {
      tooltip.write('\n${item.note}');
    }

    return Tooltip(
      message: tooltip.toString(),
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onSelect == null ? null : () => onSelect!(item.siteKey),
          child: SizedBox(
            width: 26,
            height: 26,
            child: Center(
              // 用 `AnimatedContainer` 而不是 `Container`：换源时选中环的出现/
              // 消失、以及星等变化时点径的伸缩，都需要一个可读的过渡。
              //
              // 这是本设计系统**唯一**一处动效，也是有意义的一处——
              // 它回答的是"你现在在哪个源上"，不是装饰。
              // 一次性过渡（非循环），所以 `pumpAndSettle` 能正常结束。
              child: AnimatedContainer(
                duration: AppMotion.base,
                curve: AppMotion.ease,
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  // 基准星：一圈琥珀环，说明"你现在看的是这个源"。
                  border: selected
                      ? Border.all(color: semantic.magnitude, width: 1.5)
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
