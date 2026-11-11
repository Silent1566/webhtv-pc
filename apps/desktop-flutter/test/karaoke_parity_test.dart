import 'package:flutter_test/flutter_test.dart';

import 'karaoke_algorithm_probe.dart' as algorithm;
import 'karaoke_controller_probe.dart' as controller;
import 'karaoke_repository_fixture.dart' as repository;
import 'karaoke_replace_probe.dart' as replacement;
import 'karaoke_pause_probe.dart' as pause;

void main() {
  // 直接执行同一组独立期望断言；不启动脚本进程、不打开真实设备或调用远程服务。
  test('PCM YIN、参考轨、半音八度静音、预热、延迟、自由唱与颤音合同', algorithm.main);
  test('仓库身份、UltraStar/MIDI、本地响应、生成轨与持久备份合同', repository.main);
  test('控制器合成PCM计分、暂停停止、seek代际、不可用麦与默认生产适配合同', controller.main);
  test('用户轨完整预验证、精确替换、空集合、缓存保留与备份回滚合同', replacement.main);
  test(
    '用户评分暂停与媒体播放双闸门、保留旧分并精确恢复合同',
    pause.main,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
