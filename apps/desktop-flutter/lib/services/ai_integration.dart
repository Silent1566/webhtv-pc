import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ad_rules.dart';
import '../core/ai_config.dart';
import '../core/audio_ai/audio_ai.dart';
import 'karaoke/karaoke_controller.dart';
import 'karaoke/track_repository.dart';
import 'karaoke/windows_mic_source.dart';
import '../core/karaoke/ultrastar_parser.dart';
import '../core/ai_content/ad_rule_validation.dart';
import '../core/ai_content/group_rule_validation.dart';
import '../core/protocol.dart';
import '../core/tmdb_playback.dart';
import '../core/site_group_rules.dart';
import '../core/tmdb_identity.dart';
import 'ai_content/ad_rule_service.dart';
import 'ai_content/ai_content_completion.dart';
import 'ai_content/ai_content_paths.dart';
import 'ai_content/group_rule_service.dart';
import 'ai_content/log_diagnosis_service.dart';
import 'ai_content/profile_service.dart';
import 'ai_content/recommendation_service.dart';
import 'ai_content/title_resolution_service.dart';
import 'ai_content/user_data_store.dart';
import 'app_paths.dart';
import 'log_service.dart';

class AiPlaylistSnapshot {
  const AiPlaylistSnapshot({
    required this.playlist,
    required this.evidence,
    required this.siteKey,
    required this.sessionFingerprint,
  });
  final Uri playlist;
  final AdPlaylistEvidence evidence;
  final String siteKey;
  final String sessionFingerprint;
  String get signature => jsonEncode([
    siteKey,
    sessionFingerprint,
    playlist.toString(),
    evidence.segments,
  ]);
}

class AiIntegration {
  AiIntegration({
    required AppPaths paths,
    required AiConfig Function() config,
    required bool Function() titleEnabled,
    required LogService log,
    RecommendationEnricher? enricher,
    AiContentCompletion? completion,
  }) {
    final contentPaths = AiContentPaths.of(paths);
    userData = AiContentUserDataStore(paths: contentPaths, log: log);
    recommendation = RecommendationService(
      config: config,
      paths: contentPaths,
      userData: userData,
      enricher: enricher,
      completion: completion,
      log: log,
    );
    title = TitleResolutionService(
      config: config,
      paths: contentPaths,
      userData: userData,
      aiEnabled: () => titleEnabled() && config().isReady,
      completion: completion,
      log: log,
    );
    group = GroupRuleService(
      config: config,
      paths: contentPaths,
      userData: userData,
      completion: completion,
      log: log,
    );
    ad = AdRuleService(
      config: config,
      paths: contentPaths,
      userData: userData,
      completion: completion,
      log: log,
    );
    diagnosis = LogDiagnosisService(
      config: config,
      completion: completion,
      log: log,
    );
    profile = ViewingProfileService(
      config: config,
      paths: contentPaths,
      completion: completion,
      log: log,
    );
  }
  late final AiContentUserDataStore userData;
  late final RecommendationService recommendation;
  late final TitleResolutionService title;
  late final GroupRuleService group;
  late final AdRuleService ad;
  late final LogDiagnosisService diagnosis;
  late final ViewingProfileService profile;
}

SiteGroupSettings mergeAiGroupRules(
  SiteGroupSettings current,
  List<GroupRuleProposal> rules,
) => current.copyWith(
  rules: [
    for (final rule in current.rules)
      if (!rule.id.startsWith('ai-content-')) rule,
    for (var i = 0; i < rules.length; i++)
      SiteGroupRule(
        id: 'ai-content-$i',
        name: rules[i].name,
        pattern: rules[i].regex,
      ),
  ],
);

AdRuleSet mergeAiAdRules(
  AdRuleSet manual,
  List<AdRuleProposal> proposals,
  Uri playlist,
) => AdRuleSet(
  adHosts: manual.adHosts,
  hlsRules: [
    ...manual.hlsRules,
    for (var i = 0; i < proposals.length; i++)
      HlsAdRule(
        id: 'ai-content-$i',
        playlistHostSuffixes: [playlist.host],
        playlistPath: playlist.path,
        hostSuffixes: proposals[i].hostsBlacklist,
        segmentUrlRegex: proposals[i].regexPatterns,
        excludeUrlRegex: proposals[i].excludePatterns,
      ),
  ],
);

AdPlaylistEvidence collectAdPlaylistEvidence(String text, Uri playlist) {
  final segments = <String>[];
  final durations = <double>[];
  final discontinuities = <int>[];
  final switches = <bool>[];
  double? duration;
  var discontinuity = false;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      duration = double.tryParse(line.substring(8).split(',').first);
    } else if (line == '#EXT-X-DISCONTINUITY') {
      discontinuity = true;
    } else if (!line.startsWith('#') && line.isNotEmpty && duration != null) {
      final uri = playlist.resolve(line);
      if (uri.scheme == 'https' || uri.scheme == 'http') {
        if (discontinuity) discontinuities.add(segments.length);
        segments.add(uri.toString());
        durations.add(duration);
        switches.add(uri.host != playlist.host);
      }
      duration = null;
      discontinuity = false;
    }
  }
  return AdPlaylistEvidence(
    segments: segments,
    durations: durations,
    discontinuities: discontinuities,
    domainSwitches: switches,
  );
}

VodPlayLine applyAiEpisodeBindings(
  VodPlayLine line,
  Map<int, ({int season, int episode})> bindings,
) => line.copyWith(
  episodes: [
    for (var i = 0; i < line.episodes.length; i++)
      if (bindings[i] case final binding?)
        line.episodes[i].copyWith(
          extra: {
            ...line.episodes[i].extra,
            'tmdb_season_number': binding.season,
            'tmdb_episode_number': binding.episode,
            'display_name':
                'S${binding.season}E${binding.episode} ${line.episodes[i].name}',
          },
        )
      else
        line.episodes[i],
  ],
);

TmdbItem? pickRecommendationTmdbItem(
  List<TmdbItem> candidates,
  String title,
  TmdbMediaType type,
  int? year,
) {
  final normalized = title
      .replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '')
      .toLowerCase();
  for (final item in candidates) {
    if (item.mediaType != type) continue;
    if (item.title
            .replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '')
            .toLowerCase() !=
        normalized) {
      continue;
    }
    if (year != null && !item.subtitle.contains('$year')) continue;
    return item;
  }
  return null;
}

const aiBackupUserDataFile = 'ai-user-data.json';
const aiBackupReaderFile = 'reader.json';
const _aiUserFiles = {
  'recommendation_feedback.json',
  'title_learning.json',
  'group_rules.json',
  'ad_rules.json',
};

Future<String> exportAiUserFiles(AppPaths paths) async {
  final directory = AiContentPaths.of(paths).dataDir;
  final files = <String, Object?>{};
  for (final name in _aiUserFiles) {
    final file = File(p.join(directory, name));
    if (await file.exists()) {
      files[name] = jsonDecode(await file.readAsString());
    }
  }
  return jsonEncode({'schemaVersion': 1, 'files': files});
}

Map<String, Object?> decodeAiUserFiles(String raw) {
  final root = jsonDecode(raw);
  if (root is! Map || root['schemaVersion'] != 1 || root['files'] is! Map) {
    throw const FormatException('AI用户数据格式或版本不支持');
  }
  final files = <String, Object?>{};
  for (final entry in (root['files'] as Map).entries) {
    if (!_aiUserFiles.contains(entry.key) || entry.value is! Map) {
      throw const FormatException('AI用户数据含未知路径或损坏域');
    }
    final listKey = entry.key == 'recommendation_feedback.json'
        ? 'entries'
        : entry.key == 'title_learning.json'
        ? 'examples'
        : 'rules';
    if ((entry.value as Map)[listKey] is! List) {
      throw const FormatException('AI用户域内容结构损坏，拒绝覆盖');
    }
    files[entry.key as String] = entry.value;
  }
  return files;
}

Future<void> importAiUserFiles(
  AppPaths paths,
  String raw, {
  bool replace = false,
}) async {
  final files = decodeAiUserFiles(raw);
  final directory = AiContentPaths.of(paths).dataDir;
  await Directory(directory).create(recursive: true);
  if (replace) {
    for (final name in _aiUserFiles) {
      final file = File(p.join(directory, name));
      if (!files.containsKey(name) && await file.exists()) await file.delete();
    }
  }
  for (final entry in files.entries) {
    final file = File(p.join(directory, entry.key));
    final temp = File('${file.path}.integration.tmp');
    await temp.writeAsString(jsonEncode(entry.value), flush: true);
    await temp.rename(file.path);
  }
}

class PlayerAudioAiSession {
  PlayerAudioAiSession({
    required AppPaths paths,
    required AiConfig config,
    String language = 'en',
    String? modelId,
  }) : clock = AudioSessionClock(),
       karaokeClock = AudioSessionClock(),
       capture = WindowsAudioCapture(),
       models = AudioModelManager(
         root: Directory(p.join(paths.cacheDir, 'audio_ai', 'models')),
       ),
       model =
           RealtimeModelCatalog.byId(modelId ?? '') ??
           RealtimeModelCatalog.models.first {
    karaokeRepository = KaraokeTrackRepository(
      Directory(p.join(paths.dataDir, 'karaoke')),
      cacheDirectory: Directory(p.join(paths.cacheDir, 'karaoke')),
    );
    // F created this source, so F owns its dispose (controller only disposes
    // the source it created itself when `mic == null`).
    micSource = WindowsKaraokeMicSource();
    karaoke = KaraokeController(
      clock: karaokeClock,
      repository: karaokeRepository,
      mic: micSource,
    );
    realtime = RealtimeSubtitleController(
      models: models,
      config: config,
      sourceLanguage: language,
      runner: config.isReady ? AiPrompt.fromConfig(config) : null,
    );
  }
  final AudioSessionClock clock;
  final AudioSessionClock karaokeClock;
  late final KaraokeTrackRepository karaokeRepository;
  late final KaraokeController karaoke;
  late final WindowsKaraokeMicSource micSource;
  bool _micDisposed = false;

  /// F 创建的麦克风是否已释放（所有权闭合的可观测证据）。
  bool get micDisposed => _micDisposed;
  final WindowsAudioCapture capture;
  final AudioModelManager models;
  final RealtimeModelSpec model;
  late final RealtimeSubtitleController realtime;
  void update({
    required Duration position,
    required bool playing,
    required double rate,
  }) {
    clock.update(position: position, playing: playing, rate: rate);
    karaoke.updateClock(position: position, playing: playing, rate: rate);
  }

  void seek(Duration position) {
    // Before start there is no controller-bound clock yet.
    final generation = clock.generation;
    realtime.seek(position: position);
    if (clock.generation == generation) clock.reset(position: position);
    karaoke.seek(position);
  }

  Future<void> stop() async {
    await realtime.stop();
    await capture.stop();
    await karaoke.stop();
  }

  Future<void> dispose() async {
    await realtime.dispose();
    await capture.dispose();
    await clock.dispose();
    await karaoke.dispose();
    if (!_micDisposed) {
      _micDisposed = true;
      await micSource.dispose();
    }
    await karaokeClock.dispose();
  }
}

List<TimedLyricLine> lyricLinesFromSrt(SrtDocument document) => [
  for (final cue in document.cues)
    TimedLyricLine(
      index: cue.index,
      startMs: cue.startMs,
      endMs: cue.endMs,
      text: cue.text,
    ),
];

const karaokeBackupUserDataFile = 'karaoke-user-data.json';
KaraokeTrackRepository karaokeRepositoryFor(AppPaths paths) =>
    KaraokeTrackRepository(
      Directory(p.join(paths.dataDir, 'karaoke')),
      cacheDirectory: Directory(p.join(paths.cacheDir, 'karaoke')),
    );
Future<String> exportKaraokeUserFiles(AppPaths paths) async => jsonEncode({
  'schemaVersion': 1,
  'files': await karaokeRepositoryFor(paths).exportUserData(),
});
Map<String, List<int>> decodeKaraokeUserFiles(String raw) {
  final root = jsonDecode(raw);
  if (root is! Map || root['schemaVersion'] != 1 || root['files'] is! Map) {
    throw const FormatException('卡拉OK用户轨格式/版本不支持');
  }
  final result = <String, List<int>>{};
  for (final entry in (root['files'] as Map).entries) {
    final name = entry.key;
    final bytes = entry.value;
    if (name is! String ||
        p.basename(name) != name ||
        name.contains('/') ||
        name.contains('\\') ||
        !name.endsWith('.txt') ||
        name.endsWith('.generated.txt') ||
        name.endsWith('.generated-pitch.txt') ||
        bytes is! List ||
        bytes.length > KaraokeTrackRepository.maxTrackBytes ||
        bytes.any((b) => b is! int || b < 0 || b > 255)) {
      throw const FormatException('卡拉OK用户轨含不安全文件名/生成缓存/坏字节');
    }
    final typed = List<int>.from(bytes);
    final text = utf8.decode(typed);
    if (!UltraStarParser.looksLikeUltraStar(text) ||
        !UltraStarParser.parse(text).hasScoredNotes) {
      throw const FormatException('卡拉OK轨不可评分');
    }
    result[name] = typed;
  }
  return result;
}

Future<void> importKaraokeUserFiles(AppPaths paths, String raw) async {
  final files = decodeKaraokeUserFiles(raw);
  final result = await karaokeRepositoryFor(paths)
      .importUserData(files, replace: true);
  if (result.skipped != 0 || result.restored != files.length) {
    throw const FormatException('卡拉OK用户轨恢复不完整');
  }
}

/// 单集播放身份：季集映射（AI 确认过的逐集 map）优先于上一集身份。
///
/// 不能用上一集 `seasonNumber` 兜底：跨季映射下那会把 S2 的集写成 S1。
TmdbPlaybackIdentity? aiPlaybackIdentityForEpisode(
  TmdbPlaybackIdentity? current,
  VodEpisode episode,
  String flagKey,
) {
  if (current == null) return null;
  final season = episode.extra['tmdb_season_number'];
  final number = episode.extra['tmdb_episode_number'];
  return TmdbPlaybackIdentity.of(
    identity: TmdbIdentity.of(current.mediaType, current.tmdbId),
    episode: episode,
    flagKey: flagKey,
    seasonNumber: season is int ? season : current.seasonNumber,
    episodeNumber: number is int ? number : -1,
  );
}

/// 译文独立轨的落盘路径（源 SRT 与播放结果里的字幕都不被覆盖）。
String aiTranslatedSubtitlePath(AppPaths paths, int generation) => p.join(
  paths.cacheDir,
  'audio_ai',
  'translations',
  'applied-$generation-${DateTime.now().microsecondsSinceEpoch}.srt',
);

/// 已翻译结果 → 固定字幕菜单里的独立外挂轨（不切换用户当前轨道）。
SubtitleInfo aiTranslatedSubtitle(
  SrtTranslationResult result,
  AppPaths paths,
  int generation,
) => SubtitleInfo(
  url: File(aiTranslatedSubtitlePath(paths, generation)).uri.toString(),
  name: 'AI译文 ${result.request.targetLanguage}',
  lang: result.request.targetLanguage,
  format: 'srt',
);

/// 恢复前的原始快照（settings/DB/AI 用户域/卡拉OK用户轨/Reader 偏好）。
///
/// 逐域保存**原始字节**而不是走业务导入：回滚必须能恢复用户已经损坏的旧轨，
/// 不能因为「旧数据不可评分」而整体中断。
class BackupRecovery {
  BackupRecovery(this.directory);
  final Directory directory;
  String get path => directory.path;
  Future<void> delete() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<void> _copyBytesIfExists(File source, File target) async {
  if (!await source.exists()) return;
  await target.parent.create(recursive: true);
  await target.writeAsBytes(await source.readAsBytes(), flush: true);
}

Future<BackupRecovery> captureBackupRecovery(
  AppPaths paths, {
  DateTime? now,
}) async {
  final stamp = (now ?? DateTime.now()).microsecondsSinceEpoch;
  final directory = Directory(p.join(paths.cacheDir, 'backup-recovery-$stamp'));
  await directory.create(recursive: true);
  await _copyBytesIfExists(
    File(paths.settingsPath),
    File(p.join(directory.path, 'settings.json')),
  );
  final db = File(paths.databasePath);
  await _copyBytesIfExists(
    db,
    File(p.join(directory.path, 'database.sqlite3')),
  );
  for (final suffix in ['-wal', '-shm']) {
    await _copyBytesIfExists(
      File('${db.path}$suffix'),
      File(p.join(directory.path, 'database.sqlite3$suffix')),
    );
  }
  final aiDir = Directory(AiContentPaths.of(paths).dataDir);
  for (final name in _aiUserFiles) {
    await _copyBytesIfExists(
      File(p.join(aiDir.path, name)),
      File(p.join(directory.path, 'ai', name)),
    );
  }
  final tracks = Directory(p.join(paths.dataDir, 'karaoke', 'tracks'));
  if (await tracks.exists()) {
    await for (final entry in tracks.list()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.endsWith('.txt') ||
          name.endsWith('.generated.txt') ||
          name.endsWith('.generated-pitch.txt')) {
        continue;
      }
      await _copyBytesIfExists(
        entry,
        File(p.join(directory.path, 'karaoke', name)),
      );
    }
  }
  await _copyBytesIfExists(
    File(p.join(paths.configDir, 'reader_tts.json')),
    File(p.join(directory.path, 'reader_tts.json')),
  );
  return BackupRecovery(directory);
}

Future<void> _writeAtomic(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final temp = File('${target.path}.recovery.tmp');
  await temp.writeAsBytes(bytes, flush: true);
  if (await target.exists()) await target.delete();
  await temp.rename(target.path);
}

/// 逐域恢复：单个域失败不阻断其它域，返回失败域名清单。
Future<List<String>> restoreBackupRecovery(
  AppPaths paths,
  BackupRecovery recovery,
) async {
  final failures = <String>[];
  final directory = recovery.directory;

  Future<void> step(String name, Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      failures.add('$name($error)');
    }
  }

  await step('settings', () async {
    final source = File(p.join(directory.path, 'settings.json'));
    final target = File(paths.settingsPath);
    if (await source.exists()) {
      await _writeAtomic(target, await source.readAsBytes());
    } else if (await target.exists()) {
      await target.delete();
    }
  });

  await step('database', () async {
    final db = File(paths.databasePath);
    for (final suffix in ['-wal', '-shm']) {
      final sidecar = File('${db.path}$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
    final source = File(p.join(directory.path, 'database.sqlite3'));
    if (await source.exists()) {
      await _writeAtomic(db, await source.readAsBytes());
      for (final suffix in ['-wal', '-shm']) {
        final saved = File(p.join(directory.path, 'database.sqlite3$suffix'));
        if (await saved.exists()) {
          await File('${db.path}$suffix')
              .writeAsBytes(await saved.readAsBytes(), flush: true);
        }
      }
    } else if (await db.exists()) {
      await db.delete();
    }
  });

  await step('ai', () async {
    final targetDir = Directory(AiContentPaths.of(paths).dataDir);
    for (final name in _aiUserFiles) {
      final source = File(p.join(directory.path, 'ai', name));
      final target = File(p.join(targetDir.path, name));
      if (await source.exists()) {
        await _writeAtomic(target, await source.readAsBytes());
      } else if (await target.exists()) {
        await target.delete();
      }
    }
  });

  await step('karaoke', () async {
    final targetDir = Directory(p.join(paths.dataDir, 'karaoke', 'tracks'));
    final savedDir = Directory(p.join(directory.path, 'karaoke'));
    final saved = <String>{};
    if (await savedDir.exists()) {
      await for (final entry in savedDir.list()) {
        if (entry is! File) continue;
        saved.add(p.basename(entry.path));
      }
    }
    if (await targetDir.exists()) {
      await for (final entry in targetDir.list()) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (!name.endsWith('.txt') ||
            name.endsWith('.generated.txt') ||
            name.endsWith('.generated-pitch.txt')) {
          continue;
        }
        // 恢复是原始字节交换：旧轨即使不可评分也必须原样回来。
        if (!saved.contains(name)) await entry.delete();
      }
    }
    for (final name in saved) {
      final source = File(p.join(savedDir.path, name));
      await _writeAtomic(
        File(p.join(targetDir.path, name)),
        await source.readAsBytes(),
      );
    }
  });

  await step('reader', () async {
    final source = File(p.join(directory.path, 'reader_tts.json'));
    final target = File(p.join(paths.configDir, 'reader_tts.json'));
    if (await source.exists()) {
      await _writeAtomic(target, await source.readAsBytes());
    } else if (await target.exists()) {
      await target.delete();
    }
  });

  return failures;
}

/// 恢复前快照的逐域完整性：测试与诊断用（不做业务校验）。
Future<Set<String>> recoveryDomains(BackupRecovery recovery) async {
  final domains = <String>{};
  final dir = recovery.directory;
  if (await File(p.join(dir.path, 'settings.json')).exists()) {
    domains.add('settings');
  }
  if (await File(p.join(dir.path, 'database.sqlite3')).exists()) {
    domains.add('database');
  }
  if (await Directory(p.join(dir.path, 'ai')).exists()) domains.add('ai');
  if (await Directory(p.join(dir.path, 'karaoke')).exists()) {
    domains.add('karaoke');
  }
  if (await File(p.join(dir.path, 'reader_tts.json')).exists()) {
    domains.add('reader');
  }
  return domains;
}
