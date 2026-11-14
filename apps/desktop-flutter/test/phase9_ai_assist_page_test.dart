import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/services/ai_assist_service.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_assist_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late AppState state;

  setUp(() {
    state = AppState(
      paths: AppPaths.resolve(overrides: {
          'config': '${'x'}/webhtv-pc',
          'data': '${'x'}/webhtv-pc',
          'cache': '${'x'}/webhtv-pc/cache',
          'state': '${'x'}/webhtv-pc/logs',
        }),
      log: LogService(),
    );
  });

  tearDown(() => state.dispose());

  Future<void> pumpPage(WidgetTester tester, AiAssistService service) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: AiAssistPage(state: state, service: service),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  }

  testWidgets('未配置 AI 时提示且运行按钮禁用', (tester) async {
    await pumpPage(
      tester,
      AiAssistService(config: const AiConfig(), client: AiCompletionClient()),
    );
    expect(find.byKey(const ValueKey('ai-assist-not-ready')), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('ai-assist-run')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('已配置时运行并展示标题清洗结果', (tester) async {
    final service = AiAssistService(
      config: const AiConfig(
        enabled: true,
        protocol: AiProtocol.openAiChat,
        endpoint: 'https://example.test/v1/chat/completions',
        apiKey: 'k',
        model: 'm',
      ),
      client: _FakeClient('{"title":"某剧","year":2024}'),
    );
    await pumpPage(tester, service);
    expect(find.byKey(const ValueKey('ai-assist-not-ready')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('ai-assist-input')),
      '[4K] 某剧 第二季',
    );
    await tester.tap(find.byKey(const ValueKey('ai-assist-run')));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('ai-assist-result')), findsOneWidget);
    expect(find.textContaining('某剧'), findsWidgets);
  });
}

class _FakeClient extends AiCompletionClient {
  _FakeClient(this.payload);

  final String payload;

  @override
  Future<AiCompletionResult> complete({
    required AiConfig config,
    required String prompt,
    Duration? timeout,
    String task = 'ai',
    AiCancellationToken? cancellationToken,
  }) async => AiCompletionResult(
    ok: true,
    statusCode: 200,
    text: payload,
    message: '',
  );
}
