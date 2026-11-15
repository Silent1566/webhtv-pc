/// 「片头/片尾跳过」从两个布尔升级为「模式 + 类型掩码 + 数据源掩码 + 远端开关」
/// 的回归测试：旧配置迁移、派生 getter、旧 copyWith 参数，以及设置页四个新控件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/intro_skip_options_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

AppPaths _tempPaths(Directory temp) => AppPaths.resolve(
  overrides: {
    'config': '${temp.path}${Platform.pathSeparator}config',
    'data': '${temp.path}${Platform.pathSeparator}data',
    'cache': '${temp.path}${Platform.pathSeparator}cache',
    'state': '${temp.path}${Platform.pathSeparator}logs',
  },
);

/// 开关/下拉的回调里 await 真实写盘，假时钟的 pumpAndSettle 等不到它结束。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('旧配置迁移（fromJson）', () {
    test('{"autoSkipIntro":true,"autoSkipOutro":false} → auto + 只有片头位', () {
      final options = PlayerOptions.fromJson(const <String, Object?>{
        'autoSkipIntro': true,
        'autoSkipOutro': false,
      });
      expect(options.skipMode, SkipMode.auto);
      expect(
        options.skipKinds,
        SkipKindBits.intro,
        reason: '旧配置里没有回顾信息，不能凭空补出回顾位',
      );
      expect(options.skipKinds & SkipKindBits.outro, SkipKindBits.none);
      expect(options.skipKinds & SkipKindBits.recap, SkipKindBits.none);
      expect(options.autoSkipIntro, isTrue);
      expect(options.autoSkipOutro, isFalse);
    });

    test('{"autoSkipIntro":true,"autoSkipOutro":true} → auto + 片头|片尾', () {
      final options = PlayerOptions.fromJson(const <String, Object?>{
        'autoSkipIntro': true,
        'autoSkipOutro': true,
      });
      expect(options.skipMode, SkipMode.auto);
      expect(
        options.skipKinds,
        SkipKindBits.intro | SkipKindBits.outro,
        reason: '旧配置里没有回顾信息，不能凭空补出回顾位',
      );
      expect(options.skipKinds & SkipKindBits.recap, SkipKindBits.none);
      expect(options.autoSkipIntro, isTrue);
      expect(options.autoSkipOutro, isTrue);
    });

    test('空 JSON → off + 默认类型 + 远端开 + 数据源默认', () {
      for (final raw in <Object?>[
        const <String, Object?>{},
        null,
        'nonsense',
        const <Object?>[],
      ]) {
        final options = PlayerOptions.fromJson(raw);
        expect(options.skipMode, SkipMode.off, reason: 'raw=$raw');
        expect(options.skipKinds, SkipKindBits.defaults, reason: 'raw=$raw');
        expect(options.skipRemoteEnabled, isTrue, reason: 'raw=$raw');
        expect(options.skipSources, SkipSourceBits.defaults, reason: 'raw=$raw');
      }
    });

    test('两个旧键都 false → off + 出厂默认类型位', () {
      final options = PlayerOptions.fromJson(const <String, Object?>{
        'autoSkipIntro': false,
        'autoSkipOutro': false,
      });
      expect(options.skipMode, SkipMode.off);
      expect(
        options.skipKinds,
        SkipKindBits.defaults,
        reason: '两个都关等于没用过这功能，迁移成一类都不跳会让日后的开关形同虚设',
      );
      expect(options.autoSkipIntro, isFalse);
      expect(options.autoSkipOutro, isFalse);
    });

    test('新键优先：有 skipMode 时不看旧布尔键', () {
      final options = PlayerOptions.fromJson(const <String, Object?>{
        'skipMode': 'confirm',
        'skipKinds': SkipKindBits.intro,
        'autoSkipIntro': false,
        'autoSkipOutro': false,
        'skipRemoteEnabled': false,
        'skipSources': SkipSourceBits.todb,
      });
      expect(options.skipMode, SkipMode.confirm);
      expect(options.skipKinds, SkipKindBits.intro);
      expect(options.skipRemoteEnabled, isFalse);
      expect(options.skipSources, SkipSourceBits.todb);
    });

    test('越界值被夹住、脏类型回落默认，都不抛异常', () {
      final big = PlayerOptions.fromJson(const <String, Object?>{
        'skipMode': 'auto',
        'skipKinds': 9999,
        'skipSources': 9999,
      });
      expect(big.skipKinds, SkipKindBits.all);
      expect(big.skipSources, SkipSourceBits.defaults);

      final negative = PlayerOptions.fromJson(const <String, Object?>{
        'skipKinds': -5,
        'skipSources': -1,
      });
      expect(negative.skipKinds, SkipKindBits.none);
      expect(negative.skipSources, SkipSourceBits.none);

      final dirty = PlayerOptions.fromJson(const <String, Object?>{
        'skipMode': 42,
        'skipKinds': 'all',
        'skipSources': <int>[1],
        'skipRemoteEnabled': 'yes',
      });
      expect(dirty.skipMode, SkipMode.off);
      expect(dirty.skipKinds, SkipKindBits.defaults);
      expect(dirty.skipSources, SkipSourceBits.defaults);
      expect(dirty.skipRemoteEnabled, isTrue);
    });

    test('四个新字段写盘往返（toJson/fromJson/==/hashCode）', () {
      const options = PlayerOptions(
        skipMode: SkipMode.confirm,
        skipKinds: SkipKindBits.intro | SkipKindBits.preview,
        skipRemoteEnabled: false,
        skipSources: SkipSourceBits.introdb | SkipSourceBits.todb,
      );
      final json = options.toJson();
      expect(json['skipMode'], 'confirm');
      expect(json['skipKinds'], SkipKindBits.intro | SkipKindBits.preview);
      expect(json['skipRemoteEnabled'], isFalse);
      expect(json['skipSources'], SkipSourceBits.introdb | SkipSourceBits.todb);

      final restored = PlayerOptions.fromJson(json);
      expect(restored, options);
      expect(restored.skipMode, SkipMode.confirm);
      expect(restored.hashCode, options.hashCode);
      expect(options.toString(), contains('confirm'));
    });
  });

  group('派生 getter 与旧 copyWith 参数', () {
    test('模式关闭时两个派生 getter 都为 false，即使类型位还在', () {
      const options = PlayerOptions(
        skipMode: SkipMode.off,
        skipKinds: SkipKindBits.intro | SkipKindBits.outro,
      );
      expect(options.autoSkipIntro, isFalse);
      expect(options.autoSkipOutro, isFalse);
    });

    test('copyWith(autoSkipIntro: true) → 模式升到 auto 并置片头位', () {
      const before = PlayerOptions(skipKinds: SkipKindBits.recap);
      expect(before.skipMode, SkipMode.off);
      final after = before.copyWith(autoSkipIntro: true);
      expect(after.skipMode, SkipMode.auto);
      expect(after.skipKinds & SkipKindBits.intro, SkipKindBits.intro);
      expect(after.skipKinds & SkipKindBits.outro, SkipKindBits.none);
      expect(after.autoSkipIntro, isTrue);
    });

    test('copyWith(autoSkipIntro: false) 只清片头位，模式不动', () {
      const before = PlayerOptions(
        skipMode: SkipMode.confirm,
        skipKinds: SkipKindBits.intro | SkipKindBits.outro,
      );
      final after = before.copyWith(autoSkipIntro: false);
      expect(after.skipMode, SkipMode.confirm);
      expect(after.skipKinds & SkipKindBits.intro, SkipKindBits.none);
      expect(
        after.skipKinds & SkipKindBits.outro,
        SkipKindBits.outro,
        reason: '另一类不能被连带清掉',
      );
      expect(after.autoSkipIntro, isFalse);
    });

    test('copyWith(autoSkipOutro: true/false) 按同样语义走片尾位', () {
      const before = PlayerOptions(skipKinds: SkipKindBits.recap);
      final on = before.copyWith(autoSkipOutro: true);
      expect(on.skipMode, SkipMode.auto);
      expect(on.skipKinds & SkipKindBits.outro, SkipKindBits.outro);
      expect(on.autoSkipOutro, isTrue);

      final off = on.copyWith(autoSkipOutro: false);
      expect(off.skipMode, SkipMode.auto, reason: '清位不改模式');
      expect(off.skipKinds & SkipKindBits.outro, SkipKindBits.none);
      expect(off.autoSkipOutro, isFalse);
    });

    test('旧参数关掉后不会把模式降回 off（旧调用点只表达「这一类不跳」）', () {
      const before = PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.intro | SkipKindBits.outro,
      );
      final after = before.copyWith(autoSkipIntro: false, autoSkipOutro: false);
      expect(after.skipMode, SkipMode.auto);
      expect(after.skipKinds, SkipKindBits.none);
    });

    test('copyWith 新字段，且不传时四个字段原样保留', () {
      const before = PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.intro,
        skipRemoteEnabled: false,
        skipSources: SkipSourceBits.introdb,
      );
      final kept = before.copyWith(autoNext: false);
      expect(kept.skipMode, SkipMode.auto);
      expect(kept.skipKinds, SkipKindBits.intro);
      expect(kept.skipRemoteEnabled, isFalse);
      expect(kept.skipSources, SkipSourceBits.introdb);

      final changed = before.copyWith(
        skipMode: SkipMode.confirm,
        skipKinds: SkipKindBits.outro,
        skipRemoteEnabled: true,
        skipSources: SkipSourceBits.todb,
      );
      expect(changed.skipMode, SkipMode.confirm);
      expect(changed.skipKinds, SkipKindBits.outro);
      expect(changed.skipRemoteEnabled, isTrue);
      expect(changed.skipSources, SkipSourceBits.todb);
    });
  });

  group('设置页四项控件', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-skip-settings');
      state = AppState(paths: _tempPaths(temp), log: LogService());
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: IntroSkipOptionsPage(state: state),
        ),
      );
      await tester.pump();
    }

    Future<void> reveal(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('四个控件齐全，候选与默认值正确', (tester) async {
      await pumpPage(tester);

      final remote = find.byKey(const ValueKey('settings-player-skip-remote'));
      await reveal(tester, remote);
      expect(tester.widget<SwitchListTile>(remote).value, isTrue);
      expect(find.text('远端识别片头片尾'), findsOneWidget);
      expect(find.text('从 IntroDB / TheIntroDB / TODB 自动获取时间轴'), findsOneWidget);

      final modeTile = find.byKey(const ValueKey('settings-player-skip-mode'));
      await reveal(tester, modeTile);
      final dropdownFinder = find.descendant(
        of: modeTile,
        matching: find.byType(DropdownButton<SkipMode>),
      );
      final dropdown = tester.widget<DropdownButton<SkipMode>>(dropdownFinder);
      expect(dropdown.value, SkipMode.off);
      expect(
        dropdown.items!.map((item) => (item.child as Text).data).toList(),
        <String>['关闭', '自动跳过', '先询问'],
      );

      expect(
        find.byKey(const ValueKey('settings-player-skip-kinds')),
        findsOneWidget,
      );
      for (final kind in SkipKind.values) {
        final finder = find.byKey(
          ValueKey('settings-player-skip-kind-${kind.name}'),
        );
        await reveal(tester, finder);
        expect(
          tester.widget<CheckboxListTile>(finder).value,
          (SkipKindBits.defaults & kind.bit) != 0,
          reason: '${kind.label} 的勾选态必须来自默认类型位',
        );
        expect(find.text(kind.label), findsWidgets);
      }

      expect(
        find.byKey(const ValueKey('settings-player-skip-sources')),
        findsOneWidget,
      );
      const labels = <String, String>{
        'introdb': 'IntroDB',
        'theintrodb': 'TheIntroDB',
        'todb': 'TODB',
      };
      for (final id in SkipSourceBits.all) {
        final finder = find.byKey(ValueKey('settings-player-skip-source-$id'));
        await reveal(tester, finder);
        expect(
          tester.widget<CheckboxListTile>(finder).value,
          SkipSourceBits.enabled(SkipSourceBits.defaults, id),
          reason: '数据源 $id 默认全开',
        );
        expect(find.text(labels[id]!), findsWidgets);
      }
    });

    testWidgets('每项改动都写进 playerOptions 并落盘 settings.json', (tester) async {
      await pumpPage(tester);

      final remote = find.byKey(const ValueKey('settings-player-skip-remote'));
      await reveal(tester, remote);
      await tester.tap(remote);
      await _flush(tester);
      expect(state.playerOptions.skipRemoteEnabled, isFalse);
      expect(
        tester.widget<SwitchListTile>(remote).value,
        isFalse,
        reason: '拨动后必须回显，不能弹回原值',
      );

      final modeTile = find.byKey(const ValueKey('settings-player-skip-mode'));
      await reveal(tester, modeTile);
      final dropdownFinder = find.descendant(
        of: modeTile,
        matching: find.byType(DropdownButton<SkipMode>),
      );
      await tester.tap(dropdownFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('先询问').last);
      await _flush(tester);
      expect(state.playerOptions.skipMode, SkipMode.confirm);
      expect(
        tester.widget<DropdownButton<SkipMode>>(dropdownFinder).value,
        SkipMode.confirm,
      );

      final recap = find.byKey(
        const ValueKey('settings-player-skip-kind-recap'),
      );
      await reveal(tester, recap);
      await tester.tap(recap);
      await _flush(tester);
      expect(
        state.playerOptions.skipKinds & SkipKindBits.recap,
        SkipKindBits.none,
      );
      expect(
        state.playerOptions.skipKinds & SkipKindBits.intro,
        SkipKindBits.intro,
        reason: '只清点到的这一位',
      );
      expect(tester.widget<CheckboxListTile>(recap).value, isFalse);

      final todb = find.byKey(
        const ValueKey('settings-player-skip-source-todb'),
      );
      await reveal(tester, todb);
      await tester.tap(todb);
      await _flush(tester);
      expect(
        SkipSourceBits.enabled(state.playerOptions.skipSources, 'todb'),
        isFalse,
      );
      expect(
        SkipSourceBits.enabled(state.playerOptions.skipSources, 'introdb'),
        isTrue,
        reason: '另一家不能被连带关掉',
      );

      final player = await tester.runAsync(() async {
        final file = File(state.paths.settingsPath);
        for (var i = 0; i < 100; i++) {
          if (file.existsSync()) {
            final raw =
                jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
            final section = raw['player'];
            if (section is Map && section['skipMode'] == 'confirm') {
              return section as Map<String, Object?>;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return null;
      });
      expect(player, isNotNull, reason: 'settings.json 的 player 段必须写入新字段');
      final written = player!;
      expect(written['skipMode'], 'confirm');
      expect(written['skipRemoteEnabled'], isFalse);
      expect(written['skipKinds'], SkipKindBits.intro | SkipKindBits.outro);
      expect(
        written['skipSources'],
        SkipSourceBits.introdb | SkipSourceBits.theintrodb,
      );
    });
  });
}
