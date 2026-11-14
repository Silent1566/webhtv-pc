import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:webhtv_pc/core/karaoke/karaoke.dart';
import 'package:webhtv_pc/core/karaoke/midi_parser.dart';
import 'package:webhtv_pc/services/karaoke/karaoke_controller.dart';
import 'package:webhtv_pc/services/karaoke/track_repository.dart';
import 'package:webhtv_pc/services/karaoke/track_providers.dart';
import 'package:webhtv_pc/services/karaoke/track_transport.dart';
import 'package:webhtv_pc/services/karaoke/windows_mic_source.dart';

import 'karaoke_controller_probe.dart' show FakeMic;
import 'karaoke_repository_fixture.dart' show fixture;

void check(bool value, String name) {
  if (!value) throw StateError('FAIL: $name');
  stdout.writeln('PASS: $name');
}

const a = KaraokeMedia(
  key: 'a',
  url: 'a.mp4',
  title: 'Song A',
  artist: 'Artist A',
  durationMs: 60000,
);
const b = KaraokeMedia(
  key: 'b',
  url: 'b.mp4',
  title: 'Song B',
  artist: 'Artist B',
  durationMs: 60000,
);
KaraokeTrack track(int pitch) => UltraStarParser.parse(
  '#TITLE:Track $pitch\n#BPM:60\n#GAP:0\n: 0 60 $pitch la\nE',
);
const sample = KaraokePitchSample(
  timestampMs: 0,
  frequencyHz: 440,
  volume: .3,
  confidence: 1,
);

class GatedGenerated extends KaraokeTrackRepository {
  GatedGenerated(super.dataDirectory);
  final gate = Completer<KaraokeImportResult>();
  @override
  Future<KaraokeImportResult> importGenerated(
    KaraokeMedia media,
    KaraokePitchTrack pitch,
  ) => gate.future;
}

Future<void> generatedGate() async {
  final root = await Directory.systemTemp.createTemp('karaoke_r01');
  final repo = GatedGenerated(root);
  final clock = AudioSessionClock(playing: true, now: () => DateTime(2026));
  final mic = FakeMic();
  final c = KaraokeController(clock: clock, repository: repo, mic: mic);
  try {
    await c.bindMedia(a, track: track(69));
    await c.start();
    final pending = c.importGenerated(
      const KaraokePitchTrack(
        text: fixture,
        noteCount: 3,
        observed: 3,
        pitched: 3,
      ),
    );
    await c.bindMedia(b, track: track(72));
    c.pushSample(sample);
    for (var t = 0; t <= 2000; t += 100)
      c.updateClock(position: Duration(milliseconds: t), playing: true);
    final snapshot = c.snapshot;
    repo.gate.complete(KaraokeImportResult.ok(track(69), 'A'));
    final result = await pending;
    check(
      !result.success &&
          c.track!.notes.first.pitch == 72 &&
          c.result.title == 'Track 72' &&
          identical(snapshot, c.snapshot),
      'R7-01 stale generated A cannot replace B or reset B score',
    );
  } finally {
    await c.dispose();
    await mic.close();
    await clock.dispose();
    await root.delete(recursive: true);
  }
}

Future<void> generatedIntentGates() async {
  for (final intent in ['selection', 'seek']) {
    final root = await Directory.systemTemp.createTemp('karaoke_r01_intent');
    final repo = GatedGenerated(root),
        clock = AudioSessionClock(playing: true, now: () => DateTime(2026));
    final mic = FakeMic();
    final c = KaraokeController(clock: clock, repository: repo, mic: mic);
    try {
      await c.bindMedia(a, track: track(69));
      await c.start();
      final pending = c.importGenerated(
        const KaraokePitchTrack(
          text: fixture,
          noteCount: 3,
          observed: 3,
          pitched: 3,
        ),
      );
      if (intent == 'selection')
        c.selectTrack(null);
      else
        c.seek(const Duration(milliseconds: 500));
      final old = c.snapshot;
      repo.gate.complete(KaraokeImportResult.ok(track(72), 'late'));
      check(
        !(await pending).success &&
            identical(c.snapshot, old) &&
            (intent == 'selection'
                ? c.track == null
                : c.track!.notes.first.pitch == 69),
        'R7-01 $intent intent rejects old generated result',
      );
    } finally {
      await c.dispose();
      await mic.close();
      await clock.dispose();
      await root.delete(recursive: true);
    }
  }
}

Future<void> comboGate() async {
  final root = await Directory.systemTemp.createTemp('karaoke_r02');
  final clock = AudioSessionClock(playing: true, now: () => DateTime(2026));
  final mic = FakeMic();
  final c = KaraokeController(
    clock: clock,
    repository: KaraokeTrackRepository(root),
    mic: mic,
  );
  try {
    c.selectTrack(track(69));
    await c.start();
    c.pushSample(sample);
    for (var t = 0; t <= 2000; t += 100) {
      c.updateClock(position: Duration(milliseconds: t), playing: true);
      c.pushSample(sample);
    }
    check(
      c.snapshot.currentComboMs == 900,
      'R7-02 clock plus sample maintains exact 900ms reference combo',
    );
    final old = c.snapshot;
    c.pushSample(sample);
    c.advance();
    check(
      c.snapshot.currentComboMs == old.currentComboMs &&
          c.snapshot.totalWeightMs == old.totalWeightMs,
      'R7-02 repeated same-position sample/advance is non-scoring',
    );
    c.pause();
    c.updateClock(position: const Duration(milliseconds: 4900), playing: true);
    c.resume();
    c.advance();
    check(
      c.snapshot.currentComboMs == old.currentComboMs &&
          c.snapshot.currentLineScorePercent == old.currentLineScorePercent,
      'R7-02 resume at anchor preserves combo and line',
    );
    c.updateClock(position: const Duration(milliseconds: 5000), playing: true);
    check(
      c.snapshot.currentComboMs == old.currentComboMs + 100,
      'R7-02 resumed combo adds only next true slice',
    );
    c.updateClock(position: const Duration(milliseconds: 4500), playing: true);
    check(
      c.snapshot.currentComboMs == 0,
      'R7-02 genuine reverse still clears combo',
    );
  } finally {
    await c.dispose();
    await mic.close();
    await clock.dispose();
    await root.delete(recursive: true);
  }
}

List<int> be(int n) => [
  (n >> 24) & 255,
  (n >> 16) & 255,
  (n >> 8) & 255,
  n & 255,
];
List<int> midi(List<List<int>> tracks, {int division = 96}) => [
  ...ascii.encode('MThd'),
  0,
  0,
  0,
  6,
  0,
  1,
  0,
  tracks.length,
  division >> 8,
  division & 255,
  for (final t in tracks) ...[...ascii.encode('MTrk'), ...be(t.length), ...t],
];
List<int> notes(List<int> pitches) => [
  for (final p in pitches) ...[0, 0x90, p, 100, 96, 0x80, p, 0],
  0,
  255,
  47,
  0,
];
Future<void> midiContracts() async {
  var rejected = false;
  try {
    MidiKaraokeParser.toUltraStar(
      's.mid',
      midi([
        notes([60]),
      ], division: 0xe728),
    );
  } catch (_) {
    rejected = true;
  }
  check(rejected, 'R7-03 SMPTE is rejected');
  final selected = UltraStarParser.parse(
    MidiKaraokeParser.toUltraStar(
      'm.mid',
      midi([
        notes([25, 26]),
        notes([60]),
      ]),
    ),
  );
  check(
    selected.notes.first.pitch == 60,
    'R7-03 humanNotes*10 selects melody, not two bass notes',
  );
  final events = [
    0,
    255,
    81,
    3,
    0x0f,
    0x42,
    0x40,
    0,
    0x99,
    60,
    100,
    96,
    0x89,
    60,
    0,
    0,
    0x90,
    60,
    100,
    96,
    60,
    0,
    0,
    255,
    47,
    0,
  ];
  final parsed = UltraStarParser.parse(
    MidiKaraokeParser.toUltraStar('x.mid', midi([events])),
  );
  check(
    parsed.notes.length == 1 &&
        parsed.notes.first.endMs - parsed.notes.first.startMs == 1000,
    'R7-03 tempo 1s, running-status and drum skip',
  );
  rejected = false;
  try {
    MidiKaraokeParser.toUltraStar(
      'bad.mid',
      midi([
        notes([60]),
      ]).sublist(0, 25),
    );
  } catch (_) {
    rejected = true;
  }
  check(rejected, 'R7-03 truncated declared track rejected');
}

Future<void> strictNumbers() async {
  final root = await Directory.systemTemp.createTemp('karaoke_r04');
  final repo = KaraokeTrackRepository(root);
  try {
    await repo.importText(a, 'A', fixture);
    final old = await repo.exportUserData();
    final name = '${repo.signatureOf(b)}.txt';
    for (final suffix in [
      '#BPM:NaN',
      '#BPM:Infinity',
      '#BPM:0',
      '#BPM:-1',
      '#GAP:bad',
      '#GAP:Infinity',
      ': NaN 1 69 x',
      ': 1 Infinity 69 x',
      ': 1 1 NaN x',
      ': 2147483647 2147483647 69 x',
    ]) {
      var rejected = false;
      try {
        await repo.importUserData({
          name: utf8.encode('$fixture\n$suffix\nE'),
        }, replace: true);
      } on KaraokeUserDataException {
        rejected = true;
      }
      check(rejected, 'R7-04 trailing numeric invalid $suffix rejected');
      final now = await repo.exportUserData();
      check(
        jsonEncode(now) == jsonEncode(old),
        'R7-04 invalid full restore preserves old bytes',
      );
    }
  } finally {
    await root.delete(recursive: true);
  }
}

class RoutingTransport implements KaraokeRequestTransport {
  final calls = <({Uri uri, Map<String, String> headers, String method})>[];
  final Map<String, KaraokeResponse> routes = {};
  Completer<void>? gate;
  int cancellations = 0;
  @override
  Future<KaraokeResponse> get(Uri uri) => request(uri);
  @override
  Future<KaraokeResponse> post(Uri uri, Map<String, String> form) =>
      request(uri, method: 'POST', form: form);
  @override
  Future<KaraokeResponse> request(
    Uri uri, {
    String method = 'GET',
    Map<String, String> form = const {},
    Map<String, String> headers = const {},
    KaraokeCancellation? cancellation,
  }) async {
    calls.add((uri: uri, headers: Map.of(headers), method: method));
    if (gate != null) {
      await Future.any([
        gate!.future,
        if (cancellation != null)
          cancellation.whenCancelled.then((_) {
            cancellations++;
            throw const KaraokeCancelled();
          }),
      ]);
    }
    cancellation?.throwIfCancelled();
    return routes[uri.toString()] ??
        const KaraokeResponse(
          status: 200,
          body: '<html></html>',
          contentType: 'text/html',
        );
  }
}

const github = KaraokeGithubProvider(
  sources: [('fixture', 'o', 'r', 'main', 'test')],
);
Future<void> githubValidation() async {
  final t = RoutingTransport();
  final url = 'https://api.github.com/repos/o/r/git/trees/main?recursive=1';
  for (final body in [
    'broken',
    '{"message":{"path":"Artist - Song.txt"}}',
    '{"tree":{}}',
    '{"tree":[3]}',
    '{"tree":[{"path":"Artist - Song.txt","type":"tree","size":12}]}',
    '{"tree":[{"path":"Artist - Song.txt","type":"blob"}]}',
    for (final size in [0, -1, 524289])
      jsonEncode({
        'tree': [
          {'path': 'Artist - Song.txt', 'type': 'blob', 'size': size},
        ],
      }),
  ]) {
    t.routes[url] = KaraokeResponse(
      status: 200,
      body: body,
      contentType: 'application/json',
    );
    var results = <KaraokeSearchResult>[];
    try {
      results = await github.search('Song', t);
    } catch (_) {}
    check(
      results.isEmpty,
      'R7-05 invalid JSON/tree/blob/size never yields track',
    );
  }
  t.routes[url] = const KaraokeResponse(
    status: 200,
    body:
        r'{"tree":[{"path":"Artist - S\u00f6ng.txt","type":"blob","size":12}]}',
    contentType: 'application/json',
  );
  final result = await github.search('Söng Artist', t);
  check(
    result.single.url ==
        'https://raw.githubusercontent.com/o/r/main/Artist%20-%20S%C3%B6ng.txt',
    'R7-05 escaped Unicode path and reversed tokens yield correct raw URL',
  );
}

Future<void> sourceBranches() async {
  check(
    KaraokeUsdbProvider.parseUsdbId('USDB # 12345') == '12345',
    'R7-06 source ID branch accepts marker spacing',
  );
  final t = RoutingTransport();
  const rss =
      '<rss><item><title>Artist - Song</title><guid>12345</guid></item></rss>';
  for (final name in ['rss_new_top10.php', 'rss_downloads_top10.php'])
    t.routes['https://usdb.animux.de/rss/$name'] = const KaraokeResponse(
      status: 200,
      body: rss,
      contentType: 'application/xml',
    );
  final results = await const KaraokeUsdbProvider().search('Song', t);
  check(
    results.length == 1 &&
        results.single.url.endsWith('id=12345') &&
        t.calls.where((c) => c.uri.path.contains('rss_')).length == 2,
    'R7-06 both RSS branches queried and deduplicated',
  );
  final root = await Directory.systemTemp.createTemp('karaoke_r06');
  final repo = KaraokeTrackRepository(root, transport: t, providers: [github]);
  try {
    const raw =
        'https://raw.githubusercontent.com/o/r/main/Artist%20-%20Song.txt';
    t.routes[raw] = const KaraokeResponse(
      status: 200,
      body: fixture,
      contentType: 'text/plain',
    );
    final imported = await repo.importUrl(
      a,
      Uri.parse(
        'https://github.com/o/r/blob/main/Artist%20-%20Song.txt@Cookie=session=secret',
      ),
    );
    check(
      imported.success &&
          t.calls.last.uri.toString() == raw &&
          t.calls.last.headers['Cookie'] == 'session=secret',
      'R7-06 blob rewritten and Cookie split from URI',
    );
    t.routes['https://gitlab.com/o/r/-/raw/main/song.txt'] =
        const KaraokeResponse(
          status: 200,
          body: fixture,
          contentType: 'text/plain',
        );
    check(
      (await repo.importUrl(
        b,
        Uri.parse('https://gitlab.com/o/r/-/blob/main/song.txt'),
      )).success,
      'R7-06 GitLab blob normalizes to raw',
    );
    t.calls.clear();
    await repo.search('Song');
    check(
      t.calls.every((call) => !call.headers.containsKey('Cookie')),
      'R7-06 scoped Cookie never leaks to other requests or diagnostics',
    );
    t.routes['https://usdb.animux.de/?link=list'] = const KaraokeResponse(
      status: 200,
      body: '<tr class="list_tr1"><td class="x">Artist</td><td class="x">Song</td><td onclick="show_detail(12345)"></td></tr>',
      contentType: 'text/html',
    );
    check(
      (await const KaraokeUsdbProvider().search('Song', t)).single.source ==
          'USDB',
      'R7-06 typed USDB list branch parses artist/title',
    );
    t.routes['https://usdb.animux.de/?link=detail&id=12345'] =
        const KaraokeResponse(
          status: 200,
          body: '<title>USDB - Artist - Song</title><tr class="list_tr1"><td>BPM</td><td>60</td></tr><tr class="list_tr2"><td>GAP</td><td>0</td></tr>',
          contentType: 'text/html',
        );
    t.routes['https://usdb.animux.de/view.php?id=12345&database1=deluxe_songs'] =
        const KaraokeResponse(
          status: 200,
          body: "giveinfo0('golden','0','4','69','','la')",
          contentType: 'text/html',
        );
    final usdb = await repo.importUrl(
      a,
      Uri.parse('https://usdb.animux.de/?link=detail&id=12345'),
    );
    check(
      usdb.success &&
          usdb.track!.notes.single.type == KaraokeNoteType.golden &&
          usdb.track!.notes.single.endMs == 4000,
      'R7-06 USDB detail timing plus notes produces true golden track',
    );
    const es =
        '<li title="See all complete information of Artist - Song"><a href="/en/canciones?artista=A">Artist</a><a>Song</a><a href="/en/canciones/descargar/txt/42">download</a>\n</ul>';
    check(
      KaraokeUltrastarEsProvider.parseList(es).single.url ==
          'https://ultrastar-es.org/en/canciones/descargar/txt/42',
      'R7-06 UltraStar-ES fixture produces authenticated txt link',
    );
    t.routes['https://fixture.invalid/octet.txt'] = const KaraokeResponse(
      status: 200,
      body: fixture,
      contentType: 'application/octet-stream',
    );
    check(
      (await repo.importUrl(
        a,
        Uri.parse('https://fixture.invalid/octet.txt'),
      )).success,
      'R7-05 source permits octet TXT only after strict scoring-track validation',
    );
    check(
      (await repo.importUrl(a, Uri.parse('12345'))).success,
      'R7-06 plain USDB identifier normalizes to detail/notes requests',
    );
    final bad = RoutingTransport();
    bad.routes['https://usdb.animux.de/?link=detail&id=12345'] =
        KaraokeResponse(
          status: 200,
          body: 'x' * 524289,
          contentType: 'text/html',
        );
    final invalid = KaraokeTrackRepository(root, transport: bad);
    check(
      !(await invalid.importUrl(
        b,
        Uri.parse('https://usdb.animux.de/?link=detail&id=12345'),
      )).success,
      'R7-05 USDB body bounds checked before consumption',
    );
    bad.routes['https://api.github.com/repos/o/r/git/trees/main?recursive=1'] =
        const KaraokeResponse(
          status: 200,
          body: '{}',
          contentType: 'image/png',
        );
    final invalidSearch = KaraokeTrackRepository(
      root,
      transport: bad,
      providers: [github],
    );
    check(
      (await invalidSearch.search('Song')).isEmpty,
      'R7-05 non-text search response cannot produce/corrupt cache',
    );
    final failedCalls = bad.calls.length;
    await invalidSearch.search('Song');
    check(
      bad.calls.length > failedCalls,
      'R7-05 invalid search response was not cached',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

class PacketBackend implements KaraokeMicBackend {
  PacketBackend(this.sampleRate);
  @override
  final int sampleRate;
  final packets = <Float32List>[];
  int nextRead = 0;
  bool stopped = false;
  @override
  bool get isAvailable => true;
  @override
  String get error => 'fixture read failure';
  @override
  bool start(int frameSize) {
    stopped = false;
    return true;
  }

  @override
  int read(Float32List buffer) {
    if (nextRead != 0) return nextRead;
    if (packets.isEmpty) return 0;
    final p = packets.removeAt(0);
    buffer.setRange(0, p.length, p);
    return p.length;
  }

  @override
  void stop() {
    stopped = true;
  }
}

Future<void> micPackets() async {
  for (final rate in [44100, 48000, 96000]) {
    final backend = PacketBackend(rate);
    final mic = WindowsKaraokeMicSource(
      backend: backend,
      automaticPolling: false,
    );
    final samples = <KaraokePitchSample>[];
    final errors = <Object>[];
    final sub = mic.samples.listen(samples.add, onError: errors.add);
    try {
      await mic.start();
      await mic.poll();
      check(samples.isEmpty, 'R7-07 zero read emits no fake sample at $rate');
      var offset = 0;
      for (var i = 0; i < 50; i++) {
        final n = i.isEven ? 882 : 926;
        final packet = Float32List.fromList(
          List.generate(n, (j) {
            final t = (offset + j) / rate;
            return i < 10
                ? 0.001 * math.sin(2 * math.pi * 1000 * t)
                : 0.3 * math.sin(2 * math.pi * 80 * t);
          }),
        );
        offset += n;
        backend.packets.add(packet);
        await mic.poll();
      }
      await Future<void>.delayed(Duration.zero);
      check(
        samples.any((s) => (s.frequencyHz - 80).abs() < 2 && s.confidence > .9),
        'R7-07 split packets reach complete 2048 analysis and detect 80Hz at $rate',
      );
      final expectedWindows = ((((offset - 1) * 44100) ~/ rate) + 1) ~/ 2048;
      check(
        samples.length == expectedWindows,
        'R7-07 every complete resampled window counted, packet tail retained at $rate',
      );
      check(
        mic.msForFrames(rate) == 1000,
        'R7-07 active sample-rate lifecycle',
      );
      final count = samples.length;
      backend.packets.add(Float32List(882));
      final inFlight = mic.poll();
      await mic.stop();
      await inFlight;
      check(
        mic.msForFrames(rate) == 0,
        'R7-07 stop resets rate and drops in-flight analysis',
      );
      backend.packets.add(Float32List(882));
      await mic.poll();
      check(
        samples.length == count && backend.stopped,
        'R7-07 stop releases backend and forbids late output',
      );
      await mic.start();
      backend.nextRead = -1;
      await mic.poll();
      await Future<void>.delayed(Duration.zero);
      check(
        errors.isNotEmpty && backend.stopped,
        'R7-07 negative read exposes error and stops',
      );
      backend.nextRead = 2049;
      await mic.start();
      await mic.poll();
      check(
        backend.stopped,
        'R7-07 oversized positive read rejects buffer overflow',
      );
    } finally {
      await mic.dispose();
      await sub.cancel();
    }
  }
}

class RedirectClient extends http.BaseClient {
  final headers = <Map<String, String>>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    headers.add(Map.of(request.headers));
    if (headers.length == 1)
      return http.StreamedResponse(
        const Stream.empty(),
        302,
        headers: {'location': 'https://other.fixture.invalid/song.txt'},
      );
    return http.StreamedResponse(
      Stream.value(utf8.encode(fixture)),
      200,
      headers: {'content-type': 'text/plain'},
    );
  }
}

Future<void> redirectAuthentication() async {
  final client = RedirectClient();
  final actual = HttpKaraokeTransport(client: client);
  final response = await actual.request(
    Uri.parse('https://fixture.invalid/song.txt'),
    headers: {'Cookie': 'private'},
  );
  check(
    response.body == fixture &&
        client.headers.first.entries.any(
          (e) => e.key.toLowerCase() == 'cookie' && e.value == 'private',
        ) &&
        !client.headers.last.keys.any((key) => key.toLowerCase() == 'cookie'),
    'R7-06 manual redirect consumes result without leaking Cookie to other domain',
  );
  actual.close();
  check(
    normalizeSearchText('Песня Артист') == 'песняартист',
    'R7-06 Unicode letter/number normalization follows Android',
  );
}

class AbortAwareClient extends http.BaseClient {
  final sent = Completer<void>();
  bool aborted = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    check(
      request is http.Abortable && !request.followRedirects,
      'R7-08 production uses abortable request and cannot forward cookies via redirects',
    );
    sent.complete();
    await (request as http.Abortable).abortTrigger;
    aborted = true;
    throw http.RequestAbortedException(request.url);
  }
}

Future<void> productionAbort() async {
  final client = AbortAwareClient(), token = KaraokeCancellation();
  final transport = HttpKaraokeTransport(client: client);
  final pending = transport.request(
    Uri.parse('https://fixture.invalid/no-network'),
    cancellation: token,
  );
  await client.sent.future;
  token.cancel();
  var cancelled = false;
  try {
    await pending;
  } on KaraokeCancelled {
    cancelled = true;
  }
  check(
    cancelled && client.aborted,
    'R7-08 production AbortableRequest actually cancels injected client',
  );
  transport.close();
}

Future<void> repositoryGates() async {
  final root = await Directory.systemTemp.createTemp('karaoke_r08');
  final t = RoutingTransport();
  final repo = KaraokeTrackRepository(root, transport: t, providers: [github]);
  try {
    for (final action in ['binding', 'cache', 'replace']) {
      t.gate = Completer<void>();
      t.routes['https://fixture.invalid/song.txt'] = const KaraokeResponse(
        status: 200,
        body: fixture,
        contentType: 'text/plain',
      );
      final pending = repo.importUrl(
        a,
        Uri.parse('https://fixture.invalid/song.txt'),
      );
      await Future<void>.delayed(Duration.zero);
      if (action == 'binding')
        await repo.clearBinding(a);
      else if (action == 'cache')
        await repo.clearCache();
      else
        await repo.importUserData({}, replace: true);
      t.gate!.complete();
      final result = await pending;
      check(
        !result.success && (await repo.exportUserData()).isEmpty,
        'R7-08 $action invalidates pending GET commit',
      );
    }
    t.gate = Completer<void>();
    final token = KaraokeCancellation();
    final pending = repo.importUrl(
      a,
      Uri.parse('https://fixture.invalid/song.txt'),
      cancellation: token,
    );
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    check(
      !(await pending).success && t.cancellations > 0,
      'R7-08 actual transport cancellation executed',
    );
    t.gate!.complete();
    t.gate = Completer<void>();
    final search = repo.search('Song');
    await Future<void>.delayed(Duration.zero);
    repo.clearSearchCache();
    t.gate!.complete();
    check(
      (await search).isEmpty,
      'R7-08 late search returns no stale candidates',
    );
    final calls = t.calls.length;
    t.gate = null;
    await repo.search('Song');
    check(
      t.calls.length > calls,
      'R7-08 late search did not rebuild cleared cache',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> localMigration() async {
  final root = await Directory.systemTemp.createTemp('karaoke_r09');
  final data = Directory('${root.path}/data');
  final repo = KaraokeTrackRepository(data);
  try {
    final mediaFile = File('${root.path}/song.mp4');
    await mediaFile.writeAsBytes([0]);
    final media = a.copyWith(url: mediaFile.path);
    final sidecar = File('${root.path}/song.txt');
    await sidecar.writeAsString(fixture);
    check(
      (await repo.load(media))?.notes.length == 3,
      'R7-09 adjacent sidecar loads',
    );
    await sidecar.writeAsString('#BPM:NaN\n#GAP:0\n: 0 1 69 x');
    check(
      await repo.load(media) == null,
      'R7-09 malformed sidecar does not crash binding',
    );
    await sidecar.delete();
    await repo.trackDirectory.create(recursive: true);
    await File('${repo.trackDirectory.path}/${media.legacySignature}.txt')
        .writeAsString(fixture);
    check(
      await repo.load(media) != null,
      'R7-09 legacy signature bound track loads',
    );
    await repo.clearBinding(media);
    check(
      await repo.load(media) == null,
      'R7-09 clearing legacy binding cannot resurrect old signature',
    );
    await File(
      '${repo.trackDirectory.path}/00000000000000000000000000000000.txt',
    ).writeAsString(fixture);
    final older = File(
      '${repo.trackDirectory.path}/00000000000000000000000000000000.txt',
    );
    await older.setLastModified(DateTime(2000));
    final newer = File(
      '${repo.trackDirectory.path}/11111111111111111111111111111111.txt',
    );
    await newer.writeAsString(fixture.replaceFirst(': 0 10 69', ': 0 10 72'));
    await newer.setLastModified(DateTime(2010));
    final metadata = const KaraokeMedia(
      key: 'm',
      url: 'm',
      title: 'Fixture Song',
      artist: 'Tester',
      durationMs: 1,
    );
    check(
      await repo.load(metadata) != null &&
          await File(
            '${repo.trackDirectory.path}/${repo.signatureOf(metadata)}.txt',
          ).exists(),
      'R7-09 matching metadata migrates to current signature',
    );
    check(
      (await repo.load(metadata))!.notes.first.pitch == 72,
      'R7-09 equal metadata score selects newest source candidate',
    );
    await older.delete();
    check(
      await repo.load(b) == null,
      'R7-09 unrelated media cannot load metadata candidate',
    );
    await repo.clearBinding(metadata);
    check(
      await repo.load(metadata) == null,
      'R7-09 clearing migrated binding also clears selected old metadata candidate',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> main() async {
  final failures = <String>[];
  for (final group in <String, Future<void> Function()>{
    'R7-01': () async {
      await generatedGate();
      await generatedIntentGates();
    },
    'R7-02': comboGate,
    'R7-03': midiContracts,
    'R7-04': strictNumbers,
    'R7-05': githubValidation,
    'R7-06': () async {
      await sourceBranches();
      await redirectAuthentication();
    },
    'R7-07': micPackets,
    'R7-08': () async {
      await repositoryGates();
      await productionAbort();
    },
    'R7-09': localMigration,
  }.entries) {
    try {
      await group.value();
      stdout.writeln('GROUP PASS: ${group.key}');
    } catch (e, stack) {
      failures.add(group.key);
      stderr.writeln('$e\n$stack');
    }
  }
  if (failures.isNotEmpty)
    throw StateError('FAILED GROUPS: ${failures.join(',')}');
}
