/// `type=4` 全站扫描门禁（设计文档 §8.1 分发顺序 5、§7.4.8）。
///
/// 用户报告的就是**这一类**失败：
///
/// ```text
/// ERROR [playback] 播放决策失败 site=木偶 playbackParserRequired:
///   站点 木偶 未声明 playUrl，且剧集目标不是直链 | detail=需要解析器或 Spider 运行时（MVP-A 未实现）
/// ```
///
/// 因此本门禁断言的是一个**否定不变量**，而不是某几个站点的成功：
///
/// > 真实 AT 配置里的**每一个** `type=4` 站点，走宿主真实播放路径
/// > （`resolvePlayback`）后，**都不得**产出 `playbackParserRequired`。
///
/// 为什么必须扫全站而不是抽查：`type=4` 站点的剧集目标形态差异极大
/// （站点内 ID、URL 编码 JSON、相对路径、绝对直链、平台页地址…），
/// 抽查会漏掉某一形态再次退化回「未声明 playUrl」文案。
/// 实测本门禁在补齐缺陷 22 的第二处（占位串错误文案）后，
/// `tvb_yunbao` 一类站点才被正确归类。
///
/// 允许出现的非缺陷结论（必须如实记录，不得当成通过）：
/// - `playbackUrlMissing`：播放入口确实没给地址（上游行为，§9.4）；
/// - `parseUnsupportedType` / 解析器选择失败：AT 配置声明的 11 个解析器
///   **全部是 `type=0`（Web 嗅探）**，PC 端明确不支持（§5.8），如实报错；
/// - 「无分类 / 分类无内容 / 详情无线路」：上游站点当天数据为空，与播放链路无关。
///
/// 前置条件：可达 AT 配置地址（默认 `http://192.168.50.50:4567/sub/2024/buye-0`，
/// 经 `AT_CONFIG` 覆盖）；不可达时跳过并记证据行。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void evidence(String message) => debugPrint('PHASE3-EVIDENCE $message');

/// 配置地址可达性探测（只允许 http(s)）。
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final configUrl = Platform.environment['AT_CONFIG'] ??
      'http://192.168.50.50:4567/sub/2024/buye-0';

  testWidgets('全部 type=4 站点：播放决策绝不出现 playbackParserRequired（§8.1 分发顺序 5）',
      (tester) async {
    if (!await _reachable(configUrl)) {
      evidence('t4-sweep-skip reason=config-unreachable url=$configUrl');
      return;
    }
    final temp = await Directory.systemTemp.createTemp('webhtv-t4-sweep');
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    final imported = await state.importConfig(configUrl);
    expect(imported, isTrue, reason: state.lastError?.message);
    final config = state.config!;
    final t4Sites = config.sites
        .where((site) => site.type == SiteType.jsonApiBase64Ext)
        .toList();
    evidence(
      't4-sweep-import sites=${config.sites.length} type4=${t4Sites.length} '
      'parses=${config.parses.length}',
    );
    expect(t4Sites, isNotEmpty, reason: 'AT 配置应含 type=4 站点');

    // 统计口径必须互斥且可加总，便于复查。
    var resolved = 0;
    var parserRequired = 0;
    var noAddress = 0;
    var parserUnsupported = 0;
    var otherError = 0;
    var noContent = 0;
    final parserRequiredHits = <String>[];
    final unsupportedHits = <String>[];
    final otherHits = <String>[];

    for (final site in t4Sites) {
      try {
        await state.selectSite(site);
        final categories = state.homeResult?.classes ?? const <VodClass>[];
        if (categories.isEmpty) {
          noContent += 1;
          continue;
        }
        List<Vod> list = const [];
        for (final category in categories.take(3)) {
          await state.loadCategory(category.typeId);
          list = state.categoryResult?.list ?? const [];
          if (list.isNotEmpty) break;
        }
        if (list.isEmpty) {
          noContent += 1;
          continue;
        }
        final vod = list.first;
        await state.loadDetail(vod);
        final detail = state.detailResult?.list.isNotEmpty == true
            ? state.detailResult!.list.first
            : vod;
        final lines = state.playLinesOf(detail);
        if (lines.isEmpty) {
          noContent += 1;
          continue;
        }

        // 逐线路尝试：一条成功即算该站点可播。
        var played = false;
        AppError? lastError;
        for (final line in lines) {
          if (line.episodes.isEmpty) continue;
          try {
            final decision = await state.resolvePlayback(
              episodeTarget: line.episodes.first.url,
              flag: line.flag,
              vodId: detail.vodId,
            );
            if (decision?.url?.isNotEmpty == true) {
              played = true;
              break;
            }
          } on AppError catch (error) {
            lastError = error;
            // 用户报告的缺陷类别：立刻记账并换下一条线路/下一站点。
            if (error.kind == AppErrorKind.playbackParserRequired) {
              parserRequiredHits.add('${site.key}#${line.flag}: ${error.logLine}');
              break;
            }
          }
        }
        if (played) {
          resolved += 1;
          continue;
        }
        if (lastError == null) {
          noContent += 1;
        } else if (lastError.kind == AppErrorKind.playbackParserRequired) {
          parserRequired += 1;
        } else if (lastError.kind == AppErrorKind.playbackUrlMissing) {
          noAddress += 1;
        } else if (lastError.kind == AppErrorKind.parseUnsupportedType ||
            lastError.message.contains('解析器')) {
          // AT 配置的解析器全部是 type=0（Web 嗅探），PC 端明确不支持（§5.8）。
          parserUnsupported += 1;
          if (unsupportedHits.length < 3) {
            unsupportedHits.add('${site.key}: ${lastError.logLine}');
          }
        } else {
          otherError += 1;
          if (otherHits.length < 5) {
            otherHits.add('${site.key}: ${lastError.logLine}');
          }
        }
      } catch (error) {
        otherError += 1;
        if (otherHits.length < 5) otherHits.add('${site.key}: $error');
      }
    }

    evidence(
      't4-sweep-result type4=${t4Sites.length} resolved=$resolved '
      'playbackParserRequired=$parserRequired playbackUrlMissing=$noAddress '
      'parserUnsupportedType=$parserUnsupported otherError=$otherError '
      'noContent=$noContent',
    );
    // 非缺陷类别也逐条落证据，避免「统计数字好看但没人看得到细节」。
    for (final hit in unsupportedHits) {
      evidence('t4-sweep-parser-unsupported $hit');
    }
    for (final hit in otherHits) {
      evidence('t4-sweep-other $hit');
    }

    // 核心门禁：用户报告的缺陷类别必须为 0。
    expect(
      parserRequired,
      0,
      reason: 'type=4 站点不得再出现 playbackParserRequired（不再出现「未声明 playUrl」'
          '一类错位文案）；命中：${parserRequiredHits.take(8).join(" || ")}',
    );
  }, timeout: const Timeout(Duration(minutes: 25)));
}
