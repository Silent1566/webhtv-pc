import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-state');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('未 bootstrap 之外的默认值正确', () {
    expect(state.osdFlags, defaultOsdFlags());
    expect(state.playerButtonOrder, defaultButtonOrder());
    expect(state.playerButtonHidden, isEmpty);
  });

  // 关键用例：未 bootstrap 时（`_uiPreferences == null`）getter 必须回落到默认值，
  // **不得抛异常**。
  //
  // 为什么必须有这一条：上面那个用例的 setUp 总是 `await state.bootstrap()`，
  // 所以 `?? default*` 三条回落分支是**死代码**——变异测试实测确认：
  // 把回落改成 `_uiPreferences!.osdFlags`（会抛）或改成 `const {}`（值错）
  // 都能通过全部 5 个用例。而 `_uiPreferences` 字段自己的注释
  // （`app_state.dart:410-415`）就说明了为什么必须回落：单元测试/工具可能
  // **不调 bootstrap** 就直接用 AppState，此时取默认值应「安静降级，
  // 而不是把页面弄崩」。
  // （注意不要引 `PRODUCT.md` 的「失败必须如实」——那条讲的是**不要静默
  // 把错误当成功**，方向与「取默认值要安全」相反，引它反而自相矛盾。）
  test('未 bootstrap 时 getter 回落默认值而不抛异常', () {
    final bare = AppState(paths: state.paths, log: LogService());
    addTearDown(bare.dispose);
    // 不调用 bootstrap()。
    expect(bare.osdFlags, defaultOsdFlags());
    expect(bare.playerButtonOrder, defaultButtonOrder());
    expect(bare.playerButtonHidden, isEmpty);
  });

  // 关键用例：写操作必须真的通知监听者。
  //
  // 为什么必须有这一条：Task 9/10/11 都依赖「用户点了开关 → 界面立刻更新」。
  // 变异测试实测确认：删掉 `setOsdFlag` 里的 `notifyListeners()`，
  // 原有用例（名字里写着「并通知」）**仍然全绿**——它只断言了值，没断言通知。
  test('四个写操作各自通知一次监听者', () async {
    var notifications = 0;
    void listener() => notifications++;
    state.addListener(listener);
    addTearDown(() => state.removeListener(listener));

    await state.setOsdFlag(OsdFlag.mini, true);
    expect(notifications, 1, reason: 'setOsdFlag 必须通知');

    await state.setPlayerButtonOrder(['next', 'play']);
    expect(notifications, 2, reason: 'setPlayerButtonOrder 必须通知');

    await state.setPlayerButtonHidden({'speed'});
    expect(notifications, 3, reason: 'setPlayerButtonHidden 必须通知');

    await state.resetPlayerButtons();
    expect(notifications, 4, reason: 'resetPlayerButtons 必须通知');
  });

  test('设置屏显开关后立即生效并通知', () async {
    await state.setOsdFlag(OsdFlag.mini, true);
    expect(state.osdFlags[OsdFlag.mini], isTrue);
  });

  test('设置按钮顺序后立即生效', () async {
    await state.setPlayerButtonOrder(['next', 'play']);
    expect(state.playerButtonOrder.take(2).toList(), ['next', 'play']);
    // 用 `kPlayerButtons.length` 而不是写死数字：这条断言验证的是「用户给的
    // 两个 id 排在最前、其余按默认顺序补齐」，与按钮全集有几个无关。写死 9 会
    // 在按钮增删时误红（`line` 按钮并入选集面板后全集由 9 变 8，本用例因此
    // 在 beta 上失败了半天，而它要测的行为一直是对的）。
    expect(state.playerButtonOrder.length, kPlayerButtons.length);
  });

  test('设置隐藏集后立即生效', () async {
    await state.setPlayerButtonHidden({'speed'});
    expect(state.playerButtonHidden, {'speed'});
  });

  test('恢复默认后回到默认顺序与空隐藏集', () async {
    await state.setPlayerButtonOrder(['next', 'play']);
    await state.setPlayerButtonHidden({'speed'});
    await state.resetPlayerButtons();
    expect(state.playerButtonOrder, defaultButtonOrder());
    expect(state.playerButtonHidden, isEmpty);
  });

  // 关键用例：**从未设置过**时调 reset 必须走 store 的提前返回分支
  // （`ui_preferences_store.dart:398-400`），且仍要通知监听者。
  //
  // 为什么必须有这一条：上面那个用例先设了 order 与 hidden，
  // 所以 `_buttonOrder == null && _buttonHidden == null` 这个分支**从未被走到**——
  // 变异测试实测确认：把提前返回改成 `return false;` 或删掉它，用例仍绿。
  test('从未设置过时 reset 走提前返回分支且仍通知', () async {
    var notifications = 0;
    void listener() => notifications++;
    state.addListener(listener);
    addTearDown(() => state.removeListener(listener));

    final ok = await state.resetPlayerButtons();
    expect(ok, isTrue, reason: '提前返回分支必须返回 true（幂等成功）');
    expect(notifications, 1, reason: '即使无事可做，也要通知一次');
    expect(state.playerButtonOrder, defaultButtonOrder());
    expect(state.playerButtonHidden, isEmpty);
  });

  // 关键用例：setter 的返回值必须透传 store 的结果，不能被吞成常量 true。
  //
  // 为什么必须有这一条：7 个用例里没有任何一个断言过返回值，
  // 所以把 `return ok;` 改成 `return true;` 能全绿——而调用方
  // （Task 9/10 的界面）要靠这个 bool 决定是否提示「保存失败」。
  test('setter 透传 store 的返回值', () async {
    // 正常路径：store 可用 → true。
    expect(await state.setOsdFlag(OsdFlag.mini, true), isTrue);
    expect(await state.setPlayerButtonOrder(['next', 'play']), isTrue);
    expect(await state.setPlayerButtonHidden({'speed'}), isTrue);
    expect(await state.resetPlayerButtons(), isTrue);

    // 未 bootstrap 路径：store 为 null → false（不得谎报成功）。
    final bare = AppState(paths: state.paths, log: LogService());
    addTearDown(bare.dispose);
    expect(bare.setOsdFlag(OsdFlag.mini, true), completion(isFalse));
    expect(bare.setPlayerButtonOrder(['next']), completion(isFalse));
    expect(bare.setPlayerButtonHidden({'speed'}), completion(isFalse));
    expect(bare.resetPlayerButtons(), completion(isFalse));
  });
}
