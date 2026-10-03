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
import 'package:webhtv_pc/core/protocol.dart';
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
    for (final site in searchable.take(8)) {
      try {
        final outcome = await state.searchAll(keyword, quick: false);
        searched = outcome.totalItems;
        if (searched > 0) {
          evidence('cat-search site=${site.key} keyword=$keyword items=$searched');
          break;
        }
      } catch (error) {
        evidence('cat-search site=${site.key} error=$error');
      }
    }
    expect(searched, greaterThan(0), reason: '猫源搜索应能命中结果');
    evidence('cat-search-total items=$searched');

    // 4) 详情 → 播放：从搜索命中的第一个条目走真实 detail 与 play，
    //    验证宿主把 `episode.url`（剧集目标串）作为 `/play` 的 `id`。
    //    此前本用例只跑到搜索，标题却声称覆盖 play，使 `vodId ?? episodeTarget`
    //    的传参缺陷躲过了 Windows 验收证据（已由单测与 verify_cat_source.py 锁定）。
    Vod? picked;
    for (final entry in state.activeSearch?.results ?? const <SiteSearchEntry>[]) {
      final first = entry.result?.list.isNotEmpty == true
          ? entry.result!.list.first
          : null;
      if (first != null) {
        picked = first;
        evidence('cat-detail-pick site=${entry.siteKey} vod=${first.vodId}');
        break;
      }
    }
    expect(picked, isNotNull, reason: '搜索命中后应能取到可进详情的条目');

    // `loadDetail` 依赖当前选中站点：切到该条目所属站点再拉详情。
    final pickedSite = available
        .firstWhere((i) => i.site.key == state.activeSearch!.results
            .firstWhere((e) => e.result?.list.isNotEmpty == true)
            .siteKey)
        .site;
    await state.selectSite(pickedSite);
    await state.loadDetail(picked!);
    final detailVod = state.detailResult?.list.isNotEmpty == true
        ? state.detailResult!.list.first
        : picked;
    final lines = state.playLinesOf(detailVod);
    evidence(
      'cat-detail lines=${lines.length} '
      'flags=${lines.map((l) => l.flag).join("|")}',
    );
    expect(lines, isNotEmpty, reason: '猫源详情应至少有一条播放线路');
    final line = lines.first;
    expect(line.episodes, isNotEmpty);
    final episode = line.episodes.first;

    // 4a) 生产路径：resolvePlayback 带 `vodId`（宿主真实调用形态）。
    //     修复前会把数字 `vodId` 当作 `/play` 的 `id` → 部分猫源子站返回空 url。
    final decision = await state.resolvePlayback(
      episodeTarget: episode.url,
      flag: line.flag,
      vodId: detailVod.vodId,
    );
    evidence(
      'cat-play flag=${line.flag} url=${(decision?.url ?? "").split("?").first}',
    );
    expect(decision, isNotNull, reason: state.lastError?.message);
    expect(
      decision!.url,
      isNotNull,
      reason: '猫源 /play 必须回传真实播放地址（传纯 vod_id 会返回空 url）',
    );
    expect(decision.url, isNotEmpty);
    evidence('cat-play-ok kind=${decision.action.name}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
