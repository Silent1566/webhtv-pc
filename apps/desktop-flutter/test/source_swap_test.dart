/// 换源合并规则。这些断言是「并入后的线路还能不能播」的第一道闸门：
/// flag 必须页面内唯一，playbackFlag 必须仍然指向原站点自己的线路标识。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_swap.dart';

VodPlayLine _line(String flag, {String? sourceFlag, int episodes = 1}) {
  return VodPlayLine(
    flag: flag,
    sourceFlag: sourceFlag,
    episodes: [
      for (var i = 1; i <= episodes; i += 1)
        VodEpisode(name: '第$i集', url: 'https://example.test/$flag/$i'),
    ],
  );
}

void main() {
  group('externalLineFlag', () {
    test('taken 为空时就是「站点名 · 原线路名」', () {
      final taken = <String>{};
      expect(
        externalLineFlag(siteName: '示例站', lineFlag: '高清', taken: taken),
        '示例站 · 高清',
      );
      // 只读语义：单算一个 flag 不该污染 taken。
      expect(taken, isEmpty);
    });

    test('重名依次得到 (2)、(3) 后缀', () {
      final taken = <String>{'示例站 · 高清'};
      final second = externalLineFlag(
        siteName: '示例站',
        lineFlag: '高清',
        taken: taken,
      );
      expect(second, '示例站 · 高清 (2)');

      taken.add(second);
      final third = externalLineFlag(
        siteName: '示例站',
        lineFlag: '高清',
        taken: taken,
      );
      expect(third, '示例站 · 高清 (3)');
    });

    test('中间序号被占用时跳过它继续找空位', () {
      final taken = <String>{'A · 高清', 'A · 高清 (3)'};
      expect(
        externalLineFlag(siteName: 'A', lineFlag: '高清', taken: taken),
        'A · 高清 (2)',
      );
    });

    test('空线路名回落成「线路」，不留下悬空的中点', () {
      expect(
        externalLineFlag(siteName: 'A', lineFlag: '  ', taken: <String>{}),
        'A · 线路',
      );
    });
  });

  group('externalPlayLine', () {
    test('flag 走「站点名 · 原线路名」，sourceFlag 保留原 playbackFlag', () {
      final taken = <String>{};
      final line = _line('高清', episodes: 3);

      final wrapped = externalPlayLine(
        siteName: '示例站',
        line: line,
        taken: taken,
      );

      expect(wrapped.flag, '示例站 · 高清');
      // 契约核心：展示名与播放标识分离。
      expect(line.playbackFlag, '高清');
      expect(wrapped.sourceFlag, line.playbackFlag);
      expect(wrapped.sourceFlag, '高清');
      expect(wrapped.playbackFlag, '高清');
      // 分集原样带过，不复制、不改写。
      expect(wrapped.episodes, same(line.episodes));
      // 新 flag 落进 taken，后续并入才能接上序号。
      expect(taken, <String>{'示例站 · 高清'});
    });

    test('原线路自带 sourceFlag 时，并入后仍指向原 sourceFlag', () {
      final taken = <String>{};
      final line = _line('线路一', sourceFlag: 'real-line-flag');

      final wrapped = externalPlayLine(
        siteName: 'A 站',
        line: line,
        taken: taken,
      );

      expect(wrapped.flag, 'A 站 · 线路一');
      expect(wrapped.sourceFlag, 'real-line-flag');
      expect(wrapped.playbackFlag, 'real-line-flag');
    });

    test('同一站点的同名线路连续并入，flag 依次去重', () {
      final taken = <String>{};
      final flags = <String>[
        for (var i = 0; i < 3; i += 1)
          externalPlayLine(
            siteName: 'A 站',
            line: _line('高清'),
            taken: taken,
          ).flag,
      ];

      expect(flags, <String>['A 站 · 高清', 'A 站 · 高清 (2)', 'A 站 · 高清 (3)']);
      expect(taken, <String>{'A 站 · 高清', 'A 站 · 高清 (2)', 'A 站 · 高清 (3)'});
    });
  });
}
