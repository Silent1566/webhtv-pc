import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/watched_recommendation.dart';

class RecommendationWatchStore extends ChangeNotifier {
  RecommendationWatchStore({this.file}) {
    try {
      final raw = jsonDecode(file?.readAsStringSync() ?? '[]');
      if (raw is List) {
        _works = List.unmodifiable(
          raw.map(RecommendationWork.fromJson).nonNulls,
        );
      }
    } catch (_) {}
  }

  final File? file;
  List<RecommendationWork> _works = const [];

  /// Newest first. Marks are not playback history and do not expire.
  List<RecommendationWork> get works => _works;

  bool contains(RecommendationWork work) => _works.any(work.matches);

  bool setWatched(RecommendationWork work, bool watched) {
    if (work.titleKey.isEmpty) return false;
    final index = _works.indexWhere(work.matches);
    if ((index >= 0) == watched) return true;
    final next = [..._works];
    if (watched) {
      next.insert(0, work);
    } else {
      next.removeAt(index);
    }
    return _save(next);
  }

  bool removeWhere(bool Function(RecommendationWork) matches) {
    final next = _works.where((work) => !matches(work)).toList();
    return next.length == _works.length || _save(next);
  }

  bool clear() => _works.isEmpty || _save(const []);

  bool _save(List<RecommendationWork> next) {
    final target = file;
    if (target != null) {
      final pending = File('${target.path}.tmp');
      try {
        target.parent.createSync(recursive: true);
        pending.writeAsStringSync(jsonEncode(next), flush: true);
        pending.renameSync(target.path);
      } on FileSystemException {
        try {
          if (pending.existsSync()) pending.deleteSync();
        } on FileSystemException {
          // Keep the previous saved marks even if temporary cleanup fails.
        }
        return false;
      }
    }
    _works = List.unmodifiable(next);
    notifyListeners();
    return true;
  }
}
