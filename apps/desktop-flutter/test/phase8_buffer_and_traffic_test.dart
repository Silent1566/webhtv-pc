import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_controller.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: Center(child: child)),
);

/// 取组件树里那个滑杆，用于断言缓冲段的值。
Slider sliderOf(WidgetTester tester) => tester.widget<Slider>(
  find.descendant(
    of: find.byType(PlayerProgressSlider),
    matching: find.byType(Slider),
  ),
);

/// 相对亮度（WCAG 2.x 定义）。
double _relativeLuminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// 两色的对比度（1..21）。**算出来而不是钉死角色名**：换色可以，看不清不行。
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('formatByteRate：屏显网速的格式化（纯函数）', () {
    test('MB/s 段：保留一位小数', () {
      expect(formatByteRate(12.8 * 1000 * 1000), '12.8 MB/s');
      expect(formatByteRate(1.0 * 1000 * 1000), '1.0 MB/s');
      // 恰好 1000 000 是 MB 段的下界（不是 KB 段的 1000 KB/s）。
      expect(formatByteRate(999999), '1000 KB/s');
    });

    test('KB/s 段：取整，不带小数', () {
      expect(formatByteRate(860 * 1000.0), '860 KB/s');
      // 1000 字节 = 1 KB/s（1000 进制，与运营商口径一致）。
      expect(formatByteRate(1000), '1 KB/s');
      expect(formatByteRate(860300), '860 KB/s', reason: '小数位是假精度');
    });

    test('B/s 段：不足 1 KB 时用字节', () {
      expect(formatByteRate(0), '0 B/s');
      expect(formatByteRate(999), '999 B/s');
    });

    test('null / 非有限 / 负值 → 长破折号（不是 0）', () {
      // 这是本轮的核心语义：取不到值必须如实显示「没有」，
      // 显示 0 会被读成「网速为零 → 卡了」，与事实相反。
      expect(formatByteRate(null), '—');
      expect(formatByteRate(double.nan), '—');
      expect(formatByteRate(double.infinity), '—');
      expect(formatByteRate(-1), '—');
      // 反向锁：0 是**合法**读数，不能和「取不到」混为一谈。
      expect(formatByteRate(0), isNot('—'));
    });
  });

  group('parseByteRate：mpv raw-input-rate 的解析', () {
    test('正常浮点', () {
      expect(parseByteRate('12800000.0'), 12800000.0);
      expect(parseByteRate(' 860000 '), 860000.0, reason: '两侧空白要忽略');
      expect(parseByteRate('0'), 0.0);
    });

    test('空串 / nan / inf / 负数 → null', () {
      // media_kit 的 getProperty 在属性取不到时返回空串
      // （native/player/real.dart:1278），那是「没数据」而不是 0。
      expect(parseByteRate(''), isNull);
      expect(parseByteRate('   '), isNull);
      expect(parseByteRate(null), isNull);
      expect(parseByteRate('nan'), isNull);
      expect(parseByteRate('inf'), isNull);
      expect(parseByteRate('-5'), isNull);
      expect(parseByteRate('abc'), isNull);
    });
  });

  // 下面几条是**运行时实测**拿到的 mpv `demuxer-cache-state` 原串
  // （dart:ffi 直接加载 libmpv-2.dll、限速本地源播放时打印出来的），
  // 不是手写样例：解析函数的唯一价值就是吃这一串。
  group('parseRawInputRateFromCacheState：真实的 demuxer-cache-state', () {
    // 实测量：raw-input-rate = 9144（字节/秒，≈9 KB/s）。
    const realCacheState9144 =
        '{"cache-end":2.786395,"reader-pts":0.743039,"cache-duration":2.043356,'
        '"eof":false,"underrun":false,"idle":false,"total-bytes":284112,'
        '"fw-bytes":203456,"raw-input-rate":9144,"debug-low-level-seeks":0,'
        '"debug-byte-level-seeks":0,"debug-ts-last":2.786395,"bof-cached":true,'
        '"eof-cached":false,"seekable-ranges":[{"start":0.000000,'
        '"end":2.739955}]}';

    // 下面两条是**重跑同一份探测脚本**（tool/probe_mpv_props.dart，限速到
    // 8192 B / 60ms 的本地源）当场打印的完整原串，逐字粘贴。
    const realCacheState9012 =
        '{"cache-end":2.600635,"reader-pts":0.603719,"cache-duration":1.996916,'
        '"eof":false,"underrun":false,"idle":false,"total-bytes":265616,'
        '"fw-bytes":198832,"raw-input-rate":9012,"debug-low-level-seeks":0,'
        '"debug-byte-level-seeks":0,"debug-ts-last":2.600635,"bof-cached":true,'
        '"eof-cached":false,"seekable-ranges":[{"start":0.000000,'
        '"end":2.554195}]}';

    const realCacheState131341 =
        '{"cache-end":5.572789,"reader-pts":2.600635,"cache-duration":2.972154,'
        '"eof":false,"underrun":false,"idle":false,"total-bytes":561552,'
        '"fw-bytes":295936,"raw-input-rate":131341,"debug-low-level-seeks":0,'
        '"debug-byte-level-seeks":0,"debug-ts-last":5.572789,"bof-cached":true,'
        '"eof-cached":false,"seekable-ranges":[{"start":0.000000,'
        '"end":5.526349}]}';

    // 132086 那组量来自上游报告的实测输出，但原行中间字段被省略成「…」；
    // 这里只保留当时确实打印出来的 4 个字段（其余字段值没有证据就不写），
    // 因此没有一个数值是编的。
    const realCacheState132086 =
        '{"cache-end":5.85,"total-bytes":589296,"fw-bytes":309808,'
        '"raw-input-rate":132086}';

    test('从真实原串取出 9144', () {
      expect(parseRawInputRateFromCacheState(realCacheState9144), 9144.0);
    });

    test('从真实原串取出 9012 / 131341 / 132086', () {
      expect(parseRawInputRateFromCacheState(realCacheState9012), 9012.0);
      expect(parseRawInputRateFromCacheState(realCacheState131341), 131341.0);
      expect(parseRawInputRateFromCacheState(realCacheState132086), 132086.0);
    });

    test('缓存填充过程中 74706 这一拍也能逐字取到', () {
      // 同一段播放 t2 的完整原串（探测脚本第三次打印），证明相邻两拍都能取。
      const realCacheState74706 =
          '{"cache-end":4.086712,"reader-pts":1.578957,"cache-duration":2.507755,'
          '"eof":false,"underrun":false,"idle":false,"total-bytes":413584,'
          '"fw-bytes":249696,"raw-input-rate":74706,"debug-low-level-seeks":0,'
          '"debug-byte-level-seeks":0,"debug-ts-last":4.086712,"bof-cached":true,'
          '"eof-cached":false,"seekable-ranges":[{"start":0.000000,'
          '"end":4.040272}]}';
      expect(parseRawInputRateFromCacheState(realCacheState74706), 74706.0);
    });

    test('字段前后还有别的键时不串味', () {
      // 值必须**恰好**停在 9144：后面紧跟 `,"debug-low-level-seeks":0`，
      // 若取值边界写漏了会把后续字段一起吞进来（得到 91440 之类）。
      expect(parseRawInputRateFromCacheState(realCacheState9144), 9144.0);
      // seekable-ranges 里的 start/end 不能被误当成速率。
      expect(
        parseRawInputRateFromCacheState(
          '{"seekable-ranges":[{"start":0.0,"end":2.7}],"raw-input-rate":4096}',
        ),
        4096.0,
      );
    });

    test('缓存建立前为 null / 空串 → null（下一拍重试）', () {
      // 实测：起播头 1 秒内该属性返回 NULL（getProperty 给空串）。
      expect(parseRawInputRateFromCacheState(null), isNull);
      expect(parseRawInputRateFromCacheState(''), isNull);
      expect(parseRawInputRateFromCacheState('   '), isNull);
    });

    test('没有该键 / 值为 null / 值非数字 / 键名相近 → null', () {
      expect(parseRawInputRateFromCacheState('{"cache-end":1.0}'), isNull);
      expect(
        parseRawInputRateFromCacheState('{"raw-input-rate":null}'),
        isNull,
      );
      expect(
        parseRawInputRateFromCacheState('{"raw-input-rate":"abc"}'),
        isNull,
      );
      // 键名相近但不同的不得命中（正则要求右引号紧跟 rate）。
      expect(
        parseRawInputRateFromCacheState('{"raw-input-rate-foo":1}'),
        isNull,
      );
      expect(
        parseRawInputRateFromCacheState('{"xraw-input-rate":1}'),
        isNull,
      );
    });
  });

  group('resolveNetworkRate：双数据源的回退顺序', () {
    // sampleNetworkRate 依赖真引擎跑不了，所以把它这一拍的合成逻辑抽成
    // 纯函数 resolveNetworkRate 来断言顺序；调用点逐字使用它。
    test('首选有值 → 用首选，回退值即使给了也不采纳', () {
      expect(resolveNetworkRate(9144, '130786'), 9144.0);
    });

    test('首选为空串（缓存未建立）→ 回退 cache-speed 的 130786', () {
      // 完整复现那一拍：先读 demuxer-cache-state 拿到空串 → 解析出 null
      // → 再去读 cache-speed 拿到 "130786"。
      final primary = parseRawInputRateFromCacheState('');
      expect(primary, isNull);
      expect(resolveNetworkRate(primary, '130786'), 130786.0);
    });

    test('两个都取不到 → null（屏显显示 —，不是 0）', () {
      expect(resolveNetworkRate(null, null), isNull);
      expect(resolveNetworkRate(null, ''), isNull);
      expect(resolveNetworkRate(null, 'nan'), isNull);
    });
  });

  group('缓冲条：拖动前画、无数据不画', () {
    Widget build({
      Duration position = const Duration(minutes: 1),
      Duration buffered = const Duration(minutes: 3),
      Duration duration = const Duration(minutes: 10),
    }) => wrap(
      SizedBox(
        width: 400,
        height: 32,
        child: PlayerProgressSlider(
          position: position,
          duration: duration,
          buffered: buffered,
          onSeek: (_) {},
        ),
      ),
    );

    testWidgets('buffered > position 时渲染缓冲段', (tester) async {
      await tester.pumpWidget(build());
      // 3 分钟 = 180000ms：断言的是**真实取到 buffered**，不是写死的值。
      expect(sliderOf(tester).secondaryTrackValue, 180000.0);
    });

    testWidgets('buffered == 0（未缓冲）时不渲染缓冲段', (tester) async {
      await tester.pumpWidget(build(buffered: Duration.zero));
      expect(
        sliderOf(tester).secondaryTrackValue,
        isNull,
        reason: '未缓冲时传 0 会画出一条被钳成零宽的条，应当不画',
      );
    });

    testWidgets('buffered 落后于播放位置时也不渲染（不画负数长度的条）', (tester) async {
      await tester.pumpWidget(
        build(
          position: const Duration(minutes: 5),
          buffered: const Duration(minutes: 2),
        ),
      );
      expect(sliderOf(tester).secondaryTrackValue, isNull);
    });

    testWidgets('直播（duration <= 0）时跳过缓冲段', (tester) async {
      await tester.pumpWidget(
        build(
          position: Duration.zero,
          buffered: const Duration(minutes: 3),
          duration: Duration.zero,
        ),
      );
      expect(sliderOf(tester).secondaryTrackValue, isNull);
      expect(sliderOf(tester).onChanged, isNull, reason: '直播不可 seek');
    });

    testWidgets('缓冲段颜色与未播放轨道有足够对比度，且不与已播放段抢注意力', (tester) async {
      await tester.pumpWidget(build());
      final scheme = buildAppTheme(Brightness.dark).colorScheme;
      final buffered = sliderOf(tester).secondaryActiveColor;

      // 1) 不能是已播放段的琥珀：那会被读成"已经放到那儿了"。
      expect(
        buffered,
        isNot(scheme.primary),
        reason: '缓冲段是背景信息，不能用主色抢播放进度的注意力',
      );

      // 2) 必须真的看得见。初版取 `outline`，在 `surfaceContainerHighest`
      //    轨道上算出来只有 1.25:1（用户反馈"基本看不清"），所以这里**算**
      //    对比度而不是钉死某个角色名——换色可以，看不清不行。
      expect(buffered, isNotNull, reason: '缓冲段必须有明确的颜色');
      final ratio = _contrastRatio(buffered!, scheme.surfaceContainerHighest);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            '缓冲段对未播放轨道的对比度必须过 WCAG AA 4.5:1（实测 '
            '${ratio.toStringAsFixed(2)}:1）',
      );
    });

    testWidgets('拖动期间不画缓冲段，松手后恢复', (tester) async {
      await tester.pumpWidget(build());
      expect(sliderOf(tester).secondaryTrackValue, isNotNull);

      // 按住并移动后**不松手**：此时拇指代表"用户想去的地方"，
      // 缓冲段仍指向"引擎已经拿到的地方"，两者同画会被读成"已被覆盖"。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider)),
      );
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(
        sliderOf(tester).secondaryTrackValue,
        isNull,
        reason: '拖动中不得画缓冲段',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        sliderOf(tester).secondaryTrackValue,
        isNotNull,
        reason: '松手后缓冲段必须回来',
      );
    });
  });

  group('缓冲中提示：与加载态互斥', () {
    test('showBufferingIndicator 只有"缓冲中且不在加载"为真', () {
      expect(showBufferingIndicator(isBuffering: true, isLoading: false), isTrue);
      expect(
        showBufferingIndicator(isBuffering: true, isLoading: true),
        isFalse,
        reason: '加载阶段已有全屏 LoadingBlock，再叠一个就是两个圈',
      );
      expect(showBufferingIndicator(isBuffering: false, isLoading: true), isFalse);
      expect(showBufferingIndicator(isBuffering: false, isLoading: false), isFalse);
    });

    testWidgets('有百分比时环中显示数字', (tester) async {
      await tester.pumpWidget(wrap(const PlayerBufferingIndicator(percent: 42)));
      expect(find.text('42%'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('无百分比时只有环，没有数字', (tester) async {
      await tester.pumpWidget(wrap(const PlayerBufferingIndicator()));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PlayerBufferingIndicator),
          matching: find.byType(Text),
        ),
        findsNothing,
        reason: '没有数据就不该显示 "0%"（那是"卡死在零"的误读）',
      );
    });

    testWidgets('不吃指针：点击穿透到下层', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: Stack(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox.expand(),
                ),
                const Positioned.fill(
                  child: PlayerBufferingIndicator(percent: 50),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tapAt(const Offset(400, 300));
      expect(taps, 1, reason: '缓冲提示不得挡住画面手势');
    });
  });
}
