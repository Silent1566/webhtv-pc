import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_diagnostics.dart';
import 'package:webhtv_pc/core/playback_diagnostics.dart';

void main() {
  group('屏显诊断主列（design/02 §3.2）', () {
    test('无结论时 6 行齐全且顺序固定', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 3840,
        videoHeight: 2160,
        videoCodec: 'hevc',
        videoFps: 59.94,
        videoBitrate: 42000000,
        audioCodec: 'eac3',
        audioChannels: '6',
        audioSampleRate: 48000,
        audioBitrate: 640000,
        position: const Duration(minutes: 12, seconds: 34),
        duration: const Duration(hours: 1, minutes: 58, seconds: 20),
        buffered: const Duration(seconds: 6),
        rate: 1.0,
        volume: 80,
        muted: false,
        formatLabel: 'HLS (m3u8)',
        targetHost: 'example.com',
        siteKey: 'muou',
        flag: '线路一',
        episodeName: 'E3',
        succeeded: null,
        failureKind: null,
      );
      expect(rows.map((r) => r.label).toList(), [
        '视频', '音频', '网络', '状态', '播放', '来源',
      ]);
      expect(rows.first.value, contains('hevc'));
      expect(rows.first.value, contains('3840×2160'));
    });

    test('未知字段显示「未知」而不是 0 或空', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: '未知',
        targetHost: '',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      final video = rows.firstWhere((r) => r.label == '视频');
      expect(video.value, contains('未知'));
      expect(video.value.contains('0×0'), isFalse);
    });

    test('直播（duration 为 0）时状态行不显示 00:00 / 00:00', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 1920,
        videoHeight: 1080,
        videoCodec: 'h264',
        videoFps: 25,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: const Duration(seconds: 5),
        duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'HLS (m3u8)',
        targetHost: 'live.example.com',
        siteKey: 'live',
        flag: null,
        episodeName: 'CCTV-1',
        succeeded: null,
        failureKind: null,
      );
      final state = rows.firstWhere((r) => r.label == '状态');
      expect(state.value.contains('00:00 / 00:00'), isFalse);
    });

    test('静音时播放行标注静音', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 1920,
        videoHeight: 1080,
        videoCodec: 'h264',
        videoFps: 25,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.5,
        volume: 0,
        muted: true,
        formatLabel: 'MP4',
        targetHost: 'x.test',
        siteKey: 's',
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      final play = rows.firstWhere((r) => r.label == '播放');
      expect(play.value, contains('静音'));
      expect(play.value, contains('1.5'));
    });
  });

  group('屏显诊断结论行（design/02 §3.2 主列第一行）', () {
    // 结论行（`design/02` §3.2 主列表格的**第一行**）。
    //
    // 为什么必须单独测：它是面板里最重要的一行（回答「这次播放到底成没成」），
    // 而它的三种状态（无结论 / 成功 / 失败）各自是一条独立分支。
    // 用**正向断言确切串**，不用「不含某串」——本轮的教训是
    // 否定断言会放过完全坏掉的实现（Task 5 的直播用例就是这样漏的）。
    test('结论行：成功时是「正常」，且排在第一行', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 1920, videoHeight: 1080, videoCodec: 'h264',
        videoFps: 25, videoBitrate: null,
        audioCodec: null, audioChannels: null, audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero, duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0, volume: 100, muted: false,
        formatLabel: 'HLS (m3u8)', targetHost: 'x.test',
        siteKey: 's', flag: null, episodeName: null,
        succeeded: true, failureKind: null,
      );
      expect(rows.first.label, '结论');
      expect(rows.first.value, '正常');
      expect(rows.map((r) => r.label).toList(), [
        '结论', '视频', '音频', '网络', '状态', '播放', '来源',
      ]);
    });

    test('结论行：失败时带分类', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null, videoHeight: null, videoCodec: null,
        videoFps: null, videoBitrate: null,
        audioCodec: null, audioChannels: null, audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero, duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0, volume: 100, muted: false,
        formatLabel: '未知', targetHost: '',
        siteKey: null, flag: null, episodeName: null,
        succeeded: false, failureKind: 'timeout',
      );
      expect(rows.first.label, '结论');
      expect(rows.first.value, '失败 · timeout');
    });

    test('结论行：失败但无分类时只有「失败」', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null, videoHeight: null, videoCodec: null,
        videoFps: null, videoBitrate: null,
        audioCodec: null, audioChannels: null, audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero, duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0, volume: 100, muted: false,
        formatLabel: '未知', targetHost: '',
        siteKey: null, flag: null, episodeName: null,
        succeeded: false, failureKind: null,
      );
      expect(rows.first.value, '失败');
      expect(rows.first.value.contains('·'), isFalse, reason: '无分类时不得留分隔符');
    });

    test('结论行：succeeded 为 null 时整行不出现', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null, videoHeight: null, videoCodec: null,
        videoFps: null, videoBitrate: null,
        audioCodec: null, audioChannels: null, audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero, duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0, volume: 100, muted: false,
        formatLabel: '未知', targetHost: '',
        siteKey: null, flag: null, episodeName: null,
        succeeded: null, failureKind: null,
      );
      expect(rows.any((r) => r.label == '结论'), isFalse);
    });
  });

  group('屏显诊断附加列（design/02 §3.2）', () {
    test('拿不到的行不出现（不是显示「未知」）', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: null,
        windowSize: null,
        devicePixelRatio: null,
        themeMode: null,
        proxyPort: null,
      );
      expect(rows, isEmpty, reason: '附加列是环境快照，一行「未知」不提供信息');
    });

    test('有值的行按固定顺序出现', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: 'Windows 11 (10.0.26100)',
        windowSize: '1440×900',
        devicePixelRatio: 1.0,
        themeMode: 'dark',
        proxyPort: null,
      );
      expect(rows.map((r) => r.label).toList(), ['运行环境', '窗口', '主题']);
      expect(rows.first.value, contains('Windows'));
    });
  });

  // ---------------------------------------------------------------------------
  // 以下为实施者补充的用例。brief 的 6 条用例逐字保留在上方。
  //
  // 补充理由：brief 的 6 条用例是**行为抽样**，不是契约的完整刻画。逐条反证后
  // 发现下列实现都能通过那 6 条——因此每条补充用例都写明它杀掉哪个错误实现。
  // ---------------------------------------------------------------------------

  group('主列补盲点：码率分档与守卫', () {
    // 杀掉「码率恒按 Mbps 输出」「恒按 Kbps 输出」「根本没有分档」三种实现。
    // brief 只喂过 42000000 与 640000（都落在 Mbps 档），分档边界完全未被触及。
    test('码率三档边界（bps / Kbps / Mbps）', () {
      String videoRow(num? bitrate) => buildOsdDiagnostics(
            videoWidth: null,
            videoHeight: null,
            videoCodec: null,
            videoFps: null,
            videoBitrate: bitrate,
            audioCodec: null,
            audioChannels: null,
            audioSampleRate: null,
            audioBitrate: null,
            position: Duration.zero,
            duration: const Duration(minutes: 1),
            buffered: Duration.zero,
            rate: 1.0,
            volume: 100,
            muted: false,
            formatLabel: 'MP4',
            targetHost: '',
            siteKey: null,
            flag: null,
            episodeName: null,
            succeeded: null,
            failureKind: null,
          ).firstWhere((r) => r.label == '视频').value;

      expect(videoRow(999), '未知 · 999 bps');
      // 边界：999999/1000 = 999.999 → toStringAsFixed(0) 进位成 1000。
      // 这条同时钉住「Kbps 用 0 位小数」，换成 1 位小数会得到 1000.0。
      expect(videoRow(999999), '未知 · 1000 Kbps');
      expect(videoRow(1000000), '未知 · 1.0 Mbps');
      expect(videoRow(42000000), '未知 · 42.0 Mbps');
    });

    // 杀掉「只判 != null、不判 > 0」的实现：它会把 0 当成有效值渲染成
    // `0.00 fps` / `0 Hz` / `0 bps`，把「引擎没报」伪装成「确实是 0」。
    // brief 的未知用例喂的是 null，null 与 0 走的是两条不同分支，因此杀不掉它。
    test('0 与负值按拿不到处理，不渲染成 0', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 0,
        videoHeight: 0,
        videoCodec: 'h264',
        videoFps: 0,
        videoBitrate: 0,
        audioCodec: 'aac',
        audioChannels: null,
        audioSampleRate: 0,
        audioBitrate: -1,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'MP4',
        targetHost: '',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      final video = rows.firstWhere((r) => r.label == '视频').value;
      final audio = rows.firstWhere((r) => r.label == '音频').value;

      expect(video, 'h264');
      expect(video.contains('0×0'), isFalse);
      expect(video.contains('fps'), isFalse);
      expect(video.contains('bps'), isFalse);
      expect(audio, 'aac');
      expect(audio.contains('Hz'), isFalse);
      expect(audio.contains('bps'), isFalse);
    });

    // 杀掉「只判 != null」的实现：它会把空串原样渲染成空值，
    // 而 brief 的未知用例喂的是 null，空串分支未被覆盖。
    test('空串编解码器按「未知」处理，而不是空值', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: '',
        videoFps: null,
        videoBitrate: null,
        audioCodec: '',
        audioChannels: '',
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'MP4',
        targetHost: '',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      expect(rows.firstWhere((r) => r.label == '视频').value, '未知');
      expect(rows.firstWhere((r) => r.label == '音频').value, '未知');
    });
  });

  group('主列补盲点：状态与播放的精确格式', () {
    // 杀掉「用 inMinutes 拼时长」「不补零」「小时分支写错」的实现。
    // brief 只断言了直播时**不含** `00:00 / 00:00`——那是一条否定断言，
    // 把状态行整个渲染成空串或任意别的文本都能通过。
    test('非直播状态行含进度、总时长与缓冲，且补零', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: const Duration(minutes: 12, seconds: 34),
        duration: const Duration(hours: 1, minutes: 58, seconds: 20),
        buffered: const Duration(seconds: 6),
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'MP4',
        targetHost: '',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      expect(
        rows.firstWhere((r) => r.label == '状态').value,
        '12:34 / 1:58:20 · 缓冲 00:06',
      );
    });

    test('不足一小时时不出现小时段，秒与分补零', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: const Duration(seconds: 5),
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'MP4',
        targetHost: '',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      expect(
        rows.firstWhere((r) => r.label == '状态').value,
        '00:05 / 01:00 · 缓冲 00:00',
      );
    });

    // 杀掉「静音时同时打印静音与音量 0%」的实现：brief 只断言 contains('静音')，
    // 多打一段音量仍然通过。
    test('播放行：非静音显示音量百分比，静音时不再显示音量', () {
      List<OsdDiagnosticsRow> build({required bool muted, required double volume}) =>
          buildOsdDiagnostics(
            videoWidth: null,
            videoHeight: null,
            videoCodec: null,
            videoFps: null,
            videoBitrate: null,
            audioCodec: null,
            audioChannels: null,
            audioSampleRate: null,
            audioBitrate: null,
            position: Duration.zero,
            duration: const Duration(minutes: 1),
            buffered: Duration.zero,
            rate: 1.0,
            volume: volume,
            muted: muted,
            formatLabel: 'MP4',
            targetHost: '',
            siteKey: null,
            flag: null,
            episodeName: null,
            succeeded: null,
            failureKind: null,
          );

      expect(
        build(muted: false, volume: 80).firstWhere((r) => r.label == '播放').value,
        'media-kit · 1.00× · 音量 80%',
      );
      final mutedRow =
          build(muted: true, volume: 0).firstWhere((r) => r.label == '播放').value;
      expect(mutedRow, 'media-kit · 1.00× · 静音');
      expect(mutedRow.contains('音量'), isFalse);
    });

    // 杀掉「直播判定失效、但仍走进度分支」的实现。
    //
    // 为什么必须有这一条：brief 那条直播用例是**否定断言**
    // （`contains('00:00 / 00:00')` isFalse）。把 `duration > Duration.zero`
    // 换成恒真，直播时会渲染成 `00:05 / 00:00`——它**不含** `00:00 / 00:00`，
    // 于是那条否定断言照样通过。变异测试实测确认了这个缺口。
    // 因此这里断言直播文案的精确值，把「直播」这个语义钉死。
    test('直播状态行是直播文案，不是进度文案', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: const Duration(seconds: 5),
        duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'HLS (m3u8)',
        targetHost: 'live.example.com',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      final state = rows.firstWhere((r) => r.label == '状态').value;
      expect(state, '直播 · 已播 00:05');
      expect(state.contains('缓冲'), isFalse, reason: '直播没有可缓冲的总时长');
    });
  });

  group('主列补盲点：来源行与网络行', () {
    // 杀掉「来源行的第一个字段不做空值守卫」的实现：
    // `[siteKey ?? '', flag, episodeName].join(' · ')` 在 siteKey 为 null
    // 而 flag 有值时会渲染出前导分隔符 ` · 线路一`。
    // brief 的齐全用例里三个字段都有值，杀不掉它。
    test('来源行首个字段为空时不产生前导分隔符', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'MP4',
        targetHost: '',
        siteKey: null,
        flag: '线路一',
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      expect(rows.firstWhere((r) => r.label == '来源').value, '线路一');
    });

    // 杀掉「来源行恒出现」的实现：brief 的齐全用例里三个来源字段都有值，
    // 恒出现的实现同样通过。来源行是条件行，缺失时必须整行省略。
    test('三个来源字段都拿不到时省略来源行', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'MP4',
        targetHost: '',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      expect(rows.map((r) => r.label).toList(), ['视频', '音频', '网络', '状态', '播放']);
    });

    // 杀掉「来源行用空串占位」的实现：空串字段不得进入来源行。
    test('只有部分来源字段时按固定顺序拼接，空串不占位', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'MP4',
        targetHost: '',
        siteKey: 'muou',
        flag: '',
        episodeName: 'E3',
        succeeded: null,
        failureKind: null,
      );
      expect(rows.firstWhere((r) => r.label == '来源').value, 'muou · E3');
    });

    // 网络行只承载「格式 + 主机」。这里用真实的上游取数函数
    // （detectMediaFormat / NetworkTarget.of）构造输入，钉住 Task 11 的接线契约：
    // 带签名的地址经脱敏后只剩 host，token 不可能出现在屏显上。
    test('网络行只含格式与主机，带签名的地址不泄露 query', () {
      const signed = 'https://example.com/a.m3u8?token=SECRET123&sign=abc';
      final target = NetworkTarget.of(signed);
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: detectMediaFormat(signed).label,
        targetHost: target.host,
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      final network = rows.firstWhere((r) => r.label == '网络').value;
      expect(network, 'HLS (m3u8) · example.com');
      expect(network.contains('SECRET123'), isFalse);
      expect(network.contains('?'), isFalse);
    });

    // 杀掉「主机为空时仍拼接分隔符」的实现：会渲染出 `MP4 · ` 这种尾随分隔符。
    test('主机为空时网络行只有格式，无尾随分隔符', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'MP4',
        targetHost: '',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      expect(rows.firstWhere((r) => r.label == '网络').value, 'MP4');
    });
  });

  group('附加列补盲点：条件行的边界', () {
    // 杀掉「devicePixelRatio 为 null 就整行省略」的实现：窗口尺寸是主信息，
    // DPR 只是后缀。brief 的两条用例里 DPR 要么全 null、要么有值，杀不掉它。
    test('窗口行：DPR 拿不到时仍出现，且不带 @ 后缀', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: null,
        windowSize: '1440×900',
        devicePixelRatio: null,
        themeMode: null,
        proxyPort: null,
      );
      expect(rows.map((r) => r.label).toList(), ['窗口']);
      expect(rows.single.value, '1440×900');
    });

    test('窗口行：DPR 有值但窗口尺寸拿不到时不出现', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: null,
        windowSize: null,
        devicePixelRatio: 2.0,
        themeMode: null,
        proxyPort: null,
      );
      expect(rows, isEmpty);
    });

    test('窗口行：DPR 有值时保留两位小数', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: null,
        windowSize: '1440×900',
        devicePixelRatio: 1.5,
        themeMode: null,
        proxyPort: null,
      );
      expect(rows.single.value, '1440×900 @1.50');
    });

    // 杀掉「本地代理行根本不存在」的实现：brief 的两条用例都传 proxyPort: null，
    // 代理行从未被断言过——整行漏掉也能通过全部 6 条。
    test('本地代理行：有值时出现，0 与负值按拿不到处理', () {
      final present = buildOsdEnvironment(
        operatingSystemVersion: null,
        windowSize: null,
        devicePixelRatio: null,
        themeMode: null,
        proxyPort: 8899,
      );
      expect(present.map((r) => r.label).toList(), ['本地代理']);
      expect(present.single.value, '127.0.0.1:8899');

      for (final port in [0, -1]) {
        expect(
          buildOsdEnvironment(
            operatingSystemVersion: null,
            windowSize: null,
            devicePixelRatio: null,
            themeMode: null,
            proxyPort: port,
          ),
          isEmpty,
          reason: '端口 $port 不是可用的监听端口',
        );
      }
    });

    // 杀掉「只判 != null」的实现：会把空串渲染成一行空值。
    test('空串按拿不到处理（不出现空值行）', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: '',
        windowSize: '',
        devicePixelRatio: 1.0,
        themeMode: '',
        proxyPort: null,
      );
      expect(rows, isEmpty);
    });

    // 附加列的行序是契约（brief 只覆盖了「运行环境/窗口/主题」这一段）。
    test('四行齐全时顺序固定', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: 'Windows 11 (10.0.26100)',
        windowSize: '1440×900',
        devicePixelRatio: 1.0,
        themeMode: 'dark',
        proxyPort: 8899,
      );
      expect(
        rows.map((r) => r.label).toList(),
        ['运行环境', '窗口', '主题', '本地代理'],
      );
    });
  });
}
