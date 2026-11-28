import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/watched_recommendation.dart';
import 'package:webhtv_pc/services/recommendation_watch_store.dart';
import 'package:webhtv_pc/ui/recommendation_info_dialog.dart';
import 'package:webhtv_pc/ui/toast.dart';
import 'package:webhtv_pc/ui/tokens.dart';

const _work = RecommendationWork(title: '推荐样片', mediaType: TmdbMediaType.movie);

Future<void> _openInfo(
  WidgetTester tester,
  RecommendationWatchStore watched,
) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          Stack(fit: StackFit.expand, children: [child!, const ToastHost()]),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRecommendationInfo(
              context,
              info: const RecommendationInfo(
                title: '推荐样片',
                sourceLabel: 'TMDB',
              ),
              watched: watched,
              work: _work,
            ),
            child: const Text('查看资料'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('查看资料'));
  await tester.pumpAndSettle();
}

void main() {
  late Directory directory;
  late RecommendationWatchStore watched;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('watch-toast-');
    watched = RecommendationWatchStore(
      file: File('${directory.path}/watch.json'),
    );
  });

  tearDown(() {
    dismissAllToasts();
    watched.dispose();
    directory.deleteSync(recursive: true);
  });

  testWidgets('已看通知的撤销动作在六秒后随通知消失', (tester) async {
    await _openInfo(tester, watched);
    await tester.tap(find.text('标记已看'));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    final toast = toastCenter.toasts.single;
    expect(toast.kind, ToastKind.success);
    expect(toast.duration, const Duration(seconds: 6));
    expect(watched.contains(_work), isTrue);

    await tester.pump(const Duration(milliseconds: 5999));
    expect(find.text('已标记为看过'), findsOneWidget);
    expect(find.text('撤销').hitTestable(), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(AppMotion.base + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('已标记为看过'), findsNothing);
    expect(find.text('撤销'), findsNothing);
    expect(watched.contains(_work), isTrue);
  });

  testWidgets('取消已看显示没有撤销动作的定时通知', (tester) async {
    expect(watched.setWatched(_work, true), isTrue);
    await _openInfo(tester, watched);
    await tester.tap(find.text('取消已看'));
    await tester.pump();

    expect(watched.contains(_work), isFalse);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('已取消已看标记'), findsOneWidget);
    expect(toastCenter.toasts.single.duration, greaterThan(Duration.zero));
    expect(find.text('撤销'), findsNothing);
  });

  for (final undo in [false, true]) {
    testWidgets(undo ? '撤销写盘失败显示错误通知' : '标记写盘失败显示错误通知', (tester) async {
      await _openInfo(tester, watched);
      if (undo) {
        await tester.tap(find.text('标记已看'));
        await tester.pump();
        await tester.pump(AppMotion.base);
      }
      Directory('${watched.file!.path}.tmp').createSync();
      await tester.tap(find.text(undo ? '撤销' : '标记已看'));
      await tester.pump();

      final message = undo ? '未能撤销已看标记' : '未能保存已看标记';
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text(message), findsOneWidget);
      final error = toastCenter.toasts.singleWhere(
        (toast) => toast.message == message,
      );
      expect(error.kind, ToastKind.error);
      expect(error.duration, greaterThan(Duration.zero));
      expect(watched.contains(_work), undo);
    });
  }
}
