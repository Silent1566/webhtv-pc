// STYLE-SPIKE / THROWAWAY · 见 .superpowers/sdd/2026-11-26-style-spike/task-2/report.md
//
// 液态玻璃「视频纹理之上叠 BackdropFilter」的真机量化台（Windows）。
// 本机（Linux 缺 GTK/pkg-config）起不来，只做过 flutter analyze；真数字在 Windows 上取。
//
// 它做什么：
//   1. 用 media_kit 播本地视频——走的是 player_page.dart:4866 那套同一个 Video widget，
//      底层是 media_kit_video 的 Texture(...)（video_texture.dart:420）；
//   2. 在视频之上叠 N 块玻璃面板（ClipRect + BackdropFilter(blur sigma) + 半透明染色）；
//   3. 每 5 秒把 SchedulerBinding.addTimingsCallback 收到的帧时间打印一次 p50/p95，
//      分 build（UI 线程）/ raster（光栅线程）/ total（帧总时长）。
//
// 跑法（在 apps/desktop-flutter 下，Windows）：
//   flutter run -t tool/style_spike_perf/glass_over_video.dart -d windows --profile \
//     --dart-define=SPIKE_VIDEO=C:\path\to\gop-2s.mp4
//   可选：--dart-define=SPIKE_GLASS=0|1|4|9  --dart-define=SPIKE_SIGMA=0|12|24|40
//         --dart-define=SPIKE_EVERY_MS=5000
//
// 运行时按键（切换时立刻清窗，下一行数字只属于新配置）：
//   0 = 无玻璃（基线）  1 / 4 / 9 = 玻璃块数  B = 开关玻璃（保留块数）
//   [ ] = 调 blur sigma（0 -> 12 -> 24 -> 40 -> 0）
//
// 判读：raster 恒为 0 说明这次运行把光栅化并进了 UI 线程（桌面常见），此时看 total。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const String _videoPath = String.fromEnvironment('SPIKE_VIDEO', defaultValue: '');
const int _initialGlass = int.fromEnvironment('SPIKE_GLASS', defaultValue: 4);
const int _initialSigmaRaw = int.fromEnvironment('SPIKE_SIGMA', defaultValue: 24);
const int _windowMs = int.fromEnvironment('SPIKE_EVERY_MS', defaultValue: 5000);

const List<double> _sigmaSteps = <double>[0, 12, 24, 40];
const Color _tint = Color(0x33FFFFFF);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const SpikeApp());
}

/// 面板布局：与 tool/style_spike_perf/glass_raster_bench_test.dart 同一套几何，
/// 这样两台机器上的「N 块玻璃」指同一件事。
List<Rect> panelLayout(int n, Size size) {
  final double w = size.width;
  final double h = size.height;
  switch (n) {
    case 1:
      return <Rect>[Rect.fromLTWH(w * 0.20, h * 0.25, w * 0.60, h * 0.50)];
    case 4:
      const double m = 0.05;
      const double g = 0.04;
      final double cw = (w * (1 - 2 * m - g)) / 2;
      final double ch = (h * (1 - 2 * m - g)) / 2;
      return <Rect>[
        for (int r = 0; r < 2; r++)
          for (int c = 0; c < 2; c++)
            Rect.fromLTWH(
              w * m + c * (cw + w * g),
              h * m + r * (ch + h * g),
              cw,
              ch,
            ),
      ];
    case 9:
      const double m = 0.04;
      const double g = 0.025;
      final double cw = (w * (1 - 2 * m - 2 * g)) / 3;
      final double ch = (h * (1 - 2 * m - 2 * g)) / 3;
      return <Rect>[
        for (int r = 0; r < 3; r++)
          for (int c = 0; c < 3; c++)
            Rect.fromLTWH(
              w * m + c * (cw + w * g),
              h * m + r * (ch + h * g),
              cw,
              ch,
            ),
      ];
  }
  return const <Rect>[];
}

double percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final int idx = (p / 100 * sorted.length).ceil() - 1;
  return sorted[idx.clamp(0, sorted.length - 1)];
}

class FrameWindow {
  FrameWindow(this.glass, this.sigma, this.glassOn);

  final int glass;
  final double sigma;
  final bool glassOn;

  final List<double> build = <double>[];
  final List<double> raster = <double>[];
  final List<double> total = <double>[];

  int get frames => total.length;
  bool get isEmpty => total.isEmpty;

  void add(FrameTiming t) {
    build.add(t.buildDuration.inMicroseconds / 1000.0);
    raster.add(t.rasterDuration.inMicroseconds / 1000.0);
    total.add(t.totalSpan.inMicroseconds / 1000.0);
  }

  String report(Duration elapsed) {
    final List<double> b = List<double>.from(build)..sort();
    final List<double> r = List<double>.from(raster)..sort();
    final List<double> tt = List<double>.from(total)..sort();
    final bool rasterZero = r.isNotEmpty && r.last == 0;
    final String sec = (elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    final String sig = sigma.toStringAsFixed(0);
    final String bp50 = percentile(b, 50).toStringAsFixed(2);
    final String bp95 = percentile(b, 95).toStringAsFixed(2);
    final String rp50 = percentile(r, 50).toStringAsFixed(2);
    final String rp95 = percentile(r, 95).toStringAsFixed(2);
    final String tp50 = percentile(tt, 50).toStringAsFixed(2);
    final String tp95 = percentile(tt, 95).toStringAsFixed(2);
    final String cfg = glassOn ? 'glass=$glass sigma=$sig' : 'glass=OFF(baseline)';
    final String tail = rasterZero ? '  <- raster 恒为 0：光栅化并进了 UI 线程，请读 total' : '';
    return '[SPIKE] t=$sec s $cfg frames=$frames '
        'build p50=$bp50 p95=$bp95 | '
        'raster p50=$rp50 p95=$rp95 | '
        'total p50=$tp50 p95=$tp95 ms$tail';
  }
}

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});

  @override
  State<SpikeApp> createState() => SpikeAppState();
}

class SpikeAppState extends State<SpikeApp> {
  Player? _player;
  VideoController? _controller;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  late final TimingsCallback _onTimings = _collect;
  FrameWindow _window = FrameWindow(_initialGlass, _initialSigmaRaw.toDouble(), _initialGlass > 0);
  FrameWindow? _last;
  int _glass = _initialGlass;
  double _sigma = _initialSigmaRaw.toDouble();
  bool _glassOn = _initialGlass > 0;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    if (_videoPath.isEmpty) {
      _fatal = '缺 --dart-define=SPIKE_VIDEO=<本地视频绝对路径>';
      return;
    }
    if (!File(_videoPath).existsSync()) {
      _fatal = '视频不存在：$_videoPath';
      return;
    }
    final Player player = Player();
    _player = player;
    _controller = VideoController(player);
    _clock.start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(Duration(milliseconds: _windowMs), (_) => _flush());
    unawaited(() async {
      await player.setPlaylistMode(PlaylistMode.single);
      await player.open(Media(_videoPath), play: true);
    }());
  }

  @override
  void dispose() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _player?.dispose();
    super.dispose();
  }

  void _collect(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      _window.add(t);
    }
  }

  void _flush() {
    if (_window.isEmpty) return;
    _last = _window;
    stdout.writeln(_window.report(_clock.elapsed));
    _window = FrameWindow(_glass, _sigma, _glassOn);
  }

  void _change({int? glass, double? sigma, bool? on}) {
    _flush();
    setState(() {
      if (glass != null) {
        _glass = glass;
        _glassOn = glass > 0;
      }
      if (sigma != null) _sigma = sigma;
      if (on != null) _glassOn = on;
    });
    _window = FrameWindow(_glass, _sigma, _glassOn);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey k = event.logicalKey;
    if (k == LogicalKeyboardKey.digit0) {
      _change(glass: 0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit1) {
      _change(glass: 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit4) {
      _change(glass: 4);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit9) {
      _change(glass: 9);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyB) {
      _change(on: !_glassOn);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.bracketLeft || k == LogicalKeyboardKey.bracketRight) {
      final int i = _sigmaSteps.indexOf(_sigma);
      final int next = k == LogicalKeyboardKey.bracketRight
          ? (i + 1) % _sigmaSteps.length
          : (i - 1 + _sigmaSteps.length) % _sigmaSteps.length;
      _change(sigma: _sigmaSteps[next]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final VideoController? controller = _controller;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _fatal != null || controller == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _fatal ?? '正在初始化视频控制器…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                )
              : Column(
                  children: <Widget>[
                    Expanded(
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints c) {
                          final Size size = Size(c.maxWidth, c.maxHeight);
                          final List<Rect> panels =
                              _glassOn ? panelLayout(_glass, size) : const <Rect>[];
                          return Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              Video(
                                controller: controller,
                                controls: NoVideoControls,
                                fit: BoxFit.cover,
                              ),
                              for (final Rect r in panels)
                                Positioned(
                                  left: r.left,
                                  top: r.top,
                                  width: r.width,
                                  height: r.height,
                                  child: ClipRect(
                                    child: BackdropFilter(
                                      filter: ui.ImageFilter.blur(
                                        sigmaX: _sigma,
                                        sigmaY: _sigma,
                                      ),
                                      child: const ColoredBox(color: _tint),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    _Hud(hint: _hint(), last: _last, windowMs: _windowMs),
                  ],
                ),
        ),
      ),
    );
  }

  String _hint() {
    final String sig = _sigma.toStringAsFixed(0);
    return _glassOn ? 'glass=$_glass sigma=$sig' : 'glass=OFF (baseline)';
  }
}

class _Hud extends StatelessWidget {
  const _Hud({required this.hint, required this.last, required this.windowMs});

  final String hint;
  final FrameWindow? last;
  final int windowMs;

  @override
  Widget build(BuildContext context) {
    final FrameWindow? w = last;
    String stats = '等待首个 $windowMs ms 窗口…';
    if (w != null && !w.isEmpty) {
      final List<double> r = List<double>.from(w.raster)..sort();
      final String p50 = percentile(r, 50).toStringAsFixed(2);
      final String p95 = percentile(r, 95).toStringAsFixed(2);
      stats = '上一窗口 raster p50=$p50 p95=$p95 ms';
    }
    return ColoredBox(
      color: Colors.black,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          children: <Widget>[
            Text(hint, style: const TextStyle(color: Colors.white, fontSize: 12)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                stats,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            const Text(
              '0=基线 1/4/9=块数 B=开关 [ ]=sigma',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
