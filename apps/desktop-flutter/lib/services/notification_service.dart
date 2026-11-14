/// 追番系统通知（Phase 9 · P2-1 增强）。
///
/// 只做「把新集变成一条系统通知」这一件事，并把平台能力抽成 [SystemNotifier]：
/// 初始化失败、发送失败、平台不支持都返回 `false`，由调用方退回应用内提示
/// （侧栏徽标 + 追番页提示条）。任何失败都不向检查流程抛错。
///
/// 选型见 `docs/adr/0006-following-system-notification.md`。
library;

import 'package:local_notifier/local_notifier.dart';

import '../core/following.dart';
import 'log_service.dart';

/// 系统通知的平台能力（返回 `false` 或抛错都视为不可用）。
abstract interface class SystemNotifier {
  /// 初始化通知通道；`false` 表示本机不可用。
  Future<bool> initialize();

  /// 显示一条通知；`false` 表示发送失败。
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  });
}

/// Windows 实现（`local_notifier`，底层是 WinToast）。
class LocalNotifierAdapter implements SystemNotifier {
  LocalNotifierAdapter({this.onOpen});

  /// 用户点击通知时回传 payload（追番身份键）。
  final void Function(String payload)? onOpen;

  bool _setupOk = false;

  /// 同一部剧复用同一个通知对象：通知标识稳定，且监听器不会随发送次数累积
  /// （`LocalNotification` 构造时会把自身注册进 `LocalNotifier`）。
  final Map<int, LocalNotification> _notifications = {};

  @override
  Future<bool> initialize() async {
    if (_setupOk) return true;
    try {
      // `local_notifier` 把 appName 同时用作 AUMID（WinToast 的 toast 归属标识），
      // 必须稳定：换值后已登记的归属失效。默认策略会补一个开始菜单快捷方式。
      await LocalNotifier.instance.setup(appName: 'WebHTV');
      _setupOk = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    try {
      final notification =
          _notifications[id] ??
          (_notifications[id] = LocalNotification(
            identifier: 'webhtv-following-$id',
            title: title,
          ));
      notification.title = title;
      notification.body = body;
      notification.onClick = payload == null || payload.isEmpty
          ? null
          : () => onOpen?.call(payload);
      await notification.show();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 一次追番通知的结果。
class FollowingNotifyResult {
  const FollowingNotifyResult({
    required this.delivered,
    required this.title,
    required this.body,
    this.reason = '',
  });

  /// `true` = 系统通知已发出；`false` = 已降级为应用内提示。
  final bool delivered;
  final String title;
  final String body;

  /// 降级原因（`delivered` 时为空）。
  final String reason;

  bool get degraded => !delivered;
}

/// 一批新集的通知结果（含降级时要展示的应用内提示文案）。
class FollowingNotifyBatch {
  const FollowingNotifyBatch({
    required this.delivered,
    required this.degraded,
    required this.notice,
  });

  /// 系统通知成功的条数。
  final int delivered;

  /// 降级的条目描述（`剧名（新集信息）`）。
  final List<String> degraded;

  /// 应用内提示文案（空 = 无需提示）。
  final String notice;

  bool get hasDegraded => degraded.isNotEmpty;
}

/// 追番新集通知：优先系统通知，不可用时降级并在 [degradedReason] 留痕。
class FollowingNotifier {
  FollowingNotifier({
    SystemNotifier? platform,
    this.log,
    void Function(String payload)? onOpen,
  }) : _platform = platform ?? LocalNotifierAdapter(onOpen: onOpen);

  final SystemNotifier _platform;
  final LogService? log;

  bool _initTried = false;
  bool _available = false;
  String _degradedReason = '';

  /// 系统通知是否可用（首次尝试初始化后才有意义）。
  bool get systemAvailable => _available;

  /// 是否发生过降级（初始化或发送失败）。
  bool get degraded => _degradedReason.isNotEmpty;

  /// 最近一次降级原因（空 = 未降级）。
  String get degradedReason => _degradedReason;

  /// 逐条发通知并汇总；系统侧任何失败都只降级，不抛错。
  Future<FollowingNotifyBatch> notifyNewEpisodes(List<Following> items) async {
    final degraded = <String>[];
    var delivered = 0;
    for (final item in items) {
      final result = await notify(item: item);
      if (result.delivered) {
        delivered += 1;
      } else {
        degraded.add('${item.vodName}（${result.body}）');
      }
    }
    final notice = degraded.isEmpty
        ? ''
        : '系统通知不可用（${_degradedReason.isEmpty ? '未知原因' : _degradedReason}），'
              '已改用应用内提示：${degraded.join('、')}';
    return FollowingNotifyBatch(
      delivered: delivered,
      degraded: degraded,
      notice: notice,
    );
  }

  /// 发一条新集通知；系统侧任何失败都返回降级结果，不抛错。
  Future<FollowingNotifyResult> notify({required Following item}) async {
    final title = '${item.vodName} 有新集';
    final body = item.latestEpisodeName.isNotEmpty
        ? '${item.latestEpisodeName}（第 ${item.releasedEpisode} 集）'
        : '第 ${item.releasedEpisode} 集已可观看';
    if (await _ensureAvailable()) {
      try {
        final ok = await _platform.show(
          id: _notificationId(item),
          title: title,
          body: body,
          payload: item.identityKey,
        );
        if (ok) {
          _degradedReason = '';
          return FollowingNotifyResult(
            delivered: true,
            title: title,
            body: body,
          );
        }
      } catch (_) {
        // 落到下面的降级路径。
      }
      _markDegraded('系统通知发送失败');
    }
    return FollowingNotifyResult(
      delivered: false,
      title: title,
      body: body,
      reason: _degradedReason,
    );
  }

  Future<bool> _ensureAvailable() async {
    if (_initTried) return _available;
    _initTried = true;
    try {
      _available = await _platform.initialize();
    } catch (_) {
      _available = false;
    }
    if (!_available) _markDegraded('系统通知初始化失败');
    return _available;
  }

  void _markDegraded(String reason) {
    if (_degradedReason != reason) {
      _degradedReason = reason;
      log?.warning('追番通知降级为应用内提示：$reason', scope: 'following');
    }
  }

  /// 通知 id 按追番身份键稳定生成，避免同一部剧叠出多条。
  static int _notificationId(Following item) =>
      item.identityKey.hashCode & 0x7fffffff;
}
