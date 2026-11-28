import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';

void main() {
  test('clear removes expired legacy records from disk', () {
    final dir = Directory.systemTemp.createTempSync('feedback_clear_old');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/feedback.json')
      ..writeAsStringSync('{"old":"2025-01-01T00:00:00.000Z"}');
    final store = RecommendationFeedbackStore(
      file: file,
      clock: () => DateTime.utc(2026, 1, 1),
    );
    addTearDown(store.dispose);
    expect(store.entries, isEmpty);
    expect(store.clear(), isTrue);
    expect(jsonDecode(file.readAsStringSync()), isEmpty);
  });

  test('feedback persists normalized titles and expires after 90 days', () {
    final dir = Directory.systemTemp.createTempSync('task3-feedback');
    addTearDown(() => dir.deleteSync(recursive: true));
    var now = DateTime.utc(2026, 1, 1);
    final file = File('${dir.path}/feedback.json');
    final store = RecommendationFeedbackStore(file: file, clock: () => now);
    store.block(' 星 空 ');
    expect(
      RecommendationFeedbackStore(file: file, clock: () => now).blockedTitles,
      contains(recommendationTitleKey(' 星 空 ')),
    );
    now = now.add(const Duration(days: 90));
    expect(store.blockedTitles, isEmpty);
  });
  test('corrupt persistence is nonfatal', () {
    final dir = Directory.systemTemp.createTempSync('task3-feedback');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/feedback.json')
      ..writeAsStringSync('invalid');
    expect(RecommendationFeedbackStore(file: file).blockedTitles, isEmpty);
  });

  test('blocking a new title explicitly prunes expired persisted feedback', () {
    final dir = Directory.systemTemp.createTempSync('task3-feedback-prune');
    addTearDown(() => dir.deleteSync(recursive: true));
    var now = DateTime.utc(2026, 1, 1);
    final file = File('${dir.path}/feedback.json');
    final store = RecommendationFeedbackStore(file: file, clock: () => now);
    store.block('Expired');
    now = now.add(const Duration(days: 90));
    expect(store.blockedTitles, isEmpty);
    store.block('Fresh');
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(
      saved.entries
          .where((entry) => entry.value is String)
          .map((entry) => entry.key),
      [recommendationTitleKey('Fresh')],
    );
    expect(
      RecommendationFeedbackStore(file: file, clock: () => now).blockedTitles,
      {recommendationTitleKey('Fresh')},
    );
  });
}
