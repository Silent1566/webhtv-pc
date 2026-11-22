/// 「选择续播记录」弹框的门禁（`docs/phase6/design/02` §9）。
///
/// 用户 2026-11-29 的选型：不同爬虫源的进度**都标记、展示有差异**，真正续播时
/// 由用户自己选。因此这个弹框必须做到三件事，缺一件就会变成「自动替我选了」：
/// 1. 每条记录都写清**来源、集、看到哪、多久以前**——用户凭这些判断选哪条；
/// 2. 默认选中**最近观看**的那条（排序在 core 里已定），但不自动确认；
/// 3. 取消 = 不播、不写任何东西，返回 `null`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/history_progress_picker.dart';

void main() {
  const nowMs = 1700000000000;

  HistoryProgressChoice choiceOf({
    String sourceLabel = '本站',
    bool isOwnSite = true,
    String lineFlag = '线路一',
    int episodeIndex = 1,
    String episodeName = '第2集',
    int positionMs = 600000,
    int durationMs = 2400000,
    int updatedAt = nowMs - 3 * 3600 * 1000,
  }) => HistoryProgressChoice(
    sourceLabel: sourceLabel,
    isOwnSite: isOwnSite,
    lineFlag: lineFlag,
    episodeIndex: episodeIndex,
    episodeName: episodeName,
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: updatedAt,
  );

  Future<HistoryProgressChoice?> Function() openPicker(
    WidgetTester tester,
    List<HistoryProgressChoice> choices,
  ) {
    HistoryProgressChoice? result;
    return () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showHistoryProgressPicker(
                      context,
                      choices: choices,
                      nowMs: nowMs,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    };
  }

  testWidgets('列出每条记录的来源/集名/进度/相对时间，默认选中最近的一条', (tester) async {
    final open = openPicker(tester, [
      choiceOf(sourceLabel: '本站', updatedAt: nowMs - 3 * 3600 * 1000),
      choiceOf(
        sourceLabel: '乙站',
        isOwnSite: false,
        episodeName: '第5集',
        positionMs: 1200000,
        updatedAt: nowMs - 5 * 60 * 1000,
      ),
    ]);
    await open();

    expect(find.byKey(const ValueKey('history-progress-dialog')), findsOneWidget);
    expect(find.text('本站'), findsOneWidget);
    expect(find.text('乙站'), findsOneWidget);
    expect(find.textContaining('第2集'), findsWidgets);
    expect(find.textContaining('第5集'), findsWidgets);
    expect(find.textContaining('10:00'), findsWidgets);
    expect(find.textContaining('20:00'), findsWidgets);
    expect(find.textContaining('3 小时前'), findsOneWidget);
    expect(find.textContaining('5 分钟前'), findsOneWidget);
    // 默认选中第 0 行（调用方按优先级排好序）：选中态必须**看得见**，
    // 否则用户不知道「播放」会播哪一条。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('history-progress-option-0')),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('history-progress-option-1')),
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
      findsOneWidget,
    );
  });

  testWidgets('确认返回当前选中的那条记录', (tester) async {
    final choices = [
      choiceOf(sourceLabel: '本站'),
      choiceOf(sourceLabel: '乙站', isOwnSite: false, episodeIndex: 4, episodeName: '第5集'),
    ];
    late Future<HistoryProgressChoice?> pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = showHistoryProgressPicker(
                    context,
                    choices: choices,
                    nowMs: nowMs,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('history-progress-option-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('history-progress-confirm')));
    await tester.pumpAndSettle();

    final picked = await pending;
    expect(picked, same(choices[1]));
  });

  testWidgets('取消返回 null，不替用户选', (tester) async {
    late Future<HistoryProgressChoice?> pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = showHistoryProgressPicker(
                    context,
                    choices: [choiceOf()],
                    nowMs: nowMs,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-progress-cancel')));
    await tester.pumpAndSettle();
    expect(await pending, isNull);
  });

  testWidgets('键盘上下切换、Enter 确认、Esc 取消', (tester) async {
    late Future<HistoryProgressChoice?> pending;
    final choices = [
      choiceOf(sourceLabel: '本站'),
      choiceOf(sourceLabel: '乙站', isOwnSite: false, episodeIndex: 4, episodeName: '第5集'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  pending = showHistoryProgressPicker(
                    context,
                    choices: choices,
                    nowMs: nowMs,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect((await pending)?.sourceLabel, '乙站');
  });
}
