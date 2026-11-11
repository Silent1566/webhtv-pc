import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/detail_recommendation.dart';

class RecommendationFeedbackStore extends ChangeNotifier {
  RecommendationFeedbackStore({this.file, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    try {
      final value = jsonDecode(file?.readAsStringSync() ?? '{}');
      if (value is Map) {
        for (final entry in value.entries) {
          final date = DateTime.tryParse(entry.value.toString());
          if (date != null) _blocked[entry.key.toString()] = date;
        }
      }
    } catch (_) {}
    _pruneExpired();
  }
  final File? file;
  final DateTime Function() _clock;
  final Map<String, DateTime> _blocked = {};
  Object? persistenceError;
  Set<String> get blockedTitles {
    final cutoff = _clock().subtract(const Duration(days: 90));
    return Set.unmodifiable(
      _blocked.entries
          .where((entry) => entry.value.isAfter(cutoff))
          .map((entry) => entry.key),
    );
  }

  void _pruneExpired() {
    final cutoff = _clock().subtract(const Duration(days: 90));
    _blocked.removeWhere((_, time) => !time.isAfter(cutoff));
  }

  void block(String title) {
    final key = recommendationTitleKey(title);
    if (key.isEmpty) return;
    _pruneExpired();
    _blocked[key] = _clock();
    notifyListeners();
    try {
      file?.parent.createSync(recursive: true);
      file?.writeAsStringSync(
        jsonEncode(
          _blocked.map((key, time) => MapEntry(key, time.toIso8601String())),
        ),
      );
      persistenceError = null;
    } catch (error) {
      persistenceError = error;
    }
  }
}
