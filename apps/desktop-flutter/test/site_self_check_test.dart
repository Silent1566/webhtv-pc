import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/request_cancellation.dart';
import 'package:webhtv_pc/services/cancellable_probe_runtime.dart';
import 'package:webhtv_pc/services/site_self_check.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';

Site site(String key) =>
    Site(key: key, name: '站点 $key', type: 1, api: 'https://fixture.invalid');
SiteResult content() => SiteResult(
  list: [Vod(vodId: 'v', vodName: '作品')],
);
const classes = [
  VodClass(typeId: 'config', typeName: '配置中心'),
  VodClass(typeId: 'login', typeName: '登录'),
  VodClass(typeId: 'settings', typeName: 'Settings'),
  VodClass(typeId: '1', typeName: '电影'),
  VodClass(typeId: '1', typeName: '重复电影'),
  VodClass(typeId: '2', typeName: '剧集'),
  VodClass(typeId: '3', typeName: '综艺'),
];

class ProbeRuntime extends UnsupportedRuntime
    implements CancellableProbeRuntime {
  ProbeRuntime() : super(runtimeName: 'fixture', reason: 'fixture');
  Future<SiteResult> Function(Site, RequestCancellation) onHome = (
    _,
    _,
  ) async => content();
  Future<SiteResult> Function(Site, String, RequestCancellation) onCategory = (
    _,
    _,
    _,
  ) async => content();
  final homes = <String>[];
  final categories = <String>[];
  final signals = <RequestCancellation>[];
  @override
  Future<SiteResult> homeCancellable(
    Site site, {
    required RequestCancellation cancellation,
  }) {
    homes.add(site.key);
    signals.add(cancellation);
    return onHome(site, cancellation);
  }

  @override
  Future<SiteResult> categoryCancellable(
    Site site, {
    required String typeId,
    required int page,
    Map<String, String> filters = const {},
    required RequestCancellation cancellation,
  }) {
    expect(page, 1);
    categories.add(typeId);
    return onCategory(site, typeId, cancellation);
  }
}

class ProbeRouter extends SpiderRouter {
  ProbeRouter(this.runtime, {this.unavailable = const {}})
    : super(client: HttpApiClient(), globalHeaders: const []);
  final SiteRuntime runtime;
  final Set<String> unavailable;
  @override
  SiteAvailability classifySite(Site site) => SiteAvailability(
    available: !unavailable.contains(site.key),
    runtimeName: 'fixture',
    reason: '运行时未安装',
  );
  @override
  SiteRuntime runtimeFor(Site site) => runtime;
}

SiteSelfCheck checker(
  ProbeRuntime runtime,
  List<Site> sites, {
  int concurrency = 2,
  Duration siteTimeout = const Duration(seconds: 30),
  Set<String> unavailable = const {},
}) {
  final router = ProbeRouter(runtime, unavailable: unavailable);
  addTearDown(router.dispose);
  final result = SiteSelfCheck(
    service: SiteService(
      appConfig: AppConfig(sites: sites),
      router: router,
    ),
    concurrency: concurrency,
    siteTimeout: siteTimeout,
  );
  addTearDown(result.dispose);
  return result;
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'explicit run uses configured identity, deduplicates and streams stages',
    () async {
      final runtime = ProbeRuntime();
      final a = site('a');
      final check = checker(runtime, [a]);
      final updates = <SiteCheckStatus>[];
      check.addListener(() {
        if (check.reports.isNotEmpty) updates.add(check.reports.first.status);
      });
      expect(runtime.homes, isEmpty);
      await check.run([a, a]);
      expect(runtime.homes, ['a']);
      expect(check.completed, 1);
      expect(check.reports.single.status, SiteCheckStatus.limited);
      expect(check.reports.single.stages.map((s) => s.phase), [
        SiteCheckPhase.runtime,
        SiteCheckPhase.home,
        SiteCheckPhase.category,
      ]);
      expect(check.reports.single.stages[1].itemCount, 1);
      expect(updates, contains(SiteCheckStatus.running));
      expect(check.reports.single.canCancelRequest, isTrue);
    },
  );

  test(
    'empty home can be limited with at most two safe distinct categories',
    () async {
      final runtime = ProbeRuntime()
        ..onHome = (_, _) async => const SiteResult(classes: classes);
      runtime.onCategory = (_, id, _) async =>
          id == '2' ? content() : const SiteResult();
      final a = site('a');
      final check = checker(runtime, [a]);
      await check.run([a]);
      expect(runtime.categories, ['1', '2']);
      expect(check.reports.single.status, SiteCheckStatus.limited);
      expect(check.reports.single.stages[1].status, SiteCheckStageStatus.empty);
      expect(check.reports.single.stages[1].categoryCount, 7);
      expect(check.reports.single.stages.last.itemCount, 1);
    },
  );

  test(
    'home and category content produce success but classes alone never do',
    () async {
      final runtime = ProbeRuntime()
        ..onHome = (_, _) async =>
            SiteResult(classes: classes, list: content().list);
      final a = site('a');
      final check = checker(runtime, [a]);
      await check.run([a]);
      expect(check.reports.single.status, SiteCheckStatus.success);
      expect(runtime.categories, ['1']);
      runtime.onHome = (_, _) async => const SiteResult(classes: classes);
      runtime.onCategory = (_, _, _) async =>
          const SiteResult(classes: classes);
      await check.run([a]);
      expect(check.reports.single.status, SiteCheckStatus.empty);
      expect(check.reports.single.stages.last.reason, isNotEmpty);
    },
  );

  test(
    'category failure is retained while next category can supply content',
    () async {
      final runtime = ProbeRuntime()
        ..onHome = (_, _) async => const SiteResult(classes: classes);
      runtime.onCategory = (_, id, _) async {
        if (id == '1') throw AppError(AppErrorKind.siteNetwork, '网络失败');
        return content();
      };
      final a = site('a');
      final check = checker(runtime, [a]);
      await check.run([a]);
      expect(check.reports.single.status, SiteCheckStatus.limited);
      expect(
        check.reports.single.stages[2].status,
        SiteCheckStageStatus.failed,
      );
      expect(check.reports.single.stages[2].reason, contains('网络失败'));
      expect(
        check.reports.single.stages[3].status,
        SiteCheckStageStatus.success,
      );
    },
  );

  test(
    'home errors and unavailable runtime do not erase other site results',
    () async {
      final runtime = ProbeRuntime()
        ..onHome = (s, _) async {
          if (s.key == 'bad') throw AppError(AppErrorKind.siteParse, '首页格式错误');
          return content();
        };
      final sites = [site('bad'), site('missing'), site('ok')];
      final check = checker(runtime, sites, unavailable: {'missing'});
      await check.run(sites);
      expect(check.completed, 3);
      expect(check.reports.map((r) => r.status), [
        SiteCheckStatus.failed,
        SiteCheckStatus.failed,
        SiteCheckStatus.limited,
      ]);
      expect(runtime.homes, isNot(contains('missing')));
      expect(check.reports[1].stages.first.phase, SiteCheckPhase.runtime);
      expect(check.reports[1].stages.first.reason, '运行时未安装');
    },
  );

  test(
    'default concurrency is two and each queue slot eventually runs',
    () async {
      final runtime = ProbeRuntime();
      final gates = <String, Completer<SiteResult>>{};
      var active = 0;
      var peak = 0;
      runtime.onHome = (s, _) async {
        active++;
        if (active > peak) peak = active;
        final gate = gates[s.key] = Completer<SiteResult>();
        try {
          return await gate.future;
        } finally {
          active--;
        }
      };
      final sites = List.generate(5, (i) => site('$i'));
      final check = checker(runtime, sites);
      final done = check.run(sites);
      await tick();
      expect(runtime.homes.length, 2);
      for (var i = 0; i < 5; i++) {
        gates['$i']!.complete(content());
        await tick();
      }
      await done;
      expect(peak, 2);
      expect(check.completed, 5);
    },
  );

  test(
    'cancel terminates queued and in flight sites and ignores late results',
    () async {
      final runtime = ProbeRuntime();
      final gate = Completer<SiteResult>();
      runtime.onHome = (_, _) => gate.future;
      final sites = [site('a'), site('b'), site('c')];
      final check = checker(runtime, sites, concurrency: 1);
      final done = check.run(sites);
      await tick();
      check.cancel();
      await done;
      expect(runtime.homes, ['a']);
      expect(runtime.signals.single.isCancelled, isTrue);
      expect(
        check.reports.every((r) => r.status == SiteCheckStatus.cancelled),
        isTrue,
      );
      expect(check.completed, 3);
      final reports = check.reports;
      gate.complete(content());
      await tick();
      expect(check.reports, reports);
    },
  );

  test(
    'whole site timeout signals siteTimeout and preserves prior stage',
    () async {
      final runtime = ProbeRuntime()
        ..onHome = (_, _) async => const SiteResult(classes: classes);
      final gate = Completer<SiteResult>();
      runtime.onCategory = (_, _, _) => gate.future;
      final a = site('a');
      final check = checker(runtime, [
        a,
      ], siteTimeout: const Duration(milliseconds: 25));
      await check.run([a]);
      expect(runtime.signals.single.reason?.kind, AppErrorKind.siteTimeout);
      expect(check.reports.single.status, SiteCheckStatus.timedOut);
      expect(check.reports.single.stages[1].status, SiteCheckStageStatus.empty);
      expect(
        check.reports.single.stages.last.status,
        SiteCheckStageStatus.timedOut,
      );
      gate.completeError(StateError('late error is observed'));
      await tick();
    },
  );

  test(
    'rerun isolates old batch and can finish despite a stalled legacy request',
    () async {
      final runtime = ProbeRuntime();
      final gate = Completer<SiteResult>();
      runtime.onHome = (_, _) => gate.future;
      final a = site('a');
      final check = checker(runtime, [a]);
      final old = check.run([a]);
      await tick();
      runtime.onHome = (_, _) async => const SiteResult();
      await check.run([a]);
      await old;
      expect(check.reports.single.status, SiteCheckStatus.empty);
      gate.complete(content());
      await tick();
      expect(check.reports.single.status, SiteCheckStatus.empty);
    },
  );

  test(
    'runtime reported timeout is a timeout terminal not a generic failure',
    () async {
      final runtime = ProbeRuntime()
        ..onHome = (_, _) async {
          throw AppError(AppErrorKind.siteTimeout, '请求超时');
        };
      final a = site('a');
      final check = checker(runtime, [a]);
      await check.run([a]);
      expect(check.reports.single.status, SiteCheckStatus.timedOut);
      expect(
        check.reports.single.stages.last.status,
        SiteCheckStageStatus.timedOut,
      );
    },
  );

  test(
    'category cancellation keeps home and never starts another category',
    () async {
      final runtime = ProbeRuntime()
        ..onHome = (_, _) async => const SiteResult(classes: classes);
      final gate = Completer<SiteResult>();
      runtime.onCategory = (_, _, _) => gate.future;
      final a = site('a');
      final check = checker(runtime, [a]);
      final done = check.run([a]);
      await tick();
      check.cancel();
      await done;
      expect(runtime.categories, ['1']);
      expect(check.reports.single.stages[1].status, SiteCheckStageStatus.empty);
      expect(check.reports.single.stages.last.phase, SiteCheckPhase.category);
      expect(
        check.reports.single.stages.last.status,
        SiteCheckStageStatus.cancelled,
      );
      gate.complete(content());
      await tick();
      expect(check.reports.single.status, SiteCheckStatus.cancelled);
    },
  );

  test('home and category share one cumulative timeout budget', () async {
    final runtime = ProbeRuntime()
      ..onHome = (_, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return const SiteResult(classes: classes);
      };
    runtime.onCategory = (_, _, _) async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return content();
    };
    final a = site('a');
    final check = checker(runtime, [
      a,
    ], siteTimeout: const Duration(milliseconds: 200));
    await check.run([a]);
    expect(runtime.signals.single.reason?.kind, AppErrorKind.siteTimeout);
    expect(check.reports.single.status, SiteCheckStatus.timedOut);
    expect(
      check.reports.single.stages[1].elapsed.inMilliseconds,
      greaterThanOrEqualTo(100),
    );
    expect(
      check.reports.single.stages.last.elapsed.inMilliseconds,
      lessThan(120),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(check.reports.single.status, SiteCheckStatus.timedOut);
  });

  test(
    'rejects more than 100 unique or foreign sites before network work',
    () async {
      final runtime = ProbeRuntime();
      final sites = List.generate(101, (i) => site('$i'));
      final check = checker(runtime, sites);
      await expectLater(check.run(sites), throwsArgumentError);
      await expectLater(check.run([site('foreign')]), throwsArgumentError);
      expect(runtime.homes, isEmpty);
    },
  );

  test('non cancellable runtime is explicitly marked as wait only', () async {
    final a = site('a');
    final runtime = LegacyRuntime();
    final router = ProbeRouter(runtime);
    addTearDown(router.dispose);
    final check = SiteSelfCheck(
      service: SiteService(
        appConfig: AppConfig(sites: [a]),
        router: router,
      ),
    );
    addTearDown(check.dispose);
    final done = check.run([a]);
    await tick();
    expect(check.reports.single.canCancelRequest, isFalse);
    check.cancel();
    await done;
    expect(check.reports.single.status, SiteCheckStatus.cancelled);
    runtime.gate.complete(content());
    await tick();
  });
}

class LegacyRuntime extends UnsupportedRuntime {
  LegacyRuntime() : super(runtimeName: 'legacy', reason: 'fixture');
  final gate = Completer<SiteResult>();
  @override
  Future<SiteResult> home(Site site) => gate.future;
}
