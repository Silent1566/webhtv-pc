/// `type=4`（HTTP API + Base64 ext）播放入口端到端测试（设计文档 §8.1 分发顺序 4、
/// §7.4.8）。
///
/// 覆盖目标：**T4 站点能真实播放**——用户实测日志里 `site=木偶
/// playbackParserRequired: 站点 木偶 未声明 playUrl，且剧集目标不是直链`。
///
/// 真实链路：AT 配置（含 163 站点，其中 68 个 `type=4`）→ `AppState.importConfig`
/// → 选中 T4 站点 → 首页 → 分类 → 详情 → `resolvePlayback`（必须真实调站点
/// `api?play=<剧集目标>&flag=<线路>`）→ 拿到可播地址。
///
/// 前置条件：
/// - 可达 AT 配置地址（默认 `http://192.168.50.50:4567/sub/2024/buye-0`），
///   经环境变量 `AT_CONFIG` 覆盖；不可达时整组用例跳过并记证据行。
///
/// 与 `cat_source_flow_test.dart` 同构：真实服务端 + 真实 HTTP，不是打桩。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void evidence(String message) => debugPrint('PHASE3-EVIDENCE $message');

/// 配置地址可达性探测（HEAD/GET 均试；只允许 http(s)）。
Future<bool> _reachable(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>();
    return response.statusCode >= 200 && response.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 一次媒体取流探针的结果。
class _StreamProbe {
  const _StreamProbe({
    required this.status,
    required this.bytes,
    required this.reason,
  });

  final int status;
  final int bytes;
  final String reason;

  bool get ok => status >= 200 && status < 300 && bytes > 0;
}

/// 用宿主真实取流路径（决策地址 + 决策 Header）做一次 `Range` 请求。
///
/// 地址可能是本地代理 URL（`http://127.0.0.1:<port>/p/<token>/<base64>`）或直连
/// 上游地址，两者都用同一个 `HttpClient` 请求；Header 取 [PlaybackDecision.assetHeaders]
/// （走代理时为代理前的原始 Header，这正是代理自己会注入的那一份）。
Future<_StreamProbe> _probeBytes(PlaybackDecision decision) async {
  final url = decision.url;
  if (url == null || url.isEmpty) {
    return const _StreamProbe(status: 0, bytes: 0, reason: 'empty-url');
  }
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return const _StreamProbe(status: 0, bytes: 0, reason: 'non-http-scheme');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
    // 决策携带的媒体 Header 必须原样带上（115 CDN 靠 UA 放行）。
    final headers = decision.assetHeaders;
    if (headers != null) {
      for (final entry in headers.entries) {
        // Range 由探针自己控制，站点 Header 不得覆盖它。
        if (entry.key.toLowerCase() == 'range') continue;
        request.headers.set(entry.key, entry.value);
      }
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = await response.fold<int>(0, (sum, chunk) => sum + chunk.length);
    return _StreamProbe(
      status: response.statusCode,
      bytes: bytes,
      reason: 'content-type=${response.headers.contentType}',
    );
  } catch (error) {
    return _StreamProbe(status: 0, bytes: 0, reason: '$error');
  } finally {
    client.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final configUrl = Platform.environment['AT_CONFIG'] ??
      'http://192.168.50.50:4567/sub/2024/buye-0';
  // 期望被真实播放的 T4 站点（用户实测失败的那个）。多个候选按顺序尝试。
  final preferredKeys = (Platform.environment['T4_SITES'] ?? '木偶,HanXiaoQuanNight')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  late Directory temp;
  late AppPaths paths;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-t4-e2e');
    paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('T4（type=4）：真实配置 → 站点 → 分类 → 详情 → 播放入口 → 可播地址', (
    tester,
  ) async {
    if (!await _reachable(configUrl)) {
      evidence('t4-skip reason=config-unreachable url=$configUrl');
      return;
    }
    evidence('t4-config url=$configUrl');

    // 1) 导入真实 AT 配置。
    final imported = await state.importConfig(configUrl);
    expect(imported, isTrue, reason: state.lastError?.message);
    final config = state.config!;
    final t4Sites = config.sites
        .where((site) => site.type == SiteType.jsonApiBase64Ext)
        .toList();
    evidence(
      't4-import sites=${config.sites.length} type4=${t4Sites.length} '
      'parses=${config.parses.length}',
    );
    expect(t4Sites, isNotEmpty, reason: 'AT 配置应含 type=4 站点');

    // 2) 站点可用性：`type=4` 走 HTTP API 运行时（不得报不支持）。
    final items = state.siteItems;
    final available = items
        .where((item) => item.site.type == SiteType.jsonApiBase64Ext)
        .where((item) => item.availability.available)
        .toList();
    evidence('t4-available available=${available.length}/${t4Sites.length}');
    expect(
      available.length,
      t4Sites.length,
      reason: 'type=4 站点必须全部判定为可用（HTTP API 运行时）',
    );

    // 3) 逐个候选站点跑完整闭环：首页 → 分类 → 详情 → 播放。
    //
    // **每个**候选站点都必须能拿到可播地址：这是用户报告的缺陷本身
    // （`site=木偶 playbackParserRequired`）。若只断言「至少一个成功」，
    // 那么当“某个站点的剧集目标恰好是直链”时旧代码也能过，反向验证实测
    // 证明了这一点（旧代码下 `HanXiaoQuanNight` 成功、`木偶` 失败）。
    var succeeded = 0;
    final failures = <String>[];
    for (final key in preferredKeys) {
      final match = t4Sites.where((site) => site.key == key).toList();
      if (match.isEmpty) {
        evidence('t4-site-missing key=$key');
        continue;
      }
      final site = match.first;
      try {
        await state.selectSite(site);
        final home = state.homeResult;
        evidence(
          't4-home site=$key classes=${home?.classes.length ?? 0} '
          'list=${home?.list.length ?? 0}',
        );

        // 分类：取第一个分类，拉第一页。
        final categories = home?.classes ?? const <VodClass>[];
        expect(categories, isNotEmpty, reason: 'T4 站点应有分类');
        await state.loadCategory(categories.first.typeId);
        final list = state.categoryResult?.list ?? const <Vod>[];
        evidence(
          't4-category site=$key t=${categories.first.typeId} list=${list.length}',
        );
        expect(list, isNotEmpty, reason: 'T4 站点分类第一页应有内容');

        // 详情。
        final vod = list.first;
        await state.loadDetail(vod);
        final detail = state.detailResult?.list.isNotEmpty == true
            ? state.detailResult!.list.first
            : vod;
        final lines = state.playLinesOf(detail);
        evidence(
          't4-detail site=$key vod=${detail.vodId} lines=${lines.length} '
          'flags=${lines.map((l) => l.flag).join("|")}',
        );
        expect(lines, isNotEmpty, reason: 'T4 详情应至少有一条播放线路');

        // 播放：必须真实调站点 `api?play=<剧集目标>&flag=<线路>`。
        // 修复前此处必然抛 `playbackParserRequired`（用户实测日志）。
        var playedThis = false;
        final lineErrors = <String>[];
        for (final line in lines) {
          if (line.episodes.isEmpty) continue;
          final episode = line.episodes.first;
          try {
            final decision = await state.resolvePlayback(
              episodeTarget: episode.url,
              flag: line.flag,
              vodId: detail.vodId,
            );
            expect(decision, isNotNull);
            expect(decision!.url, isNotNull, reason: '播放入口必须回传地址');
            expect(decision.url, isNotEmpty);
            // 播放入口返回的媒体 Header（如 115 CDN 必需的 UA）必须随决策带上，
            // 否则“拿到了地址但取不了流”在界面上仍表现为播放失败。
            // 注意：地址若被本地代理接管，`headers` 会清空（Header 改由代理注入，
            // §7.4.6 步骤 4），此时原始 Header 在 `upstreamHeaders` 上——
            // `assetHeaders` 就是为这种场景提供的取法。
            final effective = decision.assetHeaders;
            final headerKeys = effective?.keys.toList() ?? const [];
            evidence(
              't4-play site=$key flag=${line.flag} '
              'url=${decision.url!.split("?").first} '
              'headers=${headerKeys.join(",")}',
            );
            expect(
              headerKeys.isNotEmpty,
              isTrue,
              reason: 'T4 播放入口返回的媒体 Header 必须进入决策（实测 115 CDN 必需 UA）',
            );

            // 更强证据：**实际取一段字节**。仅有地址不够——用户感知的是「能不能播」，
            // 而 T4 站点的地址常是带时效签名的 CDN 直链（签名错/Header 缺 → 403）。
            // 这里用宿主真实的取流路径（决策地址 + 决策 Header）做一次 `Range` 请求。
            final stream = await _probeBytes(decision);
            evidence(
              't4-stream site=$key flag=${line.flag} status=${stream.status} '
              'bytes=${stream.bytes} reason=${stream.reason}',
            );
            expect(
              stream.ok,
              isTrue,
              reason: 'T4 决策地址必须真实可取流（Range 请求 2xx/206）：${stream.reason}',
            );
            playedThis = true;
            break;
          } catch (error) {
            // 单条线路失败（上游时效签名/解析器不可用）不代表站点不可播：
            // 继续试下一条线路，全部失败才记为该站点失败。
            lineErrors.add('${line.flag}: $error');
            evidence('t4-play-line-fail site=$key flag=${line.flag} error=$error');
          }
        }
        expect(
          playedThis,
          isTrue,
          reason: 'T4 站点必须能拿到可播地址；失败线路：${lineErrors.join(" / ")}',
        );
        succeeded += 1;
        evidence('t4-site-ok site=$key');
      } catch (error) {
        failures.add('$key: $error');
        evidence('t4-site-fail site=$key error=$error');
      }
    }
    expect(
      succeeded,
      preferredKeys.length,
      reason: '每个候选 T4 站点都必须完成播放闭环；失败：${failures.join(" / ")}',
    );
    evidence('t4-sites-ok count=$succeeded');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
