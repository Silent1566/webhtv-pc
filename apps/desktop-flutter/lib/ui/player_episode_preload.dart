part of 'player_page.dart';

typedef _EpisodePreloadKey = ({String flag, int index, String target});
typedef _EpisodePreloadHints = ({
  SkipMode mode,
  int kinds,
  bool remote,
  int sources,
  SkipSegments manual,
});

extension _PlayerEpisodePreload on _PlayerPageState {
  bool get _canPreloadEpisodes => _episodePreloadBlocker == null;

  String? get _episodePreloadBlocker {
    if (!_options.preloadNext || !widget.state.playerOptions.preloadNext) {
      return 'preload_disabled';
    }
    if (_isLive ||
        _isCatchup ||
        _hasQueue ||
        _request.isLocal ||
        _request.directUrl) {
      return 'unsupported_playback_mode';
    }
    if (_request.lineRoutes.containsKey(_request.flag)) return 'routed_line';
    if (_parseSourceOverride != null) return 'manual_parse';
    if (_externalPlayerRunning != null) return 'external_player';
    if (_repeat == PlaybackRepeat.one) return 'repeat_one';
    if (!_options.autoNext && _repeat != PlaybackRepeat.all) {
      return 'auto_next_disabled';
    }
    if (_sleepTimer.shouldStopOnEpisodeEnd()) return 'episode_sleep_timer';
    return null;
  }

  _EpisodePreloadHints get _currentEpisodePreloadHints => (
    mode: _options.skipMode,
    kinds: _options.skipKinds,
    remote: _options.skipRemoteEnabled,
    sources: _options.skipSources,
    manual: _skipSegments,
  );

  _EpisodePreloadKey? _nextPreloadKey(int from) {
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (from < 0 || from >= episodes.length) return null;
    final tmdb = _request.tmdb;
    final next = tmdb != null && tmdb.hasSeason
        ? TmdbAutoPlay.nextIndex(
            episodes: episodes,
            currentIndex: from,
            availableSeasons: [tmdb.seasonNumber],
            selectedSeason: tmdb.seasonNumber,
          )
        : from + 1;
    if (next < 0 ||
        next >= episodes.length ||
        episodes[next].url == episodes[from].url) {
      return null;
    }
    return (flag: _request.flag, index: next, target: episodes[next].url);
  }

  void _resetEpisodePreloads({
    _EpisodePreloadKey? keep,
    bool resetBatches = true,
  }) {
    _episodePreloadRevision++;
    final state = widget.state;
    _episodePreloadLeases.removeWhere((key, lease) {
      if (key == keep) return false;
      state.discardEpisodePreload(lease);
      return true;
    });
    if (keep == null) _episodePreloadHints = null;
    if (resetBatches) {
      _episodeEarlyStarted = false;
      _episodeEndingStarted = false;
    }
  }

  void _maybePrimeEpisodePreload({Duration? seekTarget}) {
    if (!_canPreloadEpisodes) {
      if (_episodePreloadLeases.isNotEmpty) _resetEpisodePreloads();
      widget.state.setEpisodePreloadPaused(true);
      return;
    }
    final state = widget.state;
    final playing =
        _progressReady &&
        _loadError == null &&
        _controller.isPlaying &&
        !_controller.isBuffering &&
        !_controller.isLoading &&
        !_controller.isSeeking &&
        !_controller.isRepositioning &&
        !_controller.isCompleted;
    final position = seekTarget ?? _controller.position;
    final speed = _controller.rate.clamp(0.25, 4.0);
    final ahead = (_controller.buffered - position).inMilliseconds;
    state.setEpisodePreloadPaused(
      !playing || seekTarget != null,
      allowManifestOverlap:
          playing && seekTarget == null && ahead >= 15000 * speed,
    );
    if (!playing &&
        (seekTarget == null || !_progressReady || _loadError != null)) {
      return;
    }
    final hints = _currentEpisodePreloadHints;
    if (_episodePreloadHints != null && _episodePreloadHints != hints) {
      _resetEpisodePreloads();
    }
    final batch = episodePreloadBatch(
      positionMs: position.inMilliseconds,
      durationMs: _controller.duration.inMilliseconds,
      bufferedMs: _controller.buffered.inMilliseconds,
      rate: _controller.rate,
      plan: _skipPlan,
      mode: hints.mode,
      kinds: hints.kinds,
      handled: _skipHandled,
      earlyStarted: _episodeEarlyStarted,
      endingStarted: _episodeEndingStarted,
      preparingForSeek: seekTarget != null,
    );
    if (batch == null) return;
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (_aggregatedEpisodeGroups(episodes) != null) return;
    final first = _nextPreloadKey(_request.episodeIndex);
    if (first == null) return;
    if (batch == EpisodePreloadBatch.early) {
      _episodeEarlyStarted = true;
    } else {
      _episodeEndingStarted = true;
    }
    final retained = _episodePreloadLeases[first];
    final ready = retained != null && state.episodePreloadReady(retained);
    if (batch == EpisodePreloadBatch.ending && ready) return;
    _resetEpisodePreloads(keep: ready ? first : null, resetBatches: false);
    _episodePreloadHints = hints;
    final second = batch == EpisodePreloadBatch.early
        ? _nextPreloadKey(first.index)
        : null;
    state.log.debug(
      '下一集预载调度 batch=${batch.name} '
      'position=${position.inMilliseconds}ms seek=${seekTarget != null} '
      'buffered=${_controller.buffered.inMilliseconds}ms',
      scope: 'preload',
    );
    unawaited(_prepareEpisodeBatch(episodes, first, second, hints));
  }

  Future<void> _prepareEpisodeBatch(
    List<VodEpisode> episodes,
    _EpisodePreloadKey first,
    _EpisodePreloadKey? second,
    _EpisodePreloadHints hints,
  ) async {
    final revision = _episodePreloadRevision;
    final request = _request;
    final flag = request.playbackFlag;
    final state = widget.state;
    bool current() =>
        mounted &&
        revision == _episodePreloadRevision &&
        _canPreloadEpisodes &&
        _currentEpisodePreloadHints == hints;
    for (final key in [first, ?second]) {
      if (!current()) return;
      if (_episodePreloadLeases.containsKey(key)) continue;
      final identity = _identityForEpisode(episodes[key.index], key.flag);
      final preload = state.prepareEpisodePreload(
        currentMediaUrl: request.url,
        sourceKey: request.sourceKey,
        siteKey: request.siteKey,
        episodeTarget: key.target,
        flag: flag,
        vodId: request.vodId,
        immediateNext: key == first,
        isCurrent: current,
        startAt: (durationMs) => _episodeOpening(durationMs, identity, hints),
      );
      if (preload == null) return;
      _episodePreloadLeases[key] = preload;
      await preload.prepared;
    }
  }

  Future<int> _episodeOpening(
    int durationMs,
    TmdbPlaybackIdentity? identity,
    _EpisodePreloadHints hints,
  ) async {
    if (hints.mode != SkipMode.auto ||
        (hints.kinds & SkipKind.intro.bit) == 0) {
      return 0;
    }
    var raw = const <RawSkipSegment>[];
    if (hints.manual.introEndMs == null &&
        hints.remote &&
        identity != null &&
        identity.hasIdentity) {
      final result = await lookupIntroSkip(
        query: SkipQuery(
          tmdbId: identity.tmdbId,
          imdbId: identity.imdbId,
          mediaType: identity.mediaType.name,
          season: identity.seasonNumber,
          episode: identity.episodeNumber,
          durationMs: durationMs,
        ),
        providers: buildIntroSkipProviders(hints.sources),
        timeout: const Duration(seconds: 2),
      );
      raw = result.segments;
    }
    return episodePreloadStart(
      durationMs: durationMs,
      plan: SkipPlan.resolve(
        raw,
        durationMs: durationMs,
      ).withManualOverride(manual: hints.manual, durationMs: durationMs),
      mode: hints.mode,
      kinds: hints.kinds,
    );
  }
}
