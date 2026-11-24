import '../core/protocol.dart';
import '../core/request_cancellation.dart';

/// Optional request-local cancellation for active home/category probes.
abstract interface class CancellableProbeRuntime {
  Future<SiteResult> homeCancellable(
    Site site, {
    required RequestCancellation cancellation,
  });

  Future<SiteResult> categoryCancellable(
    Site site, {
    required String typeId,
    required int page,
    Map<String, String> filters = const {},
    required RequestCancellation cancellation,
  });
}
