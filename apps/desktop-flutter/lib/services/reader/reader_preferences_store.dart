import 'dart:convert';
import 'dart:io';

import '../../core/reader/reader_models.dart';

class ReaderPreferencesStore {
  ReaderPreferencesStore(this.path);
  final String path;
  ReaderPreferences load() {
    final file = File(path);
    if (!file.existsSync()) return ReaderPreferences();
    try {
      return ReaderPreferences.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
    } on Object {
      return ReaderPreferences();
    }
  }

  void save(ReaderPreferences preferences) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    Map<String, dynamic> json = {};
    if (file.existsSync()) {
      try {
        json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } on Object {
        /* 恢复损坏的任务专属配置。 */
      }
    }
    json.addAll(preferences.toJson());
    final temporary = File('$path.reader.$pid.tmp');
    temporary.writeAsStringSync(jsonEncode(json), flush: true);
    temporary.renameSync(path);
  }
}
