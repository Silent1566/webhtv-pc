import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/external_player_catalog.dart';
import 'package:webhtv_pc/services/external_player.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  const a = r'D:\Players\A.exe';
  const b = r'D:\Players\B.exe';
  const c = r'D:\Players\C.exe';
  const scanned = [ExternalPlayer(name: 'PotPlayer', executable: a)];

  test('覆盖保留初始锚点和历史路径，失去扫描来源后仍可见', () {
    final first = const ExternalPlayerCatalog().save(
      originalExecutable: a,
      name: '改名',
      executable: b,
      scanned: scanned,
    )!;
    final next = first.save(
      originalExecutable: b,
      name: '改路径',
      executable: c,
      scanned: scanned,
    )!;
    final restored = ExternalPlayerCatalog.fromJson(next.toJson());
    expect(
      restored.list(const [
        ExternalPlayer(name: 'PotPlayer', executable: a),
        ExternalPlayer(name: 'PotPlayer', executable: b),
        ExternalPlayer(name: 'PotPlayer', executable: c),
      ], legacyExecutable: b),
      const [ExternalPlayer(name: '改路径', executable: c)],
    );
    expect(restored.list(const []), const [
      ExternalPlayer(name: '改路径', executable: c),
    ]);
    expect(restored.resolveExecutable(a), c);
    expect(restored.resolveExecutable(b), c);
  });

  test('碰撞其他当前可执行路径时拒绝，自己的锚点可改回', () {
    final first = const ExternalPlayerCatalog().save(
      originalExecutable: a,
      name: '覆盖',
      executable: b,
      scanned: scanned,
    )!;
    for (final target in [
      b,
      r'd:/players/B.EXE',
      r'D:\Players\inner\..\B.exe',
    ]) {
      expect(
        first.save(name: '新增', executable: target, scanned: scanned),
        isNull,
      );
    }
    expect(
      first
          .save(
            originalExecutable: b,
            name: '返回',
            executable: a,
            scanned: scanned,
          )!
          .list(scanned),
      const [ExternalPlayer(name: '返回', executable: a)],
    );
    expect(
      const ExternalPlayerCatalog().save(
        originalExecutable: a,
        name: '改',
        executable: c,
        scanned: const [
          ExternalPlayer(name: 'PotPlayer', executable: a),
          ExternalPlayer(name: 'VLC', executable: c),
        ],
      ),
      isNull,
    );
    expect(
      const ExternalPlayerCatalog().save(
        name: '新增',
        executable: c,
        scanned: scanned,
        legacyExecutable: c,
      ),
      isNull,
    );
  });

  test('覆盖后可显式新增历史路径，新旧条目保持独立且不复活扫描幽灵', () {
    for (final rescan in [scanned, const <ExternalPlayer>[]]) {
      final overridden = const ExternalPlayerCatalog().save(
        originalExecutable: a,
        name: '原条目改成B',
        executable: b,
        scanned: scanned,
      )!;
      expect(overridden.list(rescan), const [
        ExternalPlayer(name: '原条目改成B', executable: b),
      ]);
      final added = overridden.save(
        name: '用户显式新增A',
        executable: a,
        scanned: rescan,
      );
      expect(added, isNotNull, reason: '历史锚点不等于当前exe碰撞');
      final restored = ExternalPlayerCatalog.fromJson(added!.toJson());
      expect(restored.list(rescan).toSet(), {
        ExternalPlayer(name: '原条目改成B', executable: b),
        ExternalPlayer(name: '用户显式新增A', executable: a),
      });
      expect(
        restored.resolveExecutable(a),
        a,
        reason: '显式新条目的当前exe优先于其他条目的历史锚点',
      );
      final edited = restored.save(
        originalExecutable: a,
        name: '新增A改成C',
        executable: c,
        scanned: rescan,
      )!;
      expect(edited.list(rescan).toSet(), {
        ExternalPlayer(name: '原条目改成B', executable: b),
        ExternalPlayer(name: '新增A改成C', executable: c),
      });
      expect(
        edited.save(
          originalExecutable: c,
          name: '真正碰撞B',
          executable: b,
          scanned: rescan,
        ),
        isNull,
      );
    }
  });

  test('旧单路径匹配扫描时合并，不匹配时显示并可修复非法旧路径', () {
    expect(
      const ExternalPlayerCatalog().list(
        scanned,
        legacyExecutable: r'd:/players/A.EXE',
      ),
      scanned,
    );
    const old = 'missing-player';
    final catalog = const ExternalPlayerCatalog().save(
      originalExecutable: old,
      name: '修复旧配置',
      executable: c,
      scanned: const [],
      legacyExecutable: old,
    )!;
    expect(
      ExternalPlayerCatalog.fromJson(catalog.toJson())
          .list(const [], legacyExecutable: old),
      const [ExternalPlayer(name: '修复旧配置', executable: c)],
    );
  });

  test('连续A到B到C后可显式重建历史B，重扫和重载保持独立身份', () {
    final first = const ExternalPlayerCatalog().save(
      originalExecutable: a,
      name: '原B',
      executable: b,
      scanned: scanned,
    )!;
    final moved = first.save(
      originalExecutable: b,
      name: '原C',
      executable: c,
      scanned: scanned,
    )!;
    const rescan = [
      ExternalPlayer(name: '扫描A', executable: a),
      ExternalPlayer(name: '扫描B', executable: b),
    ];
    expect(moved.list(rescan), const [
      ExternalPlayer(name: '原C', executable: c),
    ]);
    final added = moved.save(name: '显式B', executable: b, scanned: rescan);
    expect(added, isNotNull);
    final restored = ExternalPlayerCatalog.fromJson(added!.toJson());
    expect(restored.list(rescan).toSet(), {
      const ExternalPlayer(name: '原C', executable: c),
      const ExternalPlayer(name: '显式B', executable: b),
    });
    expect(restored.resolveExecutable(b), b);
    expect(
      restored.save(
        originalExecutable: b,
        name: '碰撞C',
        executable: c,
        scanned: rescan,
      ),
      isNull,
    );
  });

  test('AppState 无store与挂store的列表都是不可变快照', () async {
    final mutableScan = [...scanned];
    final state = AppState(externalPlayerDetector: () => mutableScan);
    addTearDown(state.dispose);
    final detached = await state.listExternalPlayers();
    expect(
      () => detached.add(const ExternalPlayer(name: '额外', executable: b)),
      throwsUnsupportedError,
    );
    mutableScan.clear();
    expect(detached, scanned, reason: '调用者持有的是快照而非扫描器可变引用');
    mutableScan.addAll(scanned);
    state.attachUiPreferences(UiPreferencesStore(path: 'unused-settings.json'));
    final attached = await state.listExternalPlayers();
    expect(() => attached.clear(), throwsUnsupportedError);
    mutableScan.clear();
    expect(attached, scanned);
  });

  test('AppState 的精确接口可独立注入扫描，不依赖 bootstrap 或 UI', () async {
    final state = AppState(externalPlayerDetector: () => scanned);
    addTearDown(state.dispose);
    expect(await state.listExternalPlayers(), scanned);
    expect(await state.saveExternalPlayer(name: '新建', executable: c), isFalse);
    final store = UiPreferencesStore(path: 'unused-settings.json');
    state.attachUiPreferences(store);
    expect(await state.listExternalPlayers(), scanned);
    expect(
      await state.saveExternalPlayer(
        originalExecutable: a,
        name: '',
        executable: c,
      ),
      isFalse,
    );
  });
}
