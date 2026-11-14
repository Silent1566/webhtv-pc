import 'dart:math' as math;
import 'dart:typed_data';
import 'models.dart';

class YinPitchDetector {
  YinPitchDetector(this.sampleRate, {this.sampleSize = 2048, this.threshold = .1, this.minConfidence = .1});
  final int sampleRate, sampleSize;
  final double threshold, minConfidence;
  KaraokePitchSample detect(Float32List input, {required int timestampMs}) {
    final n = math.min(input.length, sampleSize);
    var power = 0.0;
    for (var i=0;i<n;i++) { if (!input[i].isFinite) return KaraokePitchSample(timestampMs: timestampMs, frequencyHz: 0, volume: 0, confidence: 0); power += input[i]*input[i]; }
    final volume = n == 0 ? 0.0 : math.sqrt(power / n).clamp(0.0,1.0);
    KaraokePitchSample empty() => KaraokePitchSample(timestampMs: timestampMs, frequencyHz: 0, volume: volume, confidence: 0);
    if (n < 128 || sampleRate <= 0 || power < 1e-12) return empty();
    final size = n ~/ 2;
    final yin = Float64List(size);
    var running = 0.0;
    yin[0] = 1;
    for (var tau=1;tau<size;tau++) {
      var sum=0.0;
      for (var i=0;i<n-size+1;i++) { final d=input[i]-input[i+tau]; sum+=d*d; }
      running+=sum;
      yin[tau]=running<=0 ? 1 : sum*tau/running;
    }
    for (var tau=2;tau<size;tau++) {
      if (yin[tau]>=threshold.clamp(.01,.9)) continue;
      while(tau+1<size && yin[tau+1]<yin[tau]) { tau++; }
      final confidence=(1-yin[tau]).clamp(0.0,1.0);
      if (confidence<minConfidence) return empty();
      var better=tau.toDouble();
      if (tau>0 && tau+1<size) {
        final denominator=2*(2*yin[tau]-yin[tau+1]-yin[tau-1]);
        if (denominator.abs()>1e-9) better+=(yin[tau+1]-yin[tau-1])/denominator;
      }
      return KaraokePitchSample(timestampMs: timestampMs, frequencyHz: sampleRate/better, volume: volume, confidence: confidence);
    }
    return empty();
  }
}
