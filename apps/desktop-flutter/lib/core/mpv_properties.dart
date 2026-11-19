/// mpv 属性白名单（`docs/phase9/design/01` §5.2）。
///
/// 播放器只经由 [filterMpvProperties] 向内核注入属性：**表外的键一律拒绝**，
/// 表内的键还要过值域校验。目的不是猜调用方意图，而是把
/// `NativePlayer.setProperty` 这条通道收窄到本应用自己产出的那几个属性——
/// `script-opts`、`input-conf`、`load-script`、`vo` 这类能改变进程行为的键
/// 不该因为某个调用方手滑（或历史脏配置）就进到播放内核。
///
/// 纯逻辑：不碰播放器、不读磁盘，拒绝项交给调用方记日志。
library;

/// 一条白名单规则：允许的键 + 值校验 + 拒绝时的人类可读理由。
class MpvPropertyRule {
  const MpvPropertyRule(
    this.key,
    this.accepts, {
    required this.reason,
    this.verifiable = true,
  });

  /// mpv 属性名（连字符原样，与内核一致）。
  final String key;

  /// 值校验：true 表示该值可以注入。
  final bool Function(String value) accepts;

  /// 值的合法形态，用于日志与诊断（中文、可直接展示）。
  final String reason;

  /// 写入后能否用**回读值**判定成功。
  ///
  /// media-kit 的 `setProperty` 丢弃 mpv 返回码（`real.dart:1239`），所以"没抛
  /// 异常"不等于"写进去了"。枚举/数值属性的回读就是写入值，可用来抓静默拒绝；
  /// `vf` 不行——mpv 会把滤镜图规范化重写（实测
  /// `lavfi=[lut3d=file='…']` 回读成 `lavfi=graph=%24%lut3d=file='…'`），
  /// 那类属性只能信白名单本身。
  final bool verifiable;
}

/// 一条被拒绝的属性。
class MpvPropertyRejection {
  const MpvPropertyRejection({
    required this.key,
    required this.value,
    required this.reason,
  });

  final String key;
  final String value;
  final String reason;

  /// 日志/诊断用的一行摘要。值可能很长（`vf`），截断而不是整段落日志。
  String describe() {
    final shown = value.length <= 80 ? value : '${value.substring(0, 80)}…';
    return '$key="$shown"（$reason）';
  }

  @override
  String toString() => describe();
}

/// 一次过滤的结果：通过的属性 + 被拒绝的属性。
class MpvPropertyFilterResult {
  const MpvPropertyFilterResult({
    required this.accepted,
    required this.rejected,
  });

  /// 可以安全注入的属性（保持调用方给的顺序）。
  final Map<String, String> accepted;

  /// 被拦下的属性（顺序同调用方）。
  final List<MpvPropertyRejection> rejected;

  bool get hasRejections => rejected.isNotEmpty;
}

/// 白名单里的全部键（供测试与诊断枚举）。
Set<String> get mpvPropertyWhitelistKeys => _rules.keys.toSet();

/// 某个键是否在白名单内（只判键，不判值）。
bool isWhitelistedMpvProperty(String key) => _rules.containsKey(key);

/// 按白名单过滤要注入的属性。
///
/// 逐条判定、**不抛异常**：非法项进 [MpvPropertyFilterResult.rejected]，
/// 合法项进 [MpvPropertyFilterResult.accepted]。调用方照常注入合法项，
/// 这样一条脏配置不会让整批属性（含缓存/硬解）全部失效。
MpvPropertyFilterResult filterMpvProperties(Map<String, String> requested) {
  final accepted = <String, String>{};
  final rejected = <MpvPropertyRejection>[];
  for (final entry in requested.entries) {
    if (_hasControlCharacters(entry.value)) {
      rejected.add(
        MpvPropertyRejection(
          key: entry.key,
          value: entry.value,
          reason: '值含控制字符',
        ),
      );
      continue;
    }
    final rule = _rules[entry.key];
    if (rule == null) {
      rejected.add(
        MpvPropertyRejection(
          key: entry.key,
          value: entry.value,
          reason: '不在 mpv 属性白名单内',
        ),
      );
      continue;
    }
    if (!rule.accepts(entry.value)) {
      rejected.add(
        MpvPropertyRejection(
          key: entry.key,
          value: entry.value,
          reason: rule.reason,
        ),
      );
      continue;
    }
    accepted[entry.key] = entry.value;
  }
  return MpvPropertyFilterResult(accepted: accepted, rejected: rejected);
}

// --------------------------------------------------------------- 值域校验

const Set<String> _switchValues = {'yes', 'no'};
const Set<String> _hwdecValues = {'no', 'auto-safe'};

/// 音频直通允许的编码：与 `PlayerOptions` 写出的集合一致，另加两者常见的
/// 扩展（用户手改配置时不必因为多一个编码就把整条属性丢掉）。
const Set<String> _spdifCodecs = {'ac3', 'eac3', 'dts', 'dts-hd', 'truehd'};

/// 只认 `HdrToneMapping` 产出的 6 个取值。
///
/// 脏配置里写了别的算法（mpv 还支持 `hable`/`gamma`/`linear`/`bt.2446a` 等）
/// 会在 `PlayerOptions.fromJson` 就回落 `auto`，所以这里没有"多认几个"的
/// 必要；多认只会把白名单的口子放大。同步关系由回归用例锁住。
const Set<String> _toneMappingValues = {
  'auto',
  'clip',
  'mobius',
  'reinhard',
  'bt.2390',
  'spline',
};

const Set<String> _hdrComputePeakValues = {'auto', 'yes', 'no'};

/// 字幕/音轨时间偏移在 mpv 里是**双精度秒**（`sub-delay` / `audio-delay`），
/// 本应用内部一律用毫秒整数。换算只有这一处——界面不许自己乘除。
///
/// 固定 3 位小数：1 ms 就是 0.001 s，再细的位本应用产不出来，写多了只会让
/// 回读比较多一堆噪声。
String mpvSecondsFromMilliseconds(int milliseconds) =>
    (milliseconds / 1000).toStringAsFixed(3);

/// 偏移类属性的回读容差，单位秒（= 1 ms）。
///
/// mpv 按 `%f` 打印 double，写 `0.1` 回读可能是 `0.100000`，也可能是
/// `0.09999999999999999`；按数值相等比会把「写进去了」判成失败，然后界面
/// 反复重试注入。1 ms 足够宽于差值、又远小于任何有意义的偏移步进。
const double mpvDelayToleranceSeconds = 0.001;

/// 偏移允许的绝对值上限（秒）。
///
/// 与 `player_tracks.dart` 的 `TrackOffset.maxMilliseconds` 是**两份独立常量**：
/// 模型侧夹取、白名单侧拒绝，互为补位；这里 import 上层模型会让白名单
/// 反向依赖调用方，不值得。
const double _maxDelaySeconds = 60;

/// 延迟只认本应用产出的形态：可选负号 + 整数部分 + 最多 3 位小数。
///
/// 不接受指数记数法、`+` 前缀、`nan`/`inf` 与空串——它们都不是
/// [mpvSecondsFromMilliseconds] 会写出去的形态，能出现在这里就说明有人在拼串。
final RegExp _delayValuePattern = RegExp(r'^-?\d{1,3}(\.\d{1,3})?$');

bool _isDelaySeconds(String value) {
  if (!_delayValuePattern.hasMatch(value)) return false;
  final seconds = double.tryParse(value);
  return seconds != null && seconds.abs() <= _maxDelaySeconds;
}

/// `secondary-sid` 只认 `auto` / `no` / 轨道号。
///
/// 轨道号从 1 开始（0 不是轨道），4 位封顶：再长只可能是指望它当别的东西
/// （路径、脚本参数），而这条通道正是要挡住那种东西。
final RegExp _trackIdPattern = RegExp(r'^[1-9]\d{0,3}$');

bool _isSecondarySid(String value) =>
    value == 'auto' || value == 'no' || _trackIdPattern.hasMatch(value);

bool _inSet(String value, Set<String> allowed) => allowed.contains(value);

bool _isByteSize(String value) {
  if (!RegExp(r'^[0-9]{1,10}$').hasMatch(value)) return false;
  final bytes = int.tryParse(value);
  // 0 会让 mpv 直接把缓存关掉（语义变成"不缓存"），拒绝；上界挡住手滑写错单位。
  return bytes != null && bytes > 0 && bytes <= 8 * 1024 * 1024 * 1024;
}

bool _isSpdifList(String value) {
  if (value.isEmpty) return true;
  for (final token in value.split(',')) {
    final codec = token.trim();
    if (codec.isEmpty || !_spdifCodecs.contains(codec)) return false;
  }
  return true;
}

/// `vf` 只接受 `lut.dart` 产出的那一种形态：
///
/// ```
/// lavfi=[lut3d=file='<path>']
/// ```
///
/// 空串表示清除滤镜。**不接受**别的滤镜、滤镜链或 `lut3d` 的附加参数：
/// 实测 mpv 会照收
/// `lavfi=[lut3d=file='x':interp=trilinear,movie=/unused/test]`（rc=0），
/// 也就是"在引号外多一个逗号"就能挂上第二个滤镜（`movie=` 能读本地文件）；
/// `;` 同理，且它能拼出完整的滤镜链。
///
/// 引号**内**的逗号与分号都是字面量（实测原样保留），所以路径部分允许它们
/// ——否则 `/movies/a,b.cube`、`/movies/a;b.cube` 会被误杀。危险只在引号
/// **外**：本正则把引号外的一切都钉死成 `]\$`，没有留出拼接位。
final RegExp _lutVfPattern = RegExp(
  r"^lavfi=\[lut3d=file='(?:[^'\\]|\\.)*'\]$",
);

bool _isLutVf(String value) =>
    value.isEmpty || _lutVfPattern.hasMatch(value);

/// 换行/回车/NUL 不可能出现在任何合法属性值里，只会被用来拼第二条命令。
bool _hasControlCharacters(String value) =>
    value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

/// 取某个属性的白名单规则；表外返回 null。
MpvPropertyRule? mpvPropertyRule(String key) => _rules[key];

/// 回读值是否等于写入值（供 [MpvPropertyRule.verifiable] 的属性判定落盘）。
///
/// 比较口径：去空白、数字按数值比（[tolerance] > 0 时按容差比）、其余按忽略
/// 大小写比。空回读**不等于**任何非空写入值——`NativePlayer.getProperty` 读
/// 失败时返回空串（`real.dart:1278`），当成功处理会把静默失败洗成成功。
///
/// [tolerance] 只作用于数字形态，默认 0（严格相等，即整数字节数这类属性的
/// 原有口径）。浮点属性（偏移）请传 [mpvDelayToleranceSeconds]，或直接用
/// [mpvDelayReadbackMatches]。
bool mpvPropertyReadbackMatches(
  String expected,
  String actual, {
  num tolerance = 0,
}) {
  final want = expected.trim();
  final got = actual.trim();
  if (want == got) return true;
  // mpv 会把 auto 解析成实际算法再回读（实测 tone-mapping 写 auto、回读
  // bt.2390；hdr-compute-peak 同理）。写 auto 的语义就是「让内核自己挑」，
  // 因此非空回读即算生效；空回读仍旧算失败——读失败与静默拒绝都长这样。
  if (want == 'auto') return got.isNotEmpty;
  final wantNumber = num.tryParse(want);
  final gotNumber = num.tryParse(got);
  if (wantNumber != null && gotNumber != null) {
    if (tolerance > 0) return (wantNumber - gotNumber).abs() <= tolerance;
    return wantNumber == gotNumber;
  }
  return want.toLowerCase() == got.toLowerCase();
}

/// 偏移类属性的专用回读判定：写入侧给**内部毫秒**，读回侧给 mpv 的秒串。
///
/// 为什么不直接用 [mpvPropertyReadbackMatches]：那条按数值相等比，而 mpv 打印
/// double 的末位不可控（`0.1` 可能回来 `0.09999999999999999`），差一个 ulp
/// 就会被判成没写进去。这里按 [mpvDelayToleranceSeconds] 比。
///
/// 空回读、非数字回读一律算失败：读失败与静默拒绝都长这样。
bool mpvDelayReadbackMatches(int milliseconds, String actual) {
  final got = num.tryParse(actual.trim());
  if (got == null) return false;
  return (got - milliseconds / 1000).abs() <= mpvDelayToleranceSeconds;
}

/// 音量归一写进 `af` 的**唯一**取值：裸滤镜名。
///
/// 随包内核是 `scripts/prepare_libmpv_windows.ps1` pin 的完整 FFmpeg 构建
/// （mpv v0.42.0-38 / FFmpeg N-128766），裸名 `af=dynaudnorm` 在它上面直接生效：
/// 回读 `dynaudnorm`，`audio-out-params.format` 从 `s16` 变成 `doublep`（dynaudnorm
/// 的输出格式）。Linux 的系统 libmpv 同样接受。
///
/// 仍然只放行这一个字面量、**不要**改成 `lavfi=[dynaudnorm]`：
/// - `lavfi` 形态能挂任意 ffmpeg 滤镜图（`movie=` 能读本地文件），白名单要的是
///   "只认自己产出的这一条"，不是"能以 lavfi 开头"；
/// - 历史教训：换内核之前那份 media_kit 归档（v0.36.0-403 / FFmpeg n6.0）没有编进
///   滤镜表，`lavfi=[dynaudnorm]` 会"属性写成功、建链失败"，mpv 把音轨整条丢掉
///   （`Audio: no audio`），而裸名只是被内核拒（`rc=-9`，安全的失败）。
///
/// 用例按"内核到底做了什么"断言（`afApplicable` 分支），两个平台都不互相迁就：
/// 内核能挂上就校验回读与重开保留，挂不上就校验拒绝原因、链路为空且播放照常。
/// 取证与迁移记录见 `docs/reference/libmpv-windows.md`。
const String audioNormalizationAf = 'dynaudnorm';

final Map<String, MpvPropertyRule> _rules = {
  'hwdec': MpvPropertyRule(
    'hwdec',
    (value) => _inSet(value, _hwdecValues),
    reason: '只允许 no / auto-safe',
  ),
  'cache': MpvPropertyRule(
    'cache',
    (value) => _inSet(value, _switchValues),
    reason: '只允许 yes / no',
  ),
  'demuxer-max-bytes': MpvPropertyRule(
    'demuxer-max-bytes',
    _isByteSize,
    reason: '必须是不超过 8 GiB 的正整数字节数',
  ),
  'demuxer-max-back-bytes': MpvPropertyRule(
    'demuxer-max-back-bytes',
    _isByteSize,
    reason: '必须是不超过 8 GiB 的正整数字节数',
  ),
  'audio-spdif': MpvPropertyRule(
    'audio-spdif',
    _isSpdifList,
    reason: '只允许 ac3 / eac3 / dts / dts-hd / truehd 的逗号列表',
  ),
  'af': MpvPropertyRule(
    'af',
    // 字面相等，不是前缀：lavfi 形态能把任意 ffmpeg 滤镜图挂上去，而且见
    // [audioNormalizationAf]——它在 Windows 随包内核上会把音轨整条弄没。
    (value) => value.isEmpty || value == audioNormalizationAf,
    reason: '只允许空串或 $audioNormalizationAf',
  ),
  'tone-mapping': MpvPropertyRule(
    'tone-mapping',
    (value) => _inSet(value, _toneMappingValues),
    reason: '只允许 mpv 文档里的色调映射算法',
  ),
  'hdr-compute-peak': MpvPropertyRule(
    'hdr-compute-peak',
    (value) => _inSet(value, _hdrComputePeakValues),
    reason: '只允许 auto / yes / no',
  ),
  'vf': MpvPropertyRule(
    'vf',
    _isLutVf,
    // mpv 回写的是规范化后的滤镜图，回读判不了成败。
    verifiable: false,
    reason: "只允许空串或 lavfi=[lut3d=file='…'] 形态",
  ),
  // 时间偏移：值是**秒**（双精度），由 mpvSecondsFromMilliseconds 从内部毫秒
  // 换算而来。回读要用 mpvDelayReadbackMatches（容差 1 ms），
  // 通用比较在小数末位上会把成功判成失败。
  'sub-delay': MpvPropertyRule(
    'sub-delay',
    _isDelaySeconds,
    reason: '只允许 ±60 秒内的十进制秒数（最多 3 位小数）',
  ),
  'audio-delay': MpvPropertyRule(
    'audio-delay',
    _isDelaySeconds,
    reason: '只允许 ±60 秒内的十进制秒数（最多 3 位小数）',
  ),
  // 双字幕的第二字幕：auto 跟随容器、no 关闭、数字是 mpv 轨道号。
  'secondary-sid': MpvPropertyRule(
    'secondary-sid',
    _isSecondarySid,
    reason: '只允许 auto / no / 轨道号',
  ),
};
