import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:webhtv_pc/core/karaoke/karaoke.dart';
import 'package:webhtv_pc/core/karaoke/midi_parser.dart';
import 'package:webhtv_pc/services/karaoke/track_repository.dart';
import 'package:webhtv_pc/services/karaoke/track_transport.dart';

void check(bool value, String name) {
  if (!value) throw StateError('FAIL: $name');
  print('PASS: $name');
}

const fixture = '#TITLE:Fixture Song\n#ARTIST:Tester\n#BPM:60\n#GAP:0\n: 0 10 69 la\n: 10 10 71 la\n-\n: 20 10 72 la\nE';

class FakeTransport implements KaraokeTransport {
  FakeTransport(this.body, {this.status = 200});
  final String body;
  final int status;
  final List<Uri> calls = [];
  bool cancelled = false;
  @override
  Future<KaraokeResponse> get(Uri uri) async {
    calls.add(uri);
    if (cancelled) throw const KaraokeCancelled();
    return KaraokeResponse(status: status, body: body, contentType: 'text/plain');
  }
  @override
  Future<KaraokeResponse> post(Uri uri, Map<String, String> form) async {
    calls.add(uri);
    return KaraokeResponse(status: status, body: body, contentType: 'text/html');
  }
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('karaoke_repo_probe');
  final repo = KaraokeTrackRepository(root);
  final song = const KaraokeMedia(key: 'v1', url: 'D:/media/a.mp4', title: 'Fixture Song', artist: 'Tester', durationMs: 200000);
  final other = song.copyWith(url: 'D:/media/b.mp4', title: 'Other Song');
  check(repo.signatureOf(song) != repo.signatureOf(other), 'media signature isolation');

  final rejected = await repo.importText(song, 'bad.txt', 'not a track');
  check(!rejected.success && rejected.error == 'not ultrastar', 'invalid text rejected');
  check(!File('${root.path}/tracks/${repo.signatureOf(song)}.txt').existsSync(), 'rejected import writes nothing');

  final imported = await repo.importText(song, 'a.txt', fixture);
  check(imported.success && imported.track!.notes.length == 3, 'import bound track');
  check((await repo.load(song))!.notes[1].pitch == 71, 'load bound track');
  check(await repo.load(other) == null, 'no cross-media track leak');

  final midi = <int>[0x4d,0x54,0x68,0x64,0,0,0,6,0,1,0,1,0,96,
    0x4d,0x54,0x72,0x6b,0,0,0,20,0,0x90,60,100,0x60,0x80,60,0,0x60,0x90,64,100,0x60,0x80,64,0,0,0xff,0x2f,0];
  final parsedMidi = MidiKaraokeParser.toUltraStar('m.mid', midi);
  final midiTrack = UltraStarParser.parse(parsedMidi);
  check(midiTrack.notes.length == 2 && midiTrack.notes[1].pitch == 64, 'MIDI fixture to UltraStar');
  check((await repo.importFile(other, 'm.mid', midi)).success, 'import MIDI file');
  check((await repo.load(other))!.notes.length == 2, 'MIDI import bound to own media');

  final transport = FakeTransport(fixture);
  final repo2 = KaraokeTrackRepository(await Directory.systemTemp.createTemp('karaoke_repo_probe2'), transport: transport);
  final remote = const KaraokeMedia(key: 'r', url: 'https://example.invalid/a.mp4', title: 'Remote', artist: 'R', durationMs: 1000);
  check((await repo2.importUrl(remote, Uri.parse('https://example.invalid/song.txt'))).success, 'remote import through transport');
  check(transport.calls.length == 1 && (await repo2.load(remote)) != null, 'remote track persisted');
  final big = FakeTransport('x' * (513 * 1024));
  final repo3 = KaraokeTrackRepository(await Directory.systemTemp.createTemp('karaoke_repo_probe3'), transport: big);
  final tooLarge = await repo3.importUrl(remote, Uri.parse('https://example.invalid/big.txt'));
  check(!tooLarge.success && tooLarge.error == 'track too large', 'remote oversize rejected');
  final bad = FakeTransport('{"data":[]}', status: 500);
  final repo4 = KaraokeTrackRepository(await Directory.systemTemp.createTemp('karaoke_repo_probe4'), transport: bad);
  check(!(await repo4.importUrl(remote, Uri.parse('https://example.invalid/x.txt'))).success, 'remote http failure surfaces');

  final generated = KaraokePitchTrack(text: fixture, noteCount: 3, observed: 3, pitched: 3);
  final genRepo = KaraokeTrackRepository(await Directory.systemTemp.createTemp('karaoke_repo_probe5'));
  check((await genRepo.importGenerated(song, generated)).success, 'generated pitch track import');
  check(await genRepo.load(song) != null, 'generated track loadable');

  final userFile = File('${root.path}/tracks/${repo.signatureOf(song)}.user.txt');
  await userFile.parent.create(recursive: true);
  await userFile.writeAsString(fixture);
  final exported = await repo.exportUserData();
  check(exported.containsKey('${repo.signatureOf(song)}.user.txt'), 'user data enumerated for export');
  final fresh = KaraokeTrackRepository(await Directory.systemTemp.createTemp('karaoke_repo_probe6'));
  await fresh.importUserData(exported);
  check(await fresh.load(song) != null, 'user data restored after backup');
  check(await repo.clearCache() && await repo.load(song) != null, 'generated cache rebuild keeps user binding');

  final searchRepo = KaraokeTrackRepository(await Directory.systemTemp.createTemp('karaoke_repo_probe7'), transport: FakeTransport('<html></html>'));
  final hits = await searchRepo.search('fixture');
  check(hits.isEmpty, 'empty local fixture search result is typed');

  await root.delete(recursive: true);
  final digest = md5.convert(utf8.encode('probe')).toString();
  check(digest.length == 32, 'md5 available for stable cache keys');
  print('ALL REPOSITORY PROBES PASSED');
}

