/// 历史页删除模式状态机与点击行为归一化（`docs/phase6/design/01` §3.4、§4）。
///
/// 纯逻辑，无 Flutter 依赖：这些语义（"长按进删除态后点谁删谁"、
/// "多选态点卡片只勾选"）是本轮最容易写错的地方，必须在无窗口环境下锁死。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  group('删除模式状态机', () {
    test('初始态是 none，无选中', () {
      expect(HistoryViewState.initial.mode, HistoryViewMode.none);
      expect(HistoryViewState.initial.selectedIds, isEmpty);
      expect(HistoryViewState.initial.canDeleteSelected, isFalse);
    });

    test('长按进删除态：singleDelete 且无选中集', () {
      final next = HistoryViewState.initial.enterSingleDelete();
      expect(next.mode, HistoryViewMode.singleDelete);
      expect(next.selectedIds, isEmpty, reason: '删除态没有"选中集"概念');
    });

    test('进多选态：清空已有选中', () {
      final dirty = HistoryViewState.initial
          .enterMultiSelect()
          .toggleSelection(7);
      final next = dirty.enterMultiSelect();
      expect(next.mode, HistoryViewMode.multiSelect);
      expect(next.selectedIds, isEmpty);
    });

    test('多选态点卡片只切换勾选，不删除', () {
      var state = HistoryViewState.initial.enterMultiSelect();
      state = state.toggleSelection(3);
      expect(state.selectedIds, {3});
      state = state.toggleSelection(3);
      expect(state.selectedIds, isEmpty, reason: '再点一次取消勾选');
    });

    test('singleDelete 下 toggleSelection 不产生选中', () {
      final state = HistoryViewState.initial
          .enterSingleDelete()
          .toggleSelection(5);
      expect(state.selectedIds, isEmpty);
    });

    test('全选只勾选传入的可见 id', () {
      final state = HistoryViewState.initial
          .enterMultiSelect()
          .selectAll(const [4, 9, 2]);
      expect(state.selectedIds, {2, 4, 9});
      expect(state.selectedInOrder, [2, 4, 9], reason: '稳定升序，便于断言');
    });

    test('退出模式清空选中，保留 keyword', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterMultiSelect()
          .toggleSelection(1)
          .exitMode();
      expect(state.mode, HistoryViewMode.none);
      expect(state.selectedIds, isEmpty);
      expect(state.keyword, '剧名');
    });

    test('canDeleteSelected 仅多选态且有选中时为真', () {
      expect(HistoryViewState.initial.enterMultiSelect().canDeleteSelected, isFalse);
      expect(
        HistoryViewState.initial.enterMultiSelect().toggleSelection(1).canDeleteSelected,
        isTrue,
      );
      expect(
        HistoryViewState.initial.enterSingleDelete().toggleSelection(1).canDeleteSelected,
        isFalse,
      );
    });

    // 以下五个用例由 mutant 自检补入：原 brief 用例不足，删掉对应实现仍然全绿。

    test('长按进删除态：清空多选态残留的选中', () {
      final dirty = HistoryViewState.initial
          .enterMultiSelect()
          .toggleSelection(3)
          .toggleSelection(4);
      final next = dirty.enterSingleDelete();
      expect(next.selectedIds, isEmpty, reason: '删除态没有"选中集"概念');
    });

    test('selectAll 只在多选态生效', () {
      expect(HistoryViewState.initial.selectAll(const [1, 2]).selectedIds, isEmpty);
      expect(
        HistoryViewState.initial.enterSingleDelete().selectAll(const [1, 2]).selectedIds,
        isEmpty,
      );
    });

    test('selectAll 与已有勾选取并集，不覆盖', () {
      final state = HistoryViewState.initial
          .enterMultiSelect()
          .toggleSelection(7)
          .selectAll(const [1, 2]);
      expect(state.selectedInOrder, [1, 2, 7]);
    });

    test('clearSelection 清空勾选，保留 mode 与 keyword', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterMultiSelect()
          .toggleSelection(5)
          .clearSelection();
      expect(state.selectedIds, isEmpty);
      expect(state.mode, HistoryViewMode.multiSelect, reason: '清勾选不等于退模式');
      expect(state.keyword, '剧名');
    });

    test('canDeleteSelected 认模式而不认选中集', () {
      // 直接构造「非多选态却带着选中集」的非法组合：真实转移不会产生它，
      // 但 getter 的契约是「仅多选态」，必须自己把模式也判一遍。
      const impossible = HistoryViewState(
        mode: HistoryViewMode.singleDelete,
        selectedIds: {1},
        keyword: '',
      );
      expect(impossible.canDeleteSelected, isFalse);
    });
  });

  group('搜索词变化（§3.4）', () {
    test('搜索词未变化时返回同一实例，不清空选中', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterMultiSelect()
          .toggleSelection(8);
      final next = state.withKeyword('剧名');
      expect(identical(next, state), isTrue, reason: '否则每次 setState 都会清空勾选');
      expect(next.selectedIds, {8});
    });

    test('搜索词变化时清空选中', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterMultiSelect()
          .toggleSelection(8);
      final next = state.withKeyword('另一部');
      expect(next.selectedIds, isEmpty);
      expect(next.keyword, '另一部');
    });

    test('搜索词变化不退出 singleDelete', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterSingleDelete()
          .withKeyword('另一部');
      expect(state.mode, HistoryViewMode.singleDelete,
          reason: '删除态下点卡片即删，退出反而打断连续删除');
    });
  });

  group('点击行为归一化', () {
    test('合法值原样返回', () {
      expect(UiHistoryClickAction.normalize('detail'), UiHistoryClickAction.detail);
      expect(UiHistoryClickAction.normalize('play'), UiHistoryClickAction.play);
    });

    test('非法值与空值回落 detail（默认进详情页）', () {
      expect(UiHistoryClickAction.normalize(null), UiHistoryClickAction.detail);
      expect(UiHistoryClickAction.normalize(''), UiHistoryClickAction.detail);
      expect(UiHistoryClickAction.normalize('DETAIL'), UiHistoryClickAction.detail);
      expect(UiHistoryClickAction.normalize('play '), UiHistoryClickAction.play);
      expect(UiHistoryClickAction.normalize('nonsense'), UiHistoryClickAction.detail);
    });

    // 由 mutant 自检补入：原 brief 用例只覆盖「已是小写」的输入，
    // 去掉 toLowerCase() 仍然全绿。
    test('大小写与首尾空白都归一化', () {
      expect(UiHistoryClickAction.normalize('PLAY'), UiHistoryClickAction.play);
      expect(UiHistoryClickAction.normalize('  play  '), UiHistoryClickAction.play);
      expect(UiHistoryClickAction.normalize('Play'), UiHistoryClickAction.play);
      expect(UiHistoryClickAction.normalize('  DETAIL  '), UiHistoryClickAction.detail);
    });

    test('values 列出全部合法值，顺序稳定', () {
      expect(UiHistoryClickAction.values,
          [UiHistoryClickAction.detail, UiHistoryClickAction.play]);
    });
  });

  group('historyClickAction 持久化（settings.json 的 ui 段）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-history-click');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    UiPreferencesStore storeOf() =>
        UiPreferencesStore(path: p.join(dir.path, 'settings.json'));

    test('默认是 detail（缺席 = 默认，不写盘）', () async {
      final store = storeOf();
      await store.load();
      expect(store.historyClickAction, UiHistoryClickAction.detail);
      expect(store.hasExplicitHistoryClickAction, isFalse);
    });

    test('显式选择后落盘，重新 load 仍读到', () async {
      final store = storeOf();
      await store.load();
      await store.rememberHistoryClickAction(UiHistoryClickAction.play);

      final again = storeOf();
      await again.load();
      expect(again.historyClickAction, UiHistoryClickAction.play);
      expect(again.hasExplicitHistoryClickAction, isTrue);
    });

    test('非法值归一到 detail', () async {
      final store = storeOf();
      await store.load();
      await store.rememberHistoryClickAction('nonsense');
      expect(store.historyClickAction, UiHistoryClickAction.detail);
    });

    test('手改文件塞非法值时回落默认', () async {
      final file = File(p.join(dir.path, 'settings.json'));
      await file.writeAsString('{"ui":{"historyClickAction":"bogus"}}');
      final store = storeOf();
      await store.load();
      expect(store.historyClickAction, UiHistoryClickAction.detail);
    });

    test('不污染 ui 段的既有键（themeMode / searchKeywords 保留）', () async {
      final file = File(p.join(dir.path, 'settings.json'));
      await file.writeAsString(
        '{"ui":{"themeMode":"light","searchKeywords":["旧词"]},'
        '"tmdb":{"enabled":true},"sync":{"serverEnabled":true}}',
      );
      final store = storeOf();
      await store.load();
      await store.rememberHistoryClickAction(UiHistoryClickAction.play);

      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final ui = raw['ui']! as Map<String, Object?>;
      expect(ui['themeMode'], 'light');
      expect(ui['searchKeywords'], ['旧词']);
      expect(ui['historyClickAction'], UiHistoryClickAction.play);
      expect(raw.containsKey('tmdb'), isTrue, reason: '不得覆盖其他段');
      expect(raw.containsKey('sync'), isTrue, reason: '不得覆盖其他段');
    });

    // 以下三个用例由 mutant 自检补入：原 brief 用例不足，
    // 「缺席不写盘」与「load 校验非法值」两条实现被删掉仍然全绿。

    test('缺席不写盘：后续保存不会把默认 detail 固化进文件', () async {
      final file = File(p.join(dir.path, 'settings.json'));
      await file.writeAsString('{"ui":{"themeMode":"light"}}');
      final store = storeOf();
      await store.load();
      expect(store.hasExplicitHistoryClickAction, isFalse);
      // 触发一次别的写盘，确保文件被重写过。
      await store.rememberSearchThread(50);

      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final ui = raw['ui']! as Map<String, Object?>;
      expect(ui.containsKey('historyClickAction'), isFalse,
          reason: '缺席 = 默认，不该把 detail 固化进文件');
      expect(ui['themeMode'], 'light', reason: '重写时既有键仍要保留');
      expect(ui['searchThread'], 50);
    });

    test('文件里的非法值不算显式选择，也不会被写回', () async {
      final file = File(p.join(dir.path, 'settings.json'));
      await file.writeAsString('{"ui":{"historyClickAction":"bogus"}}');
      final store = storeOf();
      await store.load();
      expect(store.hasExplicitHistoryClickAction, isFalse,
          reason: '非法值不是用户的选择，不能当成「设过」');
      await store.rememberSearchThread(7);

      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final ui = raw['ui']! as Map<String, Object?>;
      expect(ui.containsKey('historyClickAction'), isFalse,
          reason: 'bogus 不得被原样写回');
    });

    test('文件里的大写/带空白合法值被接受，并按归一化后的值写回', () async {
      final file = File(p.join(dir.path, 'settings.json'));
      await file.writeAsString('{"ui":{"historyClickAction":"  PLAY  "}}');
      final store = storeOf();
      await store.load();
      expect(store.historyClickAction, UiHistoryClickAction.play);
      expect(store.hasExplicitHistoryClickAction, isTrue);
      await store.rememberSearchThread(9);

      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final ui = raw['ui']! as Map<String, Object?>;
      expect(ui['historyClickAction'], UiHistoryClickAction.play,
          reason: '写回的是归一化后的值，不是原样的空白/大写');
    });
  });

  group('AppState 暴露点击行为', () {
    late Directory dir;
    late AppState state;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-history-action');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${dir.path}/webhtv-pc',
            'data': '${dir.path}/webhtv-pc',
            'cache': '${dir.path}/webhtv-pc/cache',
            'state': '${dir.path}/webhtv-pc/logs',
          },
        ),
        log: LogService(),
      );
      await state.bootstrap();
    });

    tearDown(() async {
      state.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    AppState freshState() => AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${dir.path}/webhtv-pc',
          'data': '${dir.path}/webhtv-pc',
          'cache': '${dir.path}/webhtv-pc/cache',
          'state': '${dir.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
    );

    test('未 bootstrap 的默认值是 detail', () {
      final fresh = freshState();
      expect(fresh.historyClickAction, UiHistoryClickAction.detail);
      fresh.dispose();
    });

    test('设置后 getter 立刻反映（不依赖写盘成功）', () async {
      await state.setHistoryClickAction(UiHistoryClickAction.play);
      expect(state.historyClickAction, UiHistoryClickAction.play);
    });

    test('设置会通知监听者', () async {
      var notified = 0;
      state.addListener(() => notified++);
      await state.setHistoryClickAction(UiHistoryClickAction.play);
      expect(notified, greaterThan(0));
    });

    // 由 mutant 自检补入：把 notifyListeners() 挪到 store 写入**之前**仍然全绿。
    // 但那样监听者在收到通知时读到的是旧值，UI 会拿旧模式重建且不会再有第二次
    // 通知——用户点了「直接播放」界面却还停在「进详情页」。
    test('通知发出时 getter 已是新值（UI 重建读到新值）', () async {
      final seen = <String>[];
      state.addListener(() => seen.add(state.historyClickAction));

      await state.setHistoryClickAction(UiHistoryClickAction.play);

      expect(seen, isNotEmpty, reason: '至少要通知一次');
      expect(seen, everyElement(UiHistoryClickAction.play),
          reason: '通知期间读到的必须是新值，否则 UI 重建渲染旧模式且不再刷新');
    });

    // 以下用例由 mutant 自检补入：原 brief 三例只覆盖「store 已装配且值合法」，
    // 「getter 丢掉默认回落」「setter 不做归一化」「通知早于落定」三条实现被改坏
    // 仍然全绿。

    test('未 bootstrap 时 set 返回 false 且不抛（无 store 可写）', () async {
      final fresh = freshState();
      await expectLater(
        fresh.setHistoryClickAction(UiHistoryClickAction.play),
        completion(isFalse),
      );
      expect(fresh.historyClickAction, UiHistoryClickAction.detail,
          reason: '没有 store，无法记住任何选择');
      fresh.dispose();
    });

    test('setter 传非法值归一到 detail，不把脏值透给 getter', () async {
      await state.setHistoryClickAction('nonsense');
      expect(state.historyClickAction, UiHistoryClickAction.detail);

      await state.setHistoryClickAction('  PLAY  ');
      expect(state.historyClickAction, UiHistoryClickAction.play,
          reason: '大小写/空白归一化后才是生效值');
    });

    test('getter 转发的是归一化后的落盘值（重启后仍生效）', () async {
      final settings = AppPaths.resolve(
        overrides: {
          'config': '${dir.path}/webhtv-pc',
          'data': '${dir.path}/webhtv-pc',
          'cache': '${dir.path}/webhtv-pc/cache',
          'state': '${dir.path}/webhtv-pc/logs',
        },
      ).settingsPath;
      final file = File(settings);
      await file.create(recursive: true);
      await file.writeAsString('{"ui":{"historyClickAction":"  PLAY  "}}');

      final restarted = freshState();
      await restarted.bootstrap();
      expect(restarted.historyClickAction, UiHistoryClickAction.play);
      restarted.dispose();

      await file.writeAsString('{"ui":{"historyClickAction":"bogus"}}');
      final fallback = freshState();
      await fallback.bootstrap();
      expect(fallback.historyClickAction, UiHistoryClickAction.detail,
          reason: '文件里的脏值必须回落默认，不能让历史页拿到无法识别的模式');
      fallback.dispose();
    });
  });
}
