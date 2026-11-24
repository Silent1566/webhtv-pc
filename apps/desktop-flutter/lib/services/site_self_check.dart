import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../core/request_cancellation.dart';
import 'cancellable_probe_runtime.dart';
import 'site_service.dart';

enum SiteCheckPhase { runtime, home, category }

enum SiteCheckStageStatus {
  running,
  success,
  empty,
  failed,
  timedOut,
  cancelled,
}

enum SiteCheckStatus {
  queued,
  running,
  success,
  limited,
  empty,
  failed,
  timedOut,
  cancelled,
}

@immutable
class SiteCheckStage {
  const SiteCheckStage({
    required this.phase,
    required this.status,
    this.category,
    this.reason,
    this.itemCount = 0,
    this.categoryCount = 0,
    this.elapsed = Duration.zero,
  });
  final SiteCheckPhase phase;
  final SiteCheckStageStatus status;
  final String? category;
  final String? reason;
  final int itemCount;
  final int categoryCount;
  final Duration elapsed;
}

@immutable
class SiteCheckReport {
  SiteCheckReport({
    required this.site,
    required this.status,
    this.canCancelRequest,
    List<SiteCheckStage> stages = const [],
    this.elapsed = Duration.zero,
  }) : stages = List.unmodifiable(stages);
  final Site site;
  final SiteCheckStatus status;
  final bool? canCancelRequest;
  final List<SiteCheckStage> stages;
  final Duration elapsed;
  bool get isTerminal =>
      status != SiteCheckStatus.queued && status != SiteCheckStatus.running;
}

/// A user-owned batch. Never owns a shared runtime, client, or browser selection.
class SiteSelfCheck extends ChangeNotifier {
  SiteSelfCheck({
    required this.service,
    this.concurrency = 2,
    this.siteTimeout = const Duration(seconds: 30),
  }) {
    if (concurrency < 1 || concurrency > 2) {
      throw ArgumentError.value(concurrency, 'concurrency');
    }
    if (siteTimeout <= Duration.zero ||
        siteTimeout > const Duration(seconds: 30)) {
      throw ArgumentError.value(siteTimeout, 'siteTimeout');
    }
  }
  static const maxSites = 100;
  final SiteService service;
  final int concurrency;
  final Duration siteTimeout;
  List<SiteCheckReport> _reports = const [];
  final Map<String, RequestCancellation> _active = {};
  final Map<String, Stopwatch> _clocks = {};
  int _generation = 0;
  bool _disposed = false;
  bool _running = false;
  List<SiteCheckReport> get reports => _reports;
  bool get running => _running;
  int get completed => _reports.where((r) => r.isTerminal).length;

  Future<void> run(Iterable<Site> selected) async {
    if (_disposed) return;
    final configured = {
      for (final site in service.appConfig.sites) site.key: site,
    };
    final unique = <String, Site>{};
    for (final site in selected) {
      final current = configured[site.key];
      if (current == null) throw ArgumentError('站点不属于当前配置');
      unique[site.key] = current;
      if (unique.length > maxSites) throw ArgumentError('每批最多 100 个站点');
    }
    cancel();
    final generation = ++_generation;
    final sites = unique.values.toList();
    _reports = List.unmodifiable([
      for (final site in sites)
        SiteCheckReport(site: site, status: SiteCheckStatus.queued),
    ]);
    _running = sites.isNotEmpty;
    notifyListeners();
    var cursor = 0;
    Future<void> worker() async {
      while (_current(generation) && cursor < sites.length) {
        final index = cursor++;
        await _probe(index, sites[index], generation);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (_current(generation)) {
      _running = false;
      notifyListeners();
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _put(int index, SiteCheckReport report, int generation) {
    if (!_current(generation)) return;
    _reports = List.unmodifiable([
      ..._reports.take(index),
      report,
      ..._reports.skip(index + 1),
    ]);
    notifyListeners();
  }

  Future<void> _probe(int index, Site site, int generation) async {
    final clock = Stopwatch()..start();
    final signal = RequestCancellation();
    _active[site.key] = signal;
    _clocks[site.key] = clock;
    final timer = Timer(
      siteTimeout,
      () => signal.cancel(
        AppError(
          AppErrorKind.siteTimeout,
          '单站体检超过 ${siteTimeout.inMilliseconds / 1000} 秒预算',
        ),
      ),
    );
    final stages = <SiteCheckStage>[];
    bool? cancellable;
    void publish([SiteCheckStatus status = SiteCheckStatus.running]) => _put(
      index,
      SiteCheckReport(
        site: site,
        status: status,
        canCancelRequest: cancellable,
        stages: stages,
        elapsed: clock.elapsed,
      ),
      generation,
    );
    Future<SiteResult?> stage(
      SiteCheckPhase phase,
      Future<SiteResult> Function() call, {
      String? category,
    }) async {
      signal.throwIfCancelled();
      final start = clock.elapsed;
      stages.add(
        SiteCheckStage(
          phase: phase,
          status: SiteCheckStageStatus.running,
          category: category,
        ),
      );
      publish();
      try {
        final value = await signal.bind(Future.sync(call));
        signal.throwIfCancelled();
        stages[stages.length - 1] = SiteCheckStage(
          phase: phase,
          status: value.list.isEmpty
              ? SiteCheckStageStatus.empty
              : SiteCheckStageStatus.success,
          category: category,
          itemCount: value.list.length,
          categoryCount: value.classes.length,
          elapsed: clock.elapsed - start,
          reason: value.list.isEmpty ? '未返回内容条目' : null,
        );
        publish();
        return value;
      } catch (error) {
        final appError = error is AppError
            ? error
            : AppError(AppErrorKind.siteBusiness, '站点调用失败');
        final status = appError.kind == AppErrorKind.siteTimeout
            ? SiteCheckStageStatus.timedOut
            : appError.kind == AppErrorKind.siteCancelled
            ? SiteCheckStageStatus.cancelled
            : SiteCheckStageStatus.failed;
        stages[stages.length - 1] = SiteCheckStage(
          phase: phase,
          status: status,
          category: category,
          elapsed: clock.elapsed - start,
          reason: appError.message,
        );
        publish();
        if (appError.kind == AppErrorKind.siteTimeout ||
            appError.kind == AppErrorKind.siteCancelled) {
          signal.cancel(appError);
        }
        if (signal.isCancelled) rethrow;
        return null;
      }
    }

    try {
      publish();
      final availability = service.router.classifySite(site);
      if (!availability.available) {
        stages.add(
          SiteCheckStage(
            phase: SiteCheckPhase.runtime,
            status: SiteCheckStageStatus.failed,
            reason: availability.reason ?? '运行时不可用',
            elapsed: clock.elapsed,
          ),
        );
        publish(SiteCheckStatus.failed);
        return;
      }
      cancellable = service.router.runtimeFor(site) is CancellableProbeRuntime;
      signal.throwIfCancelled();
      stages.add(
        SiteCheckStage(
          phase: SiteCheckPhase.runtime,
          status: SiteCheckStageStatus.success,
          reason: availability.runtimeName,
          elapsed: clock.elapsed,
        ),
      );
      publish();
      final home = await stage(
        SiteCheckPhase.home,
        () async => (await service.home(site, cancellation: signal)).value,
      );
      final seen = <String>{};
      final candidates = (home?.classes ?? const <VodClass>[])
          .where((category) {
            if (category.typeId.trim().isEmpty || !seen.add(category.typeId)) {
              return false;
            }
            return !RegExp(
              r'配置|设置|登录|登錄|登入|设定|設定|config|setting|login|sign[ -]?in',
              caseSensitive: false,
            ).hasMatch('${category.typeId} ${category.typeName}');
          })
          .take(2)
          .toList();
      if (candidates.isEmpty) {
        stages.add(
          SiteCheckStage(
            phase: SiteCheckPhase.category,
            status: SiteCheckStageStatus.empty,
            reason: home == null ? '首页失败，未取得可检查分类' : '没有适合检查的内容分类',
          ),
        );
        publish();
      } else {
        for (final category in candidates) {
          final result = await stage(
            SiteCheckPhase.category,
            () async => (await service.category(
              site,
              typeId: category.typeId,
              page: 1,
              cancellation: signal,
            )).value,
            category: category.typeName,
          );
          if (result != null && result.list.isNotEmpty) break;
        }
      }
      signal.throwIfCancelled();
      final hasHome = home?.list.isNotEmpty ?? false;
      final hasCategory = stages.any(
        (s) =>
            s.phase == SiteCheckPhase.category &&
            s.status == SiteCheckStageStatus.success,
      );
      final hasFailure = stages.any(
        (s) =>
            s.status == SiteCheckStageStatus.failed ||
            s.status == SiteCheckStageStatus.timedOut,
      );
      publish(
        hasHome && hasCategory && !hasFailure
            ? SiteCheckStatus.success
            : hasHome || hasCategory
            ? SiteCheckStatus.limited
            : hasFailure
            ? SiteCheckStatus.failed
            : SiteCheckStatus.empty,
      );
    } catch (error) {
      if (!_current(generation)) return;
      final reason =
          signal.reason ??
          (error is AppError
              ? error
              : AppError(AppErrorKind.siteBusiness, '运行时检查失败'));
      final timedOut = reason.kind == AppErrorKind.siteTimeout;
      if (stages.isEmpty ||
          (stages.last.status != SiteCheckStageStatus.timedOut &&
              stages.last.status != SiteCheckStageStatus.cancelled)) {
        stages.add(
          SiteCheckStage(
            phase: stages.isEmpty ? SiteCheckPhase.runtime : stages.last.phase,
            status: timedOut
                ? SiteCheckStageStatus.timedOut
                : signal.isCancelled
                ? SiteCheckStageStatus.cancelled
                : SiteCheckStageStatus.failed,
            reason: reason.message,
          ),
        );
      }
      publish(
        timedOut
            ? SiteCheckStatus.timedOut
            : signal.isCancelled
            ? SiteCheckStatus.cancelled
            : SiteCheckStatus.failed,
      );
    } finally {
      timer.cancel();
      clock.stop();
      if (identical(_active[site.key], signal)) {
        _active.remove(site.key);
        _clocks.remove(site.key);
      }
    }
  }

  void cancel() {
    if (_disposed || !_running) return;
    _generation++;
    for (final signal in _active.values) {
      signal.cancel();
    }
    _reports = List.unmodifiable(
      _reports.map((report) {
        if (report.isTerminal) return report;
        final elapsed = _clocks[report.site.key]?.elapsed ?? report.elapsed;
        final stages = [...report.stages];
        if (stages.isNotEmpty &&
            stages.last.status == SiteCheckStageStatus.running) {
          final prior = stages.removeLast();
          stages.add(
            SiteCheckStage(
              phase: prior.phase,
              status: SiteCheckStageStatus.cancelled,
              category: prior.category,
              reason: '用户取消，已停止等待',
              elapsed: elapsed - report.elapsed,
            ),
          );
        } else {
          stages.add(
            const SiteCheckStage(
              phase: SiteCheckPhase.runtime,
              status: SiteCheckStageStatus.cancelled,
              reason: '用户取消，未继续调度',
            ),
          );
        }
        return SiteCheckReport(
          site: report.site,
          status: SiteCheckStatus.cancelled,
          canCancelRequest: report.canCancelRequest,
          stages: stages,
          elapsed: elapsed,
        );
      }),
    );
    _active.clear();
    _clocks.clear();
    _running = false;
    notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    _disposed = true;
    super.dispose();
  }
}
