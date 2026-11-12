import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/detail_ratings.dart';
import '../services/external_url.dart';
import 'common.dart';
import 'toast.dart';
import 'tokens.dart';

/// Static scores: one star per label, no placeholder or navigation affordance.
class DetailRatingTags extends StatelessWidget {
  const DetailRatingTags({
    super.key,
    this.ratings = const DetailRatings(),
    this.tmdbRating = 0,
  });

  final DetailRatings ratings;
  final double tmdbRating;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (tmdbRating.isFinite && tmdbRating > 0 && tmdbRating <= 10)
        TagChip(
          keyValue: 'tmdb-detail-rating',
          label: '${RatingBrand.tmdb} ${tmdbRating.toStringAsFixed(1)}',
          icon: Icons.star,
          emphasized: true,
        ),
      for (final entry in ratings.entries)
        if (entry.source != RatingSource.tmdb && _validScore(entry))
          Tooltip(
            message: entry.detail.isEmpty
                ? '${entry.source.label} ${entry.valueLabel}'
                : '${entry.source.label} ${entry.valueLabel} · ${entry.detail}',
            child: TagChip(
              keyValue: 'detail-rating-tag-${entry.source.key}',
              label: '${entry.source.label} ${entry.valueLabel}',
              icon: Icons.star,
              emphasized: true,
            ),
          ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      key: const ValueKey('detail-rating-tags'),
      spacing: AppSpace.sm,
      runSpacing: AppSpace.xs,
      children: chips,
    );
  }

  bool _validScore(DetailRatingEntry entry) {
    final text = entry.valueLabel.trim();
    final match = RegExp(r'^(\d+(?:\.\d+)?)(?:%|/10|/100)?$').firstMatch(text);
    if (match == null) return false;
    final value = double.tryParse(match.group(1)!);
    final max =
        entry.source == RatingSource.rottenTomatoes ||
            entry.source == RatingSource.metacritic
        ? 100
        : 10;
    return value != null && value.isFinite && value > 0 && value <= max;
  }
}

/// Footer navigation only; supplied ratings share the page's existing query.
class DetailRatingsSection extends StatelessWidget {
  const DetailRatingsSection({
    super.key,
    required this.request,
    this.ratings,
    this.onOpen,
    this.onCopy,
    this.keyPrefix = 'detail-ratings',
  });
  final DetailRatingRequest request;

  /// 页面已经查好的评分（与评分标签共用同一轮查询）。为空时只按
  /// [request] 拼静态外链——外链不需要网络。
  final DetailRatings? ratings;
  final Future<bool> Function(String url)? onOpen;
  final Future<void> Function(String url)? onCopy;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    // 页面还没开始查询（或没有评分服务）时，退化成「只按 request 拼静态外链」：
    // 外链不依赖网络，没理由跟着评分的加载状态一起缺席。
    final value = ratings;
    return _links(
      context,
      value == null || value.entries.isEmpty
          ? DetailRatingRules.build(request: request)
          : value,
    );
  }

  Widget _links(BuildContext context, DetailRatings values) {
    final links = values.entries.where((entry) => entry.canOpen).toList();
    if (links.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 不发丝线（2026-11-12 用户反馈）：它把推荐行与外部链接切成两段。
        // 间隔由 `SectionHeader` 的上 24 / 下 10 承担，与其它区块同一套节奏。
        SectionHeader(title: '外部链接', keyValue: '$keyPrefix-section'),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            for (final entry in links)
              OutlinedButton.icon(
                key: ValueKey('$keyPrefix-${entry.source.key}'),
                onPressed: () => unawaited(_open(context, entry.url)),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(entry.source.label),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    var opened = false;
    try {
      opened = await onOpen?.call(url) ?? (await ExternalUrl.open(url)).ok;
    } catch (_) {}
    if (opened) return;
    var copied = false;
    try {
      if (onCopy != null) {
        await onCopy!(url);
      } else {
        await Clipboard.setData(ClipboardData(text: url));
      }
      copied = true;
    } catch (_) {}
    if (!context.mounted) return;
    showToast(copied ? '无法打开浏览器，已复制链接' : '无法打开浏览器或复制链接', kind: ToastKind.error);
  }
}
