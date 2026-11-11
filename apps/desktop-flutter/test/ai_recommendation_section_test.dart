import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/ai_content/recommendation.dart';
import 'package:webhtv_pc/core/ai_content/recommendation_feedback.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_completion.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_content/ai_recommendation_section.dart';
import 'package:webhtv_pc/ui/app.dart';

const _payload =
    '{"items":[{"title":"缓存里的片","mediaType":"movie","year":2020},'
    '{"title":"新片A","mediaType":"tv","year":2021},'
    '{"title":"新片B","mediaType":"movie","year":2022}]}';

/// 统计调用次数并可按需失败的假补全器。
class _FakeCompletion {
  _FakeCompletion();
  bool fail = false;
  int calls = 0;

  AiContentCompletion build() => AiContentCompletion(
    complete:
        ({required AiConfig config, required String prompt, Duration timeout = Duration.zero}) async {
          calls++;
          if (fail) {
            return const AiCompletionResult(
              ok: false,
              statusCode: 500,
              text: '',
              message: '服务不可用',
            );
          }
          return const AiCompletionResult(
            ok: true,
            statusCode: 200,
            text: _payload,
            message: '',
          );
        },
  );
}

void main() {
  late Directory temp;
  late _FakeCompletion completion;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ai-rec-section');
    completion = _FakeCompletion();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
      aiContentCompletion: completion.build(),
    );
    await state.bootstrap();
    await state.saveAiConfig(
      const AiConfig(
        enabled: true,
        apiKey: 'k',
        endpoint: 'https://example.test/v1',
        model: 'm',
      ),
    );
  });

  tearDown(() async {
    state.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(WidgetTester tester, {String seed = '当前影片'}) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // 这个区块读的是真实磁盘缓存（loadCached）再发真实异步刷新，
    // 所以挂载与推进都必须在 runAsync 的真实时钟里做，否则 File IO 永远不完成。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiRecommendationSection(state: state, seedTitle: seed),
            ),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
  }

  testWidgets('无缓存时自动刷新一次并展示卡片', (tester) async {
    await pump(tester);
    expect(completion.calls, 1, reason: '无缓存 → 进详情页即刷新（B 方案）');
    expect(
      find.byKey(const ValueKey('ai-detail-recommendation-新片A')),
      findsOneWidget,
    );
  });

  testWidgets('推荐区是横向海报条，可左右滑动且带海报与不感兴趣入口', (tester) async {
    await pump(tester);
    final strip = tester.widget<ListView>(
      find.byKey(const ValueKey('ai-detail-recommendations-strip')),
    );
    expect(strip.scrollDirection, Axis.horizontal, reason: '要和海报条一样横向展示');
    // 每张卡是一个 160 宽的海报卡，带"不感兴趣"角标。
    expect(
      find.byKey(const ValueKey('ai-detail-recommendation-hide-新片A')),
      findsOneWidget,
    );
    expect(find.byType(PosterImage), findsWidgets);
    expect(find.byKey(const ValueKey('ai-detail-recommendations-title')), findsOneWidget);
  });
  testWidgets('长按海报打开推荐详情：理由/简介/不感兴趣/关闭齐全', (tester) async {
    await pump(tester);
    final poster = find.byKey(const ValueKey('ai-detail-recommendation-新片A'));
    await tester.longPress(poster);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ai-recommendation-details')), findsOneWidget);
    expect(find.text('推荐详情'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-recommendation-details-source')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-recommendation-details-title')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-recommendation-details-overview')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-recommendation-details-hide')),
      findsOneWidget,
    );

    // 关闭按钮只关弹窗，不改列表。
    await tester.tap(
      find.byKey(const ValueKey('ai-recommendation-details-confirm')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-recommendation-details')), findsNothing);
    expect(
      find.byKey(const ValueKey('ai-detail-recommendation-新片A')),
      findsOneWidget,
    );
  });

  testWidgets('详情弹窗里的「不感兴趣」会写入负反馈并关闭弹窗', (tester) async {
    await pump(tester);
    await tester.longPress(
      find.byKey(const ValueKey('ai-detail-recommendation-新片A')),
    );
    await tester.pumpAndSettle();
    // 写负反馈是真实文件 IO：必须在真实时钟里点，否则 FakeAsync 里永不完成。
    RecommendationFeedbackCollection? feedback;
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey('ai-recommendation-details-hide')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      feedback = await state.aiIntegration.recommendation.loadFeedback();
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ai-recommendation-details')), findsNothing);
    expect(
      find.byKey(const ValueKey('ai-detail-recommendation-新片A')),
      findsNothing,
      reason: '不感兴趣后该卡从条上移除',
    );
    expect(
      feedback!.entries.any((entry) => entry.title == '新片A'),
      isTrue,
      reason: '负反馈必须落盘',
    );
  });
  testWidgets('指纹一致且缓存新鲜时复用缓存，不再消耗付费调用', (tester) async {
    await pump(tester);
    expect(completion.calls, 1);

    // 重新挂载（等价于再次进入同一详情页）。
    await tester.pumpWidget(const SizedBox());
    await pump(tester);
    expect(completion.calls, 1, reason: '输入没变 → 直接读缓存，省 token');
    expect(
      find.byKey(const ValueKey('ai-detail-recommendation-新片A')),
      findsOneWidget,
    );
  });

  testWidgets('上下文变化导致指纹变化时重新刷新', (tester) async {
    await pump(tester);
    expect(completion.calls, 1);

    // 换一部影片即换输入（等价于历史/搜索上下文变了）。
    await tester.pumpWidget(const SizedBox());
    await pump(tester, seed: '另一部影片');
    expect(completion.calls, 2, reason: '输入指纹变了必须刷新');
  });

  testWidgets('刷新失败保留已显示的缓存内容并给出提示', (tester) async {
    await pump(tester);
    expect(completion.calls, 1);

    completion.fail = true;
    await tester.pumpWidget(const SizedBox());
    await pump(tester, seed: '另一部影片');
    expect(completion.calls, 2);
    // 失败不清空：仍展示上一份缓存，并显示失败原因。
    expect(
      find.byKey(const ValueKey('ai-detail-recommendation-新片A')),
      findsOneWidget,
      reason: '刷新失败不得清空已显示内容',
    );
    expect(
      find.byKey(const ValueKey('ai-detail-recommendations-message')),
      findsOneWidget,
    );
  });

  testWidgets('未配置 AI 时整块不渲染也不发请求', (tester) async {
    await state.saveAiConfig(const AiConfig());
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiRecommendationSection(state: state, seedTitle: '当前影片'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
    await tester.pump();
    expect(completion.calls, 0);
    expect(
      find.byKey(const ValueKey('ai-detail-recommendations')),
      findsNothing,
    );
  });

  test('上下文内容变化会改变输入指纹（历史新增即刷新）', () {
    const base = RecommendationRequest(
      source: RecommendationSource.current,
      seed: WatchContextItem(title: '当前影片', mediaType: RecommendationMediaType.movie),
      contexts: [
        WatchContextItem(title: '看完的剧A', mediaType: RecommendationMediaType.tv),
      ],
    );
    final withMore = base.copyWith();
    final extended = RecommendationRequest(
      source: base.source,
      seed: base.seed,
      contexts: const [
        WatchContextItem(title: '看完的剧A', mediaType: RecommendationMediaType.tv),
        WatchContextItem(title: '新看的剧B', mediaType: RecommendationMediaType.tv),
      ],
    );
    final first = RecommendationCachePolicy.inputFingerprintOf(
      providerSignature: 'p',
      request: base,
    );
    expect(
      RecommendationCachePolicy.inputFingerprintOf(
        providerSignature: 'p',
        request: withMore,
      ),
      first,
      reason: '同样输入必须得到同样指纹',
    );
    expect(
      RecommendationCachePolicy.inputFingerprintOf(
        providerSignature: 'p',
        request: extended,
      ),
      isNot(first),
      reason: '历史上新增一部剧 → 指纹必须变化',
    );
  });
}
