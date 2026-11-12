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

import 'support/temp_dirs.dart';

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
        ({
          required AiConfig config,
          required String prompt,
          Duration timeout = Duration.zero,
        }) async {
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
      // 四个最终目录都必须显式给：Linux/macOS 分支只读 XDG_*，'roaming'/'local'
      // 仅 Windows 生效，只传后两者会让各用例共用真实用户缓存（前一例写的
      // ai_content/rec_*.json 会让后一例少发一次请求）。这里按每个用例自己的
      // temp 目录给，Windows/macOS/Linux 都命中显式值。
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
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
    await deleteTempDirBestEffort(temp);
  });

  Future<void> pump(
    WidgetTester tester, {
    String seed = '当前影片',
    ValueChanged<String>? onSearchTitle,
  }) async {
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
              child: AiRecommendationSection(
                state: state,
                seedTitle: seed,
                onSearchTitle: onSearchTitle,
              ),
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
      find.byKey(const ValueKey('recommendation-ai-新片A')),
      findsOneWidget,
    );
  });

  testWidgets('推荐区是横向海报条，与其它推荐行同宽同标题样式', (tester) async {
    await pump(tester);
    final strip = tester.widget<ListView>(
      find.byKey(const ValueKey('recommendation-row-ai')),
    );
    expect(strip.scrollDirection, Axis.horizontal, reason: '要和海报条一样横向展示');
    expect(find.byType(PosterImage), findsWidgets);
    expect(
      find.byKey(const ValueKey('recommendation-heading-ai')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('recommendation-ai-新片A'))).width,
      130,
      reason: '与猜你喜欢/个性推荐行同一张卡宽',
    );
  });
  testWidgets('长按打开推荐说明：来源/信息/不感兴趣/关闭齐全', (tester) async {
    await pump(tester);
    final poster = find.byKey(const ValueKey('recommendation-ai-新片A'));
    await tester.longPress(poster);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('recommendation-info-dialog')),
      findsOneWidget,
    );
    // 来源、海报、元信息胶囊、简介占位、详情主按钮、不感兴趣都在。
    expect(
      find.byKey(const ValueKey('recommendation-info-source')),
      findsOneWidget,
    );
    expect(find.text('2021'), findsOneWidget);
    expect(find.text('剧集'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recommendation-info-poster')),
      findsOneWidget,
    );
    expect(find.text('暂无可用简介'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recommendation-info-open')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recommendation-info-hide')),
      findsOneWidget,
    );

    // 关闭按钮只关弹窗，不改列表。
    await tester.tap(find.byKey(const ValueKey('recommendation-info-close')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recommendation-info-dialog')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('recommendation-ai-新片A')),
      findsOneWidget,
    );
  });

  testWidgets('「详情」按钮与卡片单击走同一个去向', (tester) async {
    String? searched;
    await pump(tester, onSearchTitle: (title) => searched = title);
    await tester.longPress(
      find.byKey(const ValueKey('recommendation-ai-新片A')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recommendation-info-open')));
    await tester.pumpAndSettle();
    expect(searched, '新片A', reason: '详情 = 卡片单击：无身份时按标题搜站源');
    expect(
      find.byKey(const ValueKey('recommendation-info-dialog')),
      findsNothing,
      reason: '点详情先把弹窗关掉再走卡片同一条去路',
    );
  });

  testWidgets('详情弹窗里的「不感兴趣」会写入负反馈并关闭弹窗', (tester) async {
    await pump(tester);
    await tester.longPress(
      find.byKey(const ValueKey('recommendation-ai-新片A')),
    );
    await tester.pumpAndSettle();
    // 写负反馈是真实文件 IO：必须在真实时钟里点，否则 FakeAsync 里永不完成。
    RecommendationFeedbackCollection? feedback;
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey('recommendation-info-hide')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      feedback = await state.aiIntegration.recommendation.loadFeedback();
    });
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('recommendation-info-dialog')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('recommendation-ai-新片A')),
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
      find.byKey(const ValueKey('recommendation-ai-新片A')),
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
      find.byKey(const ValueKey('recommendation-ai-新片A')),
      findsOneWidget,
      reason: '刷新失败不得清空已显示内容',
    );
    expect(
      find.byKey(const ValueKey('recommendation-ai-message')),
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
      find.byKey(const ValueKey('recommendation-section-ai')),
      findsNothing,
    );
  });

  test('上下文内容变化会改变输入指纹（历史新增即刷新）', () {
    const base = RecommendationRequest(
      source: RecommendationSource.current,
      seed: WatchContextItem(
        title: '当前影片',
        mediaType: RecommendationMediaType.movie,
      ),
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
