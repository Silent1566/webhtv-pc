import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/karaoke/karaoke.dart';
import 'package:webhtv_pc/services/karaoke/track_repository.dart';
import 'package:webhtv_pc/services/karaoke/track_providers.dart';
import 'package:webhtv_pc/services/karaoke/track_transport.dart';

const _track = '#TITLE:t\n#ARTIST:a\n#BPM:60\n#GAP:0\n'
    ': 0 20 69 la\n: 20 20 69 la\n: 40 20 69 la\nE\n';

/// 可控传输：每个 host 各自等待自己的闸门，用来制造并发交错。
class _GatedTransport implements KaraokeTransport {
  final gates = <String, Completer<void>>{};
  final ranges = <String, int>{};
  Completer<void> gate(String host) =>
      gates.putIfAbsent(host, Completer<void>.new);

  @override
  Future<KaraokeResponse> get(Uri uri) async {
    final wait = gates[uri.host];
    if (wait != null) await wait.future;
    return const KaraokeResponse(
      status: 200,
      body: _track,
      contentType: 'text/plain; charset=utf-8',
    );
  }

  @override
  Future<KaraokeResponse> post(Uri uri, Map<String, String> form) async =>
      const KaraokeResponse(status: 200, body: '');
}

/// 单个 provider：返回一条下载候选，便于验证并发搜索不被写入打断。
class _Provider implements KaraokeTrackProvider {
  _Provider(this.url);
  final String url;
  @override
  String get name => 'fixture';
  @override
  Future<List<KaraokeSearchResult>> search(
    String query,
    KaraokeTransport transport,
  ) async => [
    KaraokeSearchResult(
      source: name,
      title: 'fixture song',
      artist: 'fixture artist',
      note: '',
      url: url,
    ),
  ];
}

KaraokeMedia _media(String key, String url) =>
    KaraokeMedia(key: key, url: url, title: 't', artist: 'a', durationMs: 60000);

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('karaoke_fix_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('并发两个媒体远程导入都成功，不互相误判过期（NEW-01）', () async {
    final transport = _GatedTransport();
    final repository = KaraokeTrackRepository(root, transport: transport);
    final a = transport.gate('a.test');
    final b = transport.gate('b.test');
    final first = repository.importUrl(
      _media('a', 'https://a.test/track.txt'),
      Uri.parse('https://a.test/track.txt'),
    );
    final second = repository.importUrl(
      _media('b', 'https://b.test/track.txt'),
      Uri.parse('https://b.test/track.txt'),
    );
    a.complete();
    final firstResult = await first;
    b.complete();
    final secondResult = await second;
    expect(firstResult.success, isTrue, reason: firstResult.error);
    expect(secondResult.success, isTrue, reason: secondResult.error);
    expect(
      await repository.load(_media('a', 'https://a.test/track.txt')),
      isNotNull,
    );
    expect(
      await repository.load(_media('b', 'https://b.test/track.txt')),
      isNotNull,
    );
  });

  test('写入成功不能让在途搜索被静默丢弃（NEW-01）', () async {
    final transport = _GatedTransport()..gate('a.test');
    final repository = KaraokeTrackRepository(
      root,
      transport: transport,
      providers: [_Provider('https://cdn.test/a.txt')],
    );
    final searching = repository.search('song');
    await Future<void>.delayed(Duration.zero);
    final imported = await repository.importText(
      _media('b', 'https://b.test/track.txt'),
      'B',
      _track,
    );
    expect(imported.success, isTrue, reason: imported.error);
    expect(await searching, isNotEmpty, reason: '无关写入不得清空搜索结果');
  });

  test('负GAP按源夹取到0而不是整轨拒绝（NEW-02）', () async {
    final repository = KaraokeTrackRepository(root, transport: _GatedTransport());
    const negative = '#TITLE:t\n#ARTIST:a\n#BPM:60\n#GAP:-500\n'
        ': 0 20 69 la\n: 20 20 69 la\n: 40 20 69 la\nE\n';
    final imported = await repository.importText(
      _media('c', 'https://c.test/track.txt'),
      'C',
      negative,
    );
    expect(imported.success, isTrue, reason: imported.error);
    expect(imported.track!.notes.first.startMs, 0);
    expect(imported.track!.notes.first.endMs, greaterThan(0));
    final loaded = await repository.load(_media('c', 'https://c.test/track.txt'));
    expect(loaded!.notes.first.startMs, 0);
  });

  test('真正越界与病态数值仍被拒绝（NEW-02）', () {
    for (final text in [
      '#BPM:NaN\n#GAP:0\n: 0 20 69 la\n: 20 20 69 la\nE\n',
      '#BPM:60\n#GAP:99999999999\n: 0 20 69 la\n: 20 20 69 la\nE\n',
      '#BPM:60\n#GAP:0\n: 0 0 69 la\n: 0 20 69 la\nE\n',
    ]) {
      expect(
        () => UltraStarParser.parseStrict(text),
        throwsA(isA<FormatException>()),
        reason: text,
      );
    }
  });
}
