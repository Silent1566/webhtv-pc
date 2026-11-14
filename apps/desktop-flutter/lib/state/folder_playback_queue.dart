import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_error.dart';
import '../core/playback.dart';
import '../core/playback_queue.dart';
import '../core/playback_request.dart';
import '../core/protocol.dart';
import 'app_state.dart';
import 'folder_browser_state.dart';

/// A route-owned view of the browser, resolving only the selected file.
class FolderPlaybackQueue extends ChangeNotifier implements PlaybackQueue {
  FolderPlaybackQueue({
    required this.state,
    required this.browser,
    this.sourceKey = '',
    this.resumeItemKey,
  }) {
    browser.addListener(_changed);
  }

  final AppState state;
  final FolderBrowserState browser;
  final String sourceKey;

  /// 当前播放会话首个可续播的文件身份（分页可先创建队列）。
  String? resumeItemKey;
  bool _disposed = false;
  bool _loadingMore = false;
  bool _resumed = false;
  Future<void>? _inflightLoad;
  Completer<void>? _browserWait;

  /// A directory click starts a new session; in-player resolves do not.
  void startPlaybackSession(String itemKey) {
    resumeItemKey = itemKey;
    _resumed = false;
  }

  List<Vod> get videos =>
      browser.items.where(isVideoCandidate).toList()..sort((a, b) {
        final order = naturalCompare(a.vodName, b.vodName);
        return order == 0 ? a.vodId.compareTo(b.vodId) : order;
      });

  @override
  PlaybackQueueSnapshot get snapshot => PlaybackQueueSnapshot(
    items: videos
        .map((v) => PlaybackQueueItem(key: v.vodId, title: v.vodName))
        .toList(),
    hasMore: browser.hasMore,
    loading: browser.loading || _loadingMore,
    error: browser.error,
  );

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Callers await page completion; concurrent calls share the same page run.
  @override
  Future<void> loadMore() {
    if (_disposed) return Future<void>.value();
    final inflight = _inflightLoad;
    if (inflight != null) return inflight;
    final future = _loadMore();
    _inflightLoad = future;
    return future.whenComplete(() {
      if (identical(_inflightLoad, future)) _inflightLoad = null;
    });
  }

  Future<void> _loadMore() async {
    final before = videos.map((v) => v.vodId).toSet();
    _loadingMore = true;
    _changed();
    try {
      await _settleBrowser();
      do {
        if (_disposed) return;
        if (browser.error != null) {
          await browser.retry();
        } else if (browser.page == 0) {
          await browser.load();
        } else {
          await browser.loadMore();
        }
        if (_disposed || browser.error != null) return;
      } while (browser.hasMore &&
          !videos.any((v) => !before.contains(v.vodId)));
    } finally {
      _loadingMore = false;
      _changed();
    }
  }

  /// A page already in flight (initial load, refresh) must finish before we page.
  Future<void> _settleBrowser() async {
    while (!_disposed && browser.loading) {
      final done = Completer<void>();
      _browserWait = done;
      void listener() {
        if (!done.isCompleted) done.complete();
      }

      browser.addListener(listener);
      if (!browser.loading && !done.isCompleted) done.complete();
      try {
        await done.future;
      } finally {
        try {
          browser.removeListener(listener);
        } catch (_) {
          // 浏览器已随路由销毁：监听随之丢弃，无需（也不能）再摘。
        }
        if (identical(_browserWait, done)) _browserWait = null;
      }
    }
  }

  @override
  Future<PlaybackRequest> resolve(
    String itemKey, {
    bool Function()? isCurrent,
  }) async {
    bool current() => !_disposed && (isCurrent?.call() ?? true);
    void checkCurrent() {
      if (!current()) throw AppError(AppErrorKind.siteCancelled, '播放请求已取消');
    }

    checkCurrent();
    final candidates = videos.where((v) => v.vodId == itemKey);
    if (candidates.isEmpty) {
      throw AppError(AppErrorKind.playbackUrlMissing, '目录中没有此视频');
    }
    final item = candidates.first;
    // 详情返回的条目才是权威身份：站点会重写 vod_id/vod_name（既有详情页同样以返回
    // 条目为准），但队列 key 始终是列表里那个文件 id，不随详情漂移。
    var vod = item;
    if (parseVodPlayLines(vod).isEmpty) {
      final result = (await browser.service.detail(
        browser.site,
        item.vodId,
        identity: VodIdentityHint(vodId: item.vodId, vodName: item.vodName),
      )).value;
      checkCurrent();
      if (result.list.isNotEmpty) {
        vod = result.list.firstWhere(
          (entry) => entry.vodId == item.vodId,
          orElse: () => result.list.first,
        );
      }
    }
    final lines = parseVodPlayLines(vod)
        .where((line) => line.episodes.isNotEmpty)
        .map((line) => state.applyAiMappingsToLine(vod, line))
        .toList();
    if (lines.isEmpty) {
      throw AppError(AppErrorKind.playbackUrlMissing, '此文件没有可播放的视频');
    }
    final line = lines.first;
    final episode = line.episodes.first;
    checkCurrent();
    final decision = await state.resolvePlayback(
      episodeTarget: episode.url,
      flag: line.playbackFlag,
      vodId: vod.vodId,
      siteOverride: browser.site,
      serviceOverride: browser.service,
      isCurrent: current,
    );
    checkCurrent();
    if (decision?.url == null || decision!.url!.isEmpty) {
      throw AppError(AppErrorKind.playbackUrlMissing, '播放决策没有返回可用地址');
    }
    final resume = !_resumed && itemKey == resumeItemKey
        ? state.resumePositionFor(
            siteKey: browser.site.key,
            vodId: vod.vodId,
            flag: line.playbackFlag,
            episodeId: episode.url,
            episodeName: item.vodName,
            sourceKey: sourceKey.isEmpty ? null : sourceKey,
          )
        : null;
    _resumed = true;
    return PlaybackRequest(
      url: decision.url!,
      title: browser.folder.vodName,
      siteKey: browser.site.key,
      sourceKey: sourceKey,
      vodId: vod.vodId,
      vodName: vod.vodName.isEmpty ? item.vodName : vod.vodName,
      episodeName: item.vodName,
      episodeTarget: episode.url,
      flag: line.flag,
      playbackFlag: line.playbackFlag,
      headers: decision.headers?.asRequestHeaders ?? const {},
      qualities: decision.qualities,
      qualityIndex: decision.qualityIndex,
      playLines: lines,
      episodeIndex: 0,
      vodPic: vod.vodPic ?? item.vodPic,
      startPosition: resume,
      subtitles: decision.subs,
      danmaku: decision.danmaku,
      subtitleHeaders: decision.assetHeaders?.asRequestHeaders ?? const {},
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _inflightLoad = null;
    final waiting = _browserWait;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    browser.removeListener(_changed);
    super.dispose();
  }
}

const Set<String> _nonVideoExtensions = {
  'srt',
  'ass',
  'ssa',
  'vtt',
  'sub',
  'idx',
  'txt',
  'nfo',
  'pdf',
  'json',
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'svg',
  'zip',
  'rar',
  '7z',
  'iso',
  'torrent',
  'url',
  'mp3',
  'flac',
  'wav',
  'aac',
  'm4a',
  'ape',
};

/// 文件候选 = 非目录、非动作项、非明显非视频附件；无后缀标题留给详情确认。
bool isVideoCandidate(Vod item) {
  if (item.isFolder || isBridgeFolderVodId(item.vodId)) return false;
  if (item.vodTag == 'action' || item.extra['action'] != null) return false;
  final name = item.vodName.trim();
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return true;
  return !_nonVideoExtensions.contains(name.substring(dot + 1).toLowerCase());
}

int naturalCompare(String a, String b) {
  final chunks = RegExp(r'[0-9]+|[^0-9]+');
  final left = chunks
      .allMatches(a.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  final right = chunks
      .allMatches(b.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = BigInt.tryParse(left[i]);
    final y = BigInt.tryParse(right[i]);
    final order = x != null && y != null
        ? x.compareTo(y)
        : left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  return left.length.compareTo(right.length);
}
