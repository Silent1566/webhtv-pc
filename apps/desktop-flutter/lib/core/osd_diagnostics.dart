/// 屏显诊断面板的取数层（`docs/phase8/design/02` §3.2）。
///
/// **纯函数**：输入是一组已经取好的原始值，输出是可渲染的行。
/// 之所以不直接吃 `PlayerController`：那样这个文件就要依赖 Flutter 与
/// media_kit，无法单测；而且媒体信息对话框（`_showMediaInfo`）需要**同一批数据**，
/// 两处必须调用同一个函数，否则会漂移（`docs/phase8/design/02` §6）。
///
/// 纪律：拿不到的字段显示「未知」，**不得**填 0 或用平均值假装
/// （`PRODUCT.md` §Product Principles 第 2 条「失败必须如实」）。
library;

/// 诊断面板的一行。
class OsdDiagnosticsRow {
  const OsdDiagnosticsRow(this.label, this.value);

  final String label;
  final String value;
}

String _duration(Duration value) {
  final total = value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

String _bitrate(num? bitsPerSecond) {
  if (bitsPerSecond == null || bitsPerSecond <= 0) return '未知';
  final bits = bitsPerSecond.toDouble();
  if (bits >= 1000000) return '${(bits / 1000000).toStringAsFixed(1)} Mbps';
  if (bits >= 1000) return '${(bits / 1000).toStringAsFixed(0)} Kbps';
  return '${bits.toStringAsFixed(0)} bps';
}

/// 主列：结论 / 视频 / 音频 / 网络 / 状态 / 播放 / 来源。
///
/// 顺序固定，便于截图复核与断言。结论与来源是条件行：前者在
///「还没有结论」时省略，后者在三个来源字段都拿不到时省略。
List<OsdDiagnosticsRow> buildOsdDiagnostics({
  required int? videoWidth,
  required int? videoHeight,
  required String? videoCodec,
  required double? videoFps,
  required num? videoBitrate,
  required String? audioCodec,
  required String? audioChannels,
  required int? audioSampleRate,
  required num? audioBitrate,
  required Duration position,
  required Duration duration,
  required Duration buffered,
  required double rate,
  required double volume,
  required bool muted,
  required String formatLabel,
  required String targetHost,
  required String? siteKey,
  required String? flag,
  required String? episodeName,
  // 结论行（`design/02` §3.2 主列表格的**第一行**）。
  // `succeeded == null` 表示「还没有结论」（例如刚起播），此时**不渲染该行**。
  required bool? succeeded,
  required Object? failureKind,
}) {
  final hasSize = videoWidth != null && videoHeight != null &&
      videoWidth > 0 && videoHeight > 0;
  final video = [
    if (videoCodec != null && videoCodec.isNotEmpty) videoCodec else '未知',
    if (hasSize) '$videoWidth×$videoHeight',
    if (videoFps != null && videoFps > 0) '${videoFps.toStringAsFixed(2)} fps',
    if (videoBitrate != null && videoBitrate > 0) _bitrate(videoBitrate),
  ].join(' · ');

  final audio = [
    if (audioCodec != null && audioCodec.isNotEmpty) audioCodec else '未知',
    if (audioChannels != null && audioChannels.isNotEmpty) audioChannels,
    if (audioSampleRate != null && audioSampleRate > 0) '$audioSampleRate Hz',
    if (audioBitrate != null && audioBitrate > 0) _bitrate(audioBitrate),
  ].join(' · ');

  final network = [
    formatLabel,
    if (targetHost.isNotEmpty) targetHost,
  ].join(' · ');

  // 直播（duration <= 0）没有总时长，进度无意义 —— 不显示 `00:00 / 00:00`。
  // 上游同语义：`PlayerOsdController.java:280` 的 `player.isLive()` 判定。
  final state = duration > Duration.zero
      ? '${_duration(position)} / ${_duration(duration)} · 缓冲 ${_duration(buffered)}'
      : '直播 · 已播 ${_duration(position)}';

  final play = [
    'media-kit',
    '${rate.toStringAsFixed(2)}×',
    muted ? '静音' : '音量 ${volume.round()}%',
  ].join(' · ');

  final source = [
    if (siteKey != null && siteKey.isNotEmpty) siteKey,
    if (flag != null && flag.isNotEmpty) flag,
    if (episodeName != null && episodeName.isNotEmpty) episodeName,
  ].join(' · ');

  // 结论行（`design/02` §3.2 主列表格的第一行）。
  //
  // 为什么它是第一行：它回答「这次播放到底成没成」——面板里最重要的一行。
  // 失败路径上它真实可见：错误浮层在第 1 层、屏显在第 2 层，用户能同时看到两者。
  // `succeeded == null` 表示「还没有结论」（例如刚起播），此时**整行不渲染**。
  final conclusion = switch (succeeded) {
    null => null,
    true => '正常',
    false => failureKind == null ? '失败' : '失败 · $failureKind',
  };

  return [
    if (conclusion != null) OsdDiagnosticsRow('结论', conclusion),
    OsdDiagnosticsRow('视频', video),
    OsdDiagnosticsRow('音频', audio),
    OsdDiagnosticsRow('网络', network),
    OsdDiagnosticsRow('状态', state),
    OsdDiagnosticsRow('播放', play),
    if (source.isNotEmpty) OsdDiagnosticsRow('来源', source),
  ];
}

/// 附加列：运行环境 / 窗口 / 主题 / 代理。
///
/// **任何为 null 的行都不出现**（不是显示「未知」）。
/// 理由：附加列是「环境快照」，一行「未知」不提供任何信息，只占高度。
///
/// 与上游的差异：上游这里是设备 / 系统 / 芯片 / 屏幕 / 网络环境，
/// PC 端没有对应物，**不得伪造**（`docs/phase8/design/05` §7 第 9 条）。
List<OsdDiagnosticsRow> buildOsdEnvironment({
  required String? operatingSystemVersion,
  required String? windowSize,
  required double? devicePixelRatio,
  required String? themeMode,
  required int? proxyPort,
}) {
  return [
    if (operatingSystemVersion != null && operatingSystemVersion.isNotEmpty)
      OsdDiagnosticsRow('运行环境', operatingSystemVersion),
    if (windowSize != null && windowSize.isNotEmpty)
      OsdDiagnosticsRow(
        '窗口',
        devicePixelRatio == null
            ? windowSize
            : '$windowSize @${devicePixelRatio.toStringAsFixed(2)}',
      ),
    if (themeMode != null && themeMode.isNotEmpty)
      OsdDiagnosticsRow('主题', themeMode),
    if (proxyPort != null && proxyPort > 0)
      OsdDiagnosticsRow('本地代理', '127.0.0.1:$proxyPort'),
  ];
}
