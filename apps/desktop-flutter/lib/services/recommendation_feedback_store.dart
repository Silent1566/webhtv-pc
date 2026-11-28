import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/detail_recommendation.dart';

class BlockedRecommendation {
  const BlockedRecommendation(this.key, this.title, this.createdAt);

  final String key, title;
  final DateTime createdAt;
}

class RecommendationFeedbackStore extends ChangeNotifier {
  RecommendationFeedbackStore({this.file, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    try {
      final value = jsonDecode(file?.readAsStringSync() ?? '{}');
      if (value is Map) {
        final labels = value[_labelsKey];
        for (final entry in value.entries) {
          final raw = entry.value;
          if (raw is! String || entry.key == _labelsKey) continue;
          final date = DateTime.tryParse(raw);
          if (date == null) continue;
          final key = entry.key.toString();
          final label = labels is Map ? labels[key] : null;
          _blocked[key] = BlockedRecommendation(
            key,
            label is String && label.isNotEmpty ? label : key,
            date,
          );
        }
      }
    } catch (_) {}
  }

  // Old readers ignore this non-date entry; normalized title keys cannot contain '_'.
  static const _labelsKey = '_titles';
  final File? file;
  final DateTime Function() _clock;
  Map<String, BlockedRecommendation> _blocked = {};
  Object? persistenceError;

  List<BlockedRecommendation> get entries =>
      List.unmodifiable(_activeEntries().values);

  Set<String> get blockedTitles => Set.unmodifiable(_activeEntries().keys);

  Map<String, BlockedRecommendation> _activeEntries() {
    final cutoff = _clock().subtract(const Duration(days: 90));
    return {
      for (final item in _blocked.values)
        if (item.createdAt.isAfter(cutoff)) item.key: item,
    };
  }

  void block(String title) {
    final key = recommendationTitleKey(title);
    if (key.isEmpty) return;
    _save({
      ..._activeEntries(),
      key: BlockedRecommendation(key, title.trim(), _clock()),
    });
  }

  bool removeKeys(Set<String> keys) {
    if (!keys.any(_blocked.containsKey)) return true;
    return _save(_activeEntries()..removeWhere((key, _) => keys.contains(key)));
  }

  bool clear() => _blocked.isEmpty || _save({});

  bool _save(Map<String, BlockedRecommendation> next) {
    final target = file;
    if (target != null) {
      final temp = File('${target.path}.tmp');
      try {
        target.parent.createSync(recursive: true);
        final labels = {
          for (final item in next.values)
            if (item.key != item.title) item.key: item.title,
        };
        temp.writeAsStringSync(
          jsonEncode({
            for (final item in next.values)
              item.key: item.createdAt.toIso8601String(),
            if (labels.isNotEmpty) _labelsKey: labels,
          }),
          flush: true,
        );
        temp.renameSync(target.path);
      } on FileSystemException catch (error) {
        persistenceError = error;
        try {
          if (temp.existsSync()) temp.deleteSync();
        } on FileSystemException {
          // Keep the committed record even if temporary cleanup fails.
        }
        return false;
      }
    }
    _blocked = next;
    persistenceError = null;
    notifyListeners();
    return true;
  }
}
