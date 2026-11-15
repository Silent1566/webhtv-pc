/// 射手字幕源（`docs/superpowers/plans/2026-11-15-subtitle-online-search.md` Task 4）。
///
/// 负责：本地视频文件的四段哈希、把响应里的 `Files[]` 映射成候选、
/// 单跳下载落盘（含 ZIP/体积守卫由 `SubtitleAssetStore` 兜底）。
/// 不负责：多源并行与超时（`registry.dart`）、候选打分与排序
/// （`core/subtitle_provider.dart`）、日志（URL 不得进日志）。
///
/// 没有本地文件就没有输入：网络流播放恒无结果，且**零请求**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/subtitle_provider.dart';
import '../../core/subtitle_settings.dart';
import '../subtitle_asset_store.dart';
import 'provider.dart';

const String _searchUrl = 'https://www.shooter.cn/api/subapi.php';

/// 只有 UA：该接口不校验 Referer，多带一个头反而会改参考实现的行为。
const String _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 每段读取的字节数（参考实现 shooter.py:32-44）。
const int _chunkBytes = 4 * 1024;

/// 小于 12KiB 的文件凑不满四段哈希（shooter.py:32-37）。
const int _minFileBytes = 12 * 1024;

const Set<String> _knownFormats = {'ass', 'ssa', 'srt', 'vtt'};

/// 四段 md5（小写 hex）用 `;` 连接；文件不存在或太小返回 null。
///
/// offsets 顺序照抄参考实现，**不得排序**：服务端按同一顺序拼接比对，
/// 升序会算出另一个哈希；测试里的常量由 python3 独立算出，不用本实现自证。
String? shooterFileHash(File file) {
  if (!file.existsSync()) return null;
  final size = file.lengthSync();
  if (size < _minFileBytes) return null;
  final offsets = <int>[4 * 1024, size ~/ 3 * 2, size ~/ 3, size - 8 * 1024];
  final reader = file.openSync();
  try {
    final digests = <String>[];
    for (final offset in offsets) {
      reader.setPositionSync(offset);
      digests.add(md5.convert(reader.readSync(_chunkBytes)).toString());
    }
    return digests.join(';');
  } finally {
    reader.closeSync();
  }
}

/// 语言归一：`en*` → `eng`，其余 → `zh`（只有一个语言的两种取值）。
String shooterLanguageOf(String? raw) {
  final value = (raw ?? '').toLowerCase();
  return value.startsWith('en') ? 'eng' : 'zh';
}

class ShooterSubtitleProvider implements SubtitleProvider {
  ShooterSubtitleProvider({this.client, this.cacheDir = ''});

  /// 注入的客户端；为 null 时 search 自己建一个用完就关，resolve 交给
  /// [SubtitleAssetStore] 自建。
  final http.Client? client;
  final String cacheDir;

  @override
  String get id => 'shooter';

  @override
  String get name => '射手字幕';

  @override
  int get priority => 10;

  @override
  bool get needsLocalMediaPath => true;

  @override
  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    final mediaPath = (query.mediaPath ?? '').trim();
    if (mediaPath.isEmpty) return const [];
    // SubtitleQuery 没有语言字段：输入为空，归一后发 lang=chn。
    final language = shooterLanguageOf(null);
    final String hash;
    try {
      final computed = shooterFileHash(File(mediaPath));
      if (computed == null) return const [];
      hash = computed;
    } catch (_) {
      // 文件读不到（不存在/权限/占用）等同于没有输入，不当失败上报。
      return const [];
    }
    // 字段顺序即参考实现的 form 顺序。pathinfo 按 form 规则百分号编码：
    // 不编码时含空格/'&' 的 Windows 路径会被服务端截断或注入额外字段
    // （参考实现 requests 的 data= 本身就走这层编码）。
    final body = <String>[
      'filehash=$hash',
      'pathinfo=${Uri.encodeComponent(mediaPath)}',
      'format=json',
      'lang=${language == 'eng' ? 'eng' : 'chn'}',
    ].join('&');

    final ownsClient = client == null;
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient.post(
        Uri.parse(_searchUrl),
        headers: const {
          'User-Agent': _userAgent,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: body,
      );
      return _candidatesFrom(
        response.bodyBytes,
        mediaPath: mediaPath,
        language: language,
      );
    } catch (_) {
      // 网络或解析任一环节失败都按「没有结果」处理，异常不打断聚合。
      return const [];
    } finally {
      if (ownsClient) requestClient.close();
    }
  }

  @override
  Future<SubtitleResolvedAsset?> resolve(
    SubtitleCandidate candidate,
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    final rawUrl = candidate.payload['url'];
    final url = rawUrl is String ? rawUrl.trim() : '';
    if (url.isEmpty) {
      throw const SubtitleResolveException('download_url_missing');
    }
    final rawFormat = candidate.payload['format'];
    final fallback = rawFormat is String && rawFormat.trim().isNotEmpty
        ? rawFormat.trim()
        : 'srt';
    return SubtitleAssetStore(cacheDir: cacheDir, client: client).download(
      url: url,
      headers: const {'User-Agent': _userAgent},
      nameHint: candidate.title,
      fallbackFormat: fallback,
    );
  }

  List<SubtitleCandidate> _candidatesFrom(
    List<int> bodyBytes, {
    required String mediaPath,
    required String language,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bodyBytes));
    } on FormatException {
      // 不是 JSON（错误页/风控页）不是失败：该源就是没有结果。
      return const [];
    }
    if (decoded is! List) return const [];
    final fileName = p.basename(mediaPath);
    final candidates = <SubtitleCandidate>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final files = item['Files'];
      if (files is! List) continue;
      for (final file in files) {
        if (file is! Map) continue;
        final link = file['Link'];
        if (link is! String) continue;
        final url = link.trim();
        if (url.isEmpty) continue;
        final format = _formatOf(file['Ext'], url);
        candidates.add(
          SubtitleCandidate(
            providerId: id,
            assetId: url,
            title: '$fileName | 射手 | $format',
            language: language,
            format: format,
            url: url,
            score: 120,
            payload: {'url': url, 'format': format},
            requiresResolve: true,
          ),
        );
      }
    }
    return candidates;
  }
}

/// Ext 优先，其次 URL 扩展名；**两者都要过白名单**，否则回落 srt。
///
/// Ext 也要过筛：上游给的 'zip'/'unknown' 若穿透，会作为 fallbackFormat
/// 落出一个非字幕文件，mpv 建不出轨——静默失败，不如回落 srt。
String _formatOf(Object? ext, String url) {
  final declared = (ext is String ? ext : '').trim().toLowerCase();
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  final fromUrl = dot >= 0 && dot < path.length - 1
      ? path.substring(dot + 1).toLowerCase()
      : '';
  // 参考实现先拼再 replace('.', '')，'.ass' 这类带点写法也算白名单内。
  final value = (declared.isNotEmpty ? declared : fromUrl).replaceAll('.', '');
  return _knownFormats.contains(value) ? value : 'srt';
}

/// 未启用时返回 null：该源完全不参与搜索，也不产生任何请求。
SubtitleProvider? buildShooterProvider({
  required SubtitleSettings settings,
  http.Client? client,
  String cacheDir = '',
}) {
  if (!settings.shooterEnabled) return null;
  return ShooterSubtitleProvider(client: client, cacheDir: cacheDir);
}
