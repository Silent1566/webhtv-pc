import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';

import 'settings_immediate_forms_test.dart' show isolatedState;

void main() {
  testWidgets(
    'per-character automatic credential saves never log changing secret fragments',
    (tester) async {
      final state = await isolatedState(tester);
      const aiKey = 'R7vX8qJ2mN6c';
      const tmdbKey = 'F5hK9wB3sD8u';
      const token = 'Z6pY4tG9nV2e';
      await tester.runAsync(() async {
        for (var length = 1; length <= aiKey.length; length++) {
          await state.saveAiConfig(
            AiConfig.fromJson({
              ...state.aiConfig.toJson(),
              'apiKey': aiKey.substring(0, length),
            }),
          );
        }
        for (var length = 1; length <= tmdbKey.length; length++) {
          await state.saveTmdbConfig(
            state.tmdbUserConfig.copyWith(apiKey: tmdbKey.substring(0, length)),
          );
        }
        for (var length = 1; length <= token.length; length++) {
          await state.saveTmdbConfig(
            state.tmdbUserConfig.copyWith(
              accessToken: token.substring(0, length),
            ),
          );
        }
      });
      final logs = state.log.entries.map((entry) => entry.line).join('\n');
      expect(logs, contains('AI 设置已更新'));
      expect(logs, contains('TMDB 设置已更新'));
      for (final secret in [aiKey, tmdbKey, token]) {
        for (var start = 0; start <= secret.length - 4; start++) {
          expect(
            logs,
            isNot(contains(secret.substring(start, start + 4))),
            reason: 'Success logs must not reveal credential fragments across automatic saves',
          );
        }
      }
      expect(state.aiConfig.apiKey, aiKey);
      expect(state.tmdbUserConfig.apiKey, tmdbKey);
      expect(state.tmdbUserConfig.accessToken, token);
    },
  );
}
