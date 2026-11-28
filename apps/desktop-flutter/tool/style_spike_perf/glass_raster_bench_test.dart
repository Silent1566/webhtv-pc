// STYLE-SPIKE / THROWAWAY · 见 .superpowers/sdd/2026-11-26-style-spike/task-2/report.md
//
// 液态玻璃「视频纹理之上叠 BackdropFilter」代价 spike：本机可测的相对代价。
//
// 口径（先读口径再读数字）：
//   本用例在 flutter test（flutter_tester，headless，无真实 GPU swapchain）里
//   用 RepaintBoundary.toImage 对一个固定场景做一次完整光栅化，秒表包住这一次
//   调用。它量的是「CPU 侧光栅化这一个场景要多久」，**不是 GPU 帧时间**，
//   只能看趋势与相对倍数，不能当绝对值用。真机结论必须由
//   tool/style_spike_perf/glass_over_video.dart 在 Windows 上量。
//
// 场景：1280x720 的一帧，底层是一张解码后的真实位图（fixture_base.png），
// 上面按 N 块玻璃面板分别叠 1/4/9 块，每块 = ClipRect + BackdropFilter(blur) +
// 半透明染色层。视频纹理在本机无法合成（flutter_tester 没有 texture registry），
// 所以底图用静止位图代替——这对 blur 输入是最好情况，见 report 的不可验证清单。
//
// 跑法：
//   cd apps/desktop-flutter
//   ../../.tools/flutter/bin/flutter test tool/style_spike_perf/glass_raster_bench_test.dart \
//     --dart-define=SPIKE_SAMPLES=5 --dart-define=SPIKE_WARMUP=2
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const double frameWidth = 1280;
const double frameHeight = 720;

final GlobalKey _frameKey = GlobalKey();

int get _samples => const int.fromEnvironment('SPIKE_SAMPLES', defaultValue: 5);
int get _warmup => const int.fromEnvironment('SPIKE_WARMUP', defaultValue: 2);

/// 玻璃面板布局：N 块在 1280x720 上铺开。总覆盖面积随 N 变化，表里一并给出，
/// 免得把「变贵」误读成只跟块数有关。
List<Rect> _panels(int n) {
  const double w = frameWidth;
  const double h = frameHeight;
  switch (n) {
    case 0:
      return const <Rect>[];
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
  throw ArgumentError('unsupported panel count: $n');
}

double _coverage(int n) {
  final double area = _panels(n).fold<double>(
    0,
    (double sum, Rect r) => sum + r.width * r.height,
  );
  return area / (frameWidth * frameHeight) * 100;
}

class _BaseImagePainter extends CustomPainter {
  const _BaseImagePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    // BoxFit.cover：跟播放器 Video(fit: ...) 的常见取值一致。
    final double scale = (size.width / image.width) > (size.height / image.height)
        ? size.width / image.width
        : size.height / image.height;
    final double sw = size.width / scale;
    final double sh = size.height / scale;
    final Rect src = Rect.fromLTWH(
      (image.width - sw) / 2,
      (image.height - sh) / 2,
      sw,
      sh,
    );
    canvas.drawImageRect(
      image,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_BaseImagePainter oldDelegate) => oldDelegate.image != image;
}

/// [sigma] < 0 表示「只染色、完全不插 BackdropFilter」，用来把染色合成的固定成本
/// 从 blur 成本里分出来。
class _Frame extends StatelessWidget {
  const _Frame({required this.image, required this.panels, required this.sigma});

  final ui.Image image;
  final List<Rect> panels;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: _frameKey,
        child: SizedBox(
          width: frameWidth,
          height: frameHeight,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CustomPaint(painter: _BaseImagePainter(image)),
              for (final Rect r in panels)
                Positioned(
                  left: r.left,
                  top: r.top,
                  width: r.width,
                  height: r.height,
                  child: sigma < 0
                      ? const ColoredBox(color: Color(0x33FFFFFF))
                      : ClipRect(
                          child: BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                            child: const ColoredBox(color: Color(0x33FFFFFF)),
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Result {
  _Result(this.label, this.n, this.sigma, this.coverage, this.micros);

  final String label;
  final int n;
  final double sigma;
  final double coverage;
  final List<int> micros;

  List<int> get _sorted => List<int>.from(micros)..sort();

  double _pct(double p) {
    final List<int> s = _sorted;
    final int idx = (p / 100 * s.length).ceil() - 1;
    return s[idx.clamp(0, s.length - 1)] / 1000.0;
  }

  double get p50 => _pct(50);
  double get p95 => _pct(95);
  double get min => _sorted.first / 1000.0;
  double get max => _sorted.last / 1000.0;
  double get mean => micros.reduce((int a, int b) => a + b) / micros.length / 1000.0;
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  final ui.FrameInfo info = await codec.getNextFrame();
  return info.image;
}

void main() {
  final File fixture = File('tool/style_spike_perf/fixture_base.png');

  testWidgets('glass raster bench', (WidgetTester tester) async {
    expect(fixture.existsSync(), isTrue, reason: 'missing ${fixture.path}');

    tester.view.devicePixelRatio = 1.0;
    await tester.binding.setSurfaceSize(const Size(frameWidth, frameHeight));

    // flutter_test 里 image decode 走引擎 I/O 线程，必须在 runAsync 里等真异步，
    // 否则 Future 永不完成（假时钟不推进引擎任务）。
    final ui.Image base = (await tester.runAsync(() async => _decode(await fixture.readAsBytes())))!;
    stdout.writeln('=== STYLE-SPIKE raster bench (THROWAWAY) ===');
    stdout.writeln('engine_backend: flutter_tester / Skia CPU (no GPU swapchain)');
    stdout.writeln('dart: ${Platform.version.split(' ').first}  host: ${Platform.operatingSystem}');
    stdout.writeln('frame: ${frameWidth.toInt()}x${frameHeight.toInt()} @dpr 1.0');
    stdout.writeln('base_bitmap: ${fixture.path} decoded ${base.width}x${base.height}');
    stdout.writeln('samples: $_samples  warmup: $_warmup');
    stdout.writeln('metric: Stopwatch around RepaintBoundary.toImage(pixelRatio: 1.0)');

    final List<_Result> results = <_Result>[];
    final List<List<Object>> scenarios = <List<Object>>[
      <Object>['baseline', 0, 0.0],
      <Object>['tint_only', 9, -1.0],
      for (final int n in <int>[1, 4, 9])
        for (final double s in <double>[0, 12, 24, 40]) <Object>['glass', n, s],
    ];

    for (final List<Object> sc in scenarios) {
      final String label = sc[0] as String;
      final int n = sc[1] as int;
      final double sigma = sc[2] as double;
      await tester.pumpWidget(
        _Frame(image: base, panels: _panels(n), sigma: sigma),
      );
      await tester.pump();

      final RenderRepaintBoundary boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_frameKey),
      );

      for (int i = 0; i < _warmup; i++) {
        final ui.Image img = await boundary.toImage(pixelRatio: 1.0);
        img.dispose();
      }

      final List<int> micros = <int>[];
      for (int i = 0; i < _samples; i++) {
        final Stopwatch sw = Stopwatch()..start();
        final ui.Image img = await boundary.toImage(pixelRatio: 1.0);
        sw.stop();
        img.dispose();
        micros.add(sw.elapsedMicroseconds);
      }
      results.add(_Result(label, n, sigma, _coverage(n), micros));
      stdout.writeln('measured $label N=$n sigma=${sigma.toStringAsFixed(1)}');
    }

    stdout.writeln('');
    stdout.writeln(
      'label\tN\tblur_sigma\tcovered_pct\tmin_ms\tp50_ms\tp95_ms\tmax_ms\tmean_ms'
      '\tdelta_p50_ms\tp50_x_baseline',
    );
    final double baseP50 = results.first.p50;
    for (final _Result r in results) {
      stdout.writeln(
        '${r.label}\t${r.n}\t${r.sigma.toStringAsFixed(1)}'
        '\t${r.coverage.toStringAsFixed(1)}'
        '\t${r.min.toStringAsFixed(2)}\t${r.p50.toStringAsFixed(2)}'
        '\t${r.p95.toStringAsFixed(2)}\t${r.max.toStringAsFixed(2)}'
        '\t${r.mean.toStringAsFixed(2)}'
        '\t${(r.p50 - baseP50).toStringAsFixed(2)}'
        '\t${baseP50 == 0 ? 'n/a' : (r.p50 / baseP50).toStringAsFixed(2)}',
      );
    }
    stdout.writeln('');
    stdout.writeln('NOTE: CPU software raster in flutter_tester — NOT GPU frame time.');

    base.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
