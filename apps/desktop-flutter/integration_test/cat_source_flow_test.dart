/// 猫源（CatVod T4 bundle）端到端集成测试（设计文档 §9 猫源、§21 Phase 3）。
///
/// 真实链路：猫源地址（`.../index.js.md5` 或本地包目录）→ `CatBundle` 下载/校验/
/// 缓存 → `CatNodeRuntime` 起真实 Node 进程（boot.js 注入 `catServerFactory` /
/// `catDartServerPort`）→ 轮询候选端口用 `CatSource.isConfig` 认准猫源服务 →
/// 读 `/config` → `CatSource.normalize`（补基址 + searchable 默认）→
/// `ConfigImportService` 解析 → 站点走 `CatHttpSiteRuntime` 完成 home/search/play。
///
/// 覆盖目标：**正确导入猫源并能成功拉取到对应的站点和搜索播放**。
///
/// 前置条件：
/// - 本机安装 Node（`node --version`）；
/// - 提供一个真实猫源包目录（含 `index.js` + `index.config.js`），
///   经环境变量 `CAT_PACKAGE` 指定；未提供时整组用例跳过并记录证据。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/search_state.dart';

void evidence(String message) => debugPrint('PHASE3-EVIDENCE $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final catPackage = Platform.environment['CAT_PACKAGE'] ?? r'F:\temp\catpkg';
  final hasPackage =
      File(p.join(catPackage, 'index.js')).existsSync() &&
      File(p.join(catPackage, 'index.config.js')).existsSync();

  late Directory temp;
  late AppPaths paths;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-cat-e2e');
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

  testWidgets('猫源：导入 → 站点 → 搜索 → 播放 真实闭环（§9 猫源）', (tester) async {
    final node = SidecarRuntimeResolver.resolve('node');
    if (node == null) {
      evidence('cat-skip reason=no-node');
      return;
    }
    if (!hasPackage) {
      evidence('cat-skip reason=no-package package=$catPackage');
      return;
    }
    evidence('cat-package package=$catPackage');

    // 1) 导入本地猫源包（走 CatBundle 本地目录路径，再起真实 Node）。
    final imported = await state.importConfig(catPackage);
    expect(imported, isTrue, reason: state.lastError?.message);
    final config = state.config!;
    evidence('cat-import sites=${config.sites.length}');
    expect(config.sites, isNotEmpty);

    // 2) 站点应被判定为可用（api 已补本机基址，走 CatSpider HTTP）。
    final items = state.siteItems;
    final available = items.where((i) => i.availability.available).toList();
    evidence(
      'cat-available available=${available.length} '
      'runtime=${available.isEmpty ? "-" : available.first.availability.runtimeName}',
    );
    expect(available, isNotEmpty);

    // 3) 搜索：挑一个声明可搜索的站点，真实命中关键词。
    final searchable = available
        .where((i) => i.site.searchable)
        .map((i) => i.site)
        .toList();
    expect(searchable, isNotEmpty, reason: '猫源站点应默认可搜索');
    final keyword = Platform.environment['CAT_KEYWORD'] ?? '寒战';
    var searched = 0;
    // 搜索是**整批**并发（默认 4 并发、每站点 20s 超时），126 个猫源站点一次
    // 最多可跑十分钟以上。早先写成「逐个站点重跑整批、最多 8 次」，上游一慢就会
    // 撞上 5 分钟用例超时（实测：整批 4.5 分钟后超时，tearDown 释放 AppState 后
    // 仍在途的批次继续调用它，报 `AppState was used after being disposed`）。
    // 单站点数据波动只需**有限重试**，不能按站点数放大整批次数。
    for (var attempt = 0; attempt < 2 && searched == 0; attempt++) {
      final outcome = await state.searchAll(keyword, quick: false);
      searched = outcome.totalItems;
      if (searched > 0) {
        for (final entry in outcome.results) {
          if (entry.itemCount > 0) {
            evidence(
              'cat-search site=${entry.siteKey} keyword=$keyword items=${entry.itemCount}',
            );
            break;
          }
        }
      }
    }
    expect(searched, greaterThan(0), reason: '猫源搜索应能命中结果');
    evidence('cat-search-total items=$searched');

    // 4) 详情 → 播放：从搜索命中的条目里挑一个**详情真有播放线路**的，走真实
    //    detail 与 play，验证宿主把 `episode.url`（剧集目标串）作为 `/play` 的 `id`。
    //    此前本用例只跑到搜索，标题却声称覆盖 play，使 `vodId ?? episodeTarget`
    //    的传参缺陷躲过了 Windows 验收证据（已由单测与 verify_cat_source.py 锁定）。
    //
    // 必须**逐层轮换候选**：远端猫源是真实服务，当天可能临时出现
    //   - 某条详情没有播放线路（`vod_play_from` 为空）；
    //   - 某条线路的 `/play` 回空地址（如夸克网盘上游就是不给地址）。
    // 两者均属上游数据波动，不是本仓库协议失败。只取“第一个命中 / 第一条线路”
    // 会把这类波动变成门禁失败，而这恰好掩盖了真正要验的「`/play` 的 `id` 传参语义」。
    //
    // 判别力不受影响：`id` 传参语义若错（把数字 `vodId` 当 `id`），
    // 则 jinpai/muou/huban 等子站的 `/play` **全部**回空地址，轮换也救不回来。
    String? playedUrl;
    var playedFlag = '';
    final playFailures = <String>[];
    final emptyDetailSamples = <String>[];
    final candidateEntries = (state.activeSearch?.results ??
            const <SiteSearchEntry>[])
        .where((entry) => entry.result?.list.isNotEmpty == true)
        .toList();
    // 轮换预算必须**有界**：整个用例上限 10 分钟，而「整批搜索 126 个真实站点」
    // 实测已要 1.8~4.5 分钟，单次 detail 实测 0.4~7 s。早期版本「每个条目试 5 个
    // vod、每个 vod 试全部线路」在当天大量站点详情为空时，光轮换就能跑满 10 分钟
    // 并把用例拖到超时（实测 `TimeoutException after 0:10:00`，搜索之后一直在
    // 换 `nodejs_omnibox_123TV` 的空详情条目）。这里改成小而有界的预算：
    // 最多 4 个条目 × 2 个 vod × 3 条线路，总计最多 24 次 resolvePlayback。
    // 判别力不受影响：`id` 传参语义若错，这 24 次会**全部**回空地址（实测缺陷
    // 版本在 jinpai/muou/huban 等子站上 8/8 失败），轮换救不回来。
    const maxEntries = 4;
    const maxVodsPerEntry = 2;
    const maxLinesPerVod = 3;
    for (final entry in candidateEntries.take(maxEntries)) {
      if (playedUrl != null) break;
      final site = available
          .where((item) => item.site.key == entry.siteKey)
          .map((item) => item.site)
          .toList();
      if (site.isEmpty) continue;
      for (final vod in entry.result!.list.take(maxVodsPerEntry)) {
        if (playedUrl != null) break;
        evidence('cat-detail-pick site=${entry.siteKey} vod=${vod.vodId}');
        await state.selectSite(site.first);
        await state.loadDetail(vod);
        final candidate = state.detailResult?.list.isNotEmpty == true
            ? state.detailResult!.list.first
            : vod;
        final candidateLines = state.playLinesOf(candidate);
        evidence(
          'cat-detail site=${entry.siteKey} vod=${candidate.vodId} '
          'lines=${candidateLines.length} '
          'flags=${candidateLines.map((l) => l.flag).join("|")}',
        );
        if (candidateLines.isEmpty) {
          emptyDetailSamples.add('${entry.siteKey}/${vod.vodId}');
          continue;
        }
        // 4a) 生产路径：resolvePlayback 带 `vodId`（宿主真实调用形态）。
        //     修复前会把数字 `vodId` 当作 `/play` 的 `id` → 部分猫源子站返回空 url。
        for (final candidateLine in candidateLines.take(maxLinesPerVod)) {
          if (candidateLine.episodes.isEmpty) continue;
          final candidateEpisode = candidateLine.episodes.first;
          try {
            final decision = await state.resolvePlayback(
              episodeTarget: candidateEpisode.url,
              flag: candidateLine.flag,
              vodId: candidate.vodId,
            );
            if (decision?.url?.isNotEmpty == true) {
              playedUrl = decision!.url;
              playedFlag = candidateLine.flag;
              break;
            }
            playFailures.add(
              '${entry.siteKey}/${candidate.vodId}#${candidateLine.flag}(empty)',
            );
          } catch (error) {
            // 单条线路失败（上游时效签名/解析器不可用）不代表站点不可播：
            // 继续试下一条线路与下一个条目，全部失败才判 FAIL。
            playFailures.add(
              '${entry.siteKey}/${candidate.vodId}#${candidateLine.flag}($error)',
            );
            evidence(
              'cat-play-line-fail site=${entry.siteKey} '
              'flag=${candidateLine.flag} error=$error',
            );
          }
        }
      }
    }
    evidence('cat-play flag=$playedFlag url=${(playedUrl ?? "").split("?").first}');
    expect(
      playedUrl,
      isNotNull,
      reason: '猫源 /play 必须至少对一条线路回传真实播放地址'
          '（详情为空的样本：${emptyDetailSamples.take(5).join(", ")}；'
          '播放失败样本：${playFailures.take(5).join(", ")}）',
    );
    expect(playedUrl, isNotEmpty);
    evidence('cat-play-ok kind=direct');
    // 整批搜索 126 个真实站点本就要几分钟（实测单批 ~1.8–4.5 分钟），
    // 且搜索允许最多 2 批（首批全空时重试一次），再加有界 detail/play 轮换。
    // 10 分钟在“首批慢 + 需要重试”时会被跑满（实测超时一次），放宽到 15 分钟。
  }, timeout: const Timeout(Duration(minutes: 15)));
}
