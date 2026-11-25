import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/playback_diagnostics.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

const _token = 'fixtureScopedCredential_42-';
const _query = 'fixturePrivatePayload42';
const _path = '/s/$_token/proxy';
const _url = 'http://127.0.0.1:18080$_path?payload=$_query&action=media';

void expectPrivate(String text) {
  expect(text, isNot(contains(_token)));
  expect(text, isNot(contains(_query)));
}

void main() {
  final urls = <String, String>{
    'absolute': _url,
    'relative': '$_path?payload=$_query',
    'path relative': 's/$_token/proxy?payload=$_query',
    'authority relative': '//127.0.0.1:18080$_path?payload=$_query',
    'session URI': Uri.parse(_url).toString(),
    'encoded token':
        'http://127.0.0.1:18080/s/%66ixtureScopedCredential_42-/proxy?payload=$_query',
  };

  group('local media proxy privacy', () {
    final target = base64Url
        .encode(utf8.encode('https://fixture.invalid/private?payload=$_query'))
        .replaceAll('=', '');
    final longTarget = List.filled(100, target).join();
    final routes = ['/p/$_token/$longTarget', '/p/$_token/i/42'];
    for (final route in routes) {
      final url = 'http://127.0.0.1:18080$route';
      final forms = [
        url,
        route,
        route.substring(1),
        '//127.0.0.1:18080$route',
        Uri.encodeComponent(url),
        url.replaceAll('/', '${String.fromCharCode(92)}/'),
        jsonEncode(
          jsonEncode({
            'url': url.replaceAll('/', '${String.fromCharCode(92)}/'),
          }),
        ),
        jsonEncode(jsonEncode({'url': url})),
        Uri.encodeComponent(Uri.encodeComponent(url)),
        url.replaceAll('/p/', '/%70/'),
      ];
      for (var i = 0; i < forms.length; i++) {
        test('route ${routes.indexOf(route)} representation $i', () {
          final raw = forms[i];
          final output = redactLogText(raw);
          expect(
            output.contains(_token) || output.contains(target),
            isFalse,
            reason: 'local proxy secrets must not survive',
          );
          expect(redactLogText(output), output);
          final safeUrl = redactUrl(raw);
          expect(safeUrl.contains(_token) || safeUrl.contains(target), isFalse);
          expect(redactUrl(safeUrl), safeUrl);
        });
      }
      test('all actual output surfaces ${routes.indexOf(route)}', () async {
        final log = LogService();
        addTearDown(log.dispose);
        final outcome = PlayerLoadOutcome(
          succeeded: false,
          url: url,
          errorMessage: 'failed $url',
        );
        final builder = PlaybackDiagnosticsBuilder(
          enterUrl: url,
          episodeName: url,
          flag: url,
          siteKey: url,
        );
        builder.setFinalUrl(url);
        builder.setHeaders({'Referer': url, 'X-Trace': url});
        builder.addStage(PlaybackStage.load, Duration.zero, note: url);
        builder.fail(kind: 'network', message: 'failed $url', hint: url);
        final diagnostic = builder.build();
        log.info('playback decision/result $url ${outcome.summary}');
        for (final output in [
          outcome.summary,
          diagnostic.logLine,
          diagnostic.report,
          jsonEncode(diagnostic.toJson()),
          log.export(),
          log.exportJson(),
        ]) {
          expect(
            output.contains(_token) || output.contains(target),
            isFalse,
            reason: 'serialized proxy secrets must not survive',
          );
        }
        expect(outcome.url, url);
      });
    }
    test('direct diagnostic serializers protect freeform fields', () {
      final url = 'http://127.0.0.1:18080/p/$_token/$longTarget';
      final diagnostic = PlaybackDiagnostics(
        engine: url,
        format: MediaFormat.unknown,
        target: NetworkTarget.of(url),
        timings: [
          StageTiming(
            stage: PlaybackStage.load,
            elapsed: Duration.zero,
            note: url,
          ),
        ],
        flag: url,
        episodeName: url,
        siteKey: url,
        enterUrl: url,
        finalUrl: url,
        requestedHeaders: {'Referer': url},
        failureMessage: url,
        failureHint: url,
      );
      for (final text in [
        diagnostic.logLine,
        diagnostic.report,
        jsonEncode(diagnostic.toJson()),
      ]) {
        expect(text.contains(_token) || text.contains(target), isFalse);
      }
    });
    test('normal p paths are not credential routes', () {
      for (final value in [
        'https://news.example/p/article-1',
        'p/page',
        '/p/article-1',
      ]) {
        expect(redactUrl(value), value);
        expect(redactLogText(value), value);
      }
    });
    test('direct NetworkTarget serializer redacts raw local route', () {
      final url = 'http://127.0.0.1:18080/p/$_token/$longTarget';
      final targetValue = NetworkTarget(
        host: '127.0.0.1',
        scheme: 'http',
        redactedUrl: url,
      );
      final output = jsonEncode(targetValue.toJson());
      expect(output.contains(_token) || output.contains(target), isFalse);
    });
    test('long local target redaction remains bounded', () {
      final text = List.filled(
        20,
        'http://127.0.0.1:18080/p/$_token/$longTarget',
      ).join(' ');
      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        redactLogText(text);
      }
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('actual player outcome summary', () {
    for (final form in urls.entries) {
      test('scoped ${form.key} is private without changing request data', () {
        final outcome = PlayerLoadOutcome(succeeded: true, url: form.value);
        expectPrivate(outcome.summary);
        expect(outcome.summary, contains('proxy'));
        expect(outcome.url, form.value);
      });
    }
  });

  group('common URL and freeform redaction', () {
    for (final form in urls.entries) {
      test('${form.key} URL is stable under repeated redaction', () {
        final once = redactUrl(form.value);
        expectPrivate(once);
        expect(redactUrl(once), once);
        expect(redactLogText(once), once);
      });
    }

    final messages = <String, String>{
      'absolute': 'result url=$_url code=E_NETWORK',
      'relative': 'GET $_path?payload=$_query code=403',
      'session URI': 'sessionUri=${Uri.parse(_url)}',
      'name': '弹幕加载失败 source=$_url 暂不支持',
      'query': 'failed next=$_url',
      'encoded query': 'next=${Uri.encodeComponent(_url)}',
      'JSON': jsonEncode({'name': _url, 'code': 'E_NETWORK'}),
      'escaped JSON': jsonEncode({'name': _url})
          .replaceAll('/', '${String.fromCharCode(92)}/'),
      'multiline chunk': [
        'first $_url',
        '#0 open (player.dart:42)',
        'second $_path?payload=$_query',
        'code=E_NETWORK',
      ].join(String.fromCharCode(10)),
    };
    for (final form in messages.entries) {
      test('${form.key} tokenized path is private and idempotent', () {
        final once = redactLogText(form.value);
        expectPrivate(once);
        expect(redactLogText(once), once);
      });
    }

    test('already escaped sensitive query placeholders are stable', () {
      const text =
          '<pic>https://cdn.example.com/a.jpg?token=&lt;redacted&gt;</pic>';
      expect(redactLogText(text), text);
      const xml =
          '<pic>https://cdn.example.com/a.jpg?token=&lt;redacted></pic>';
      expect(redactLogText(xml), xml);
      const plain = 'https://cdn.example.com/a.jpg?token=<redacted>';
      expect(redactLogText(plain), plain);
    });

    test('truncated or alternate scoped routes still hide the credential', () {
      final texts = [
        's/$_token',
        '/s/$_token/other?payload=$_query',
        'GET /s/$_token/other E_UNSUPPORTED',
      ];
      for (final text in texts) {
        final once = redactLogText(text);
        expectPrivate(once);
        expect(redactLogText(once), once);
      }
    });

    test('common redaction stays bounded on long and repeated input', () {
      final long = List.filled(80, 'segment/with.chars?x=1').join('/');
      final repeated = List.filled(20, _url).join(' ');
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        redactLogText('$long #$i');
      }
      for (var i = 0; i < 200; i++) {
        redactLogText(repeated);
      }
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      expectPrivate(redactLogText(repeated));
    });

    test('normal URLs and opaque diagnostics remain useful', () {
      final text = [
        'E_NETWORK unknownOpaqueValue42',
        '#0 Player.open (package:webhtv_pc/ui/player_controller.dart:42:3)',
        'https://cdn.example.com/media/series.mp4?quality=hd',
      ].join(String.fromCharCode(10));
      expect(redactLogText(text), text);
      expect(
        redactUrl('https://cdn.example.com/media/series.mp4?quality=hd'),
        'https://cdn.example.com/media/series.mp4?...',
      );
    });

    test('freeform JSON keeps its structure and non-sensitive fields', () {
      final output = redactLogText(
        jsonEncode({'name': _url, 'code': 'E_NETWORK', 'tail': 'useful'}),
      );
      expectPrivate(output);
      final decoded = jsonDecode(output) as Map<String, dynamic>;
      expect(decoded['code'], 'E_NETWORK');
      expect(decoded['tail'], 'useful');
    });
  });

  group('actual raw caller paths', () {
    for (final form in urls.entries) {
      test('warning source name leaks no ${form.key} credential', () async {
        final log = LogService();
        addTearDown(log.dispose);
        final source = DanmakuSource(url: form.value, name: form.value);
        log.warning(
          '弹幕加载失败 source=${source.displayName} E_UNSUPPORTED',
          scope: 'danmaku',
        );
        expectPrivate(log.entries.single.message);
      });
      test('info caller leaks no ${form.key} credential', () async {
        final log = LogService();
        addTearDown(log.dispose);
        log.info('sessionUri=${form.value}', scope: 'player');
        expectPrivate(log.entries.single.message);
      });
    }
  });

  group('LogService ingress protects every destination', () {
    for (final form in urls.entries) {
      test('info outcome and warning name: ${form.key}', () async {
        final temp = await Directory.systemTemp.createTemp(
          'scoped-log-privacy-',
        );
        final log = LogService();
        final streamed = <LogEntry>[];
        final subscription = log.stream.listen(streamed.add);
        addTearDown(() async {
          await subscription.cancel();
          await log.dispose();
          await temp.delete(recursive: true);
        });
        await log.open(temp.path);
        final outcome = PlayerLoadOutcome(succeeded: true, url: form.value);
        final source = DanmakuSource(url: form.value, name: form.value);
        log.info('播放器结果 ${outcome.summary}', scope: 'player');
        log.warning(
          '弹幕加载失败 source=${source.displayName} E_UNSUPPORTED',
          scope: 'danmaku',
        );
        log.info('unredacted caller url=${form.value}');
        await Future<void>.delayed(Duration.zero);
        log.flush();

        expect(log.entries, hasLength(3));
        expect(streamed, hasLength(3));
        for (final entry in [...log.entries, ...streamed]) {
          expectPrivate(entry.message);
          expectPrivate(entry.line);
          expectPrivate(jsonEncode(entry.toJson()));
        }
        expectPrivate(log.export());
        expectPrivate(log.exportJson());
        expectPrivate(File('${temp.path}/webhtv-pc.log').readAsStringSync());
        expectPrivate(await log.readPersisted());
        final exported = await log.exportToDirectory('${temp.path}/export');
        expectPrivate(await exported.readAsString());
        expect(log.entries[1].message, contains('E_UNSUPPORTED'));
        expect(outcome.url, form.value);
        expect(source.url, form.value);
        expect(source.name, form.value);
      });
    }

    test('raw multiline JSON and scope cannot bypass the ingress', () async {
      final log = LogService(scope: _url);
      addTearDown(log.dispose);
      log.warning(
        [
          'chunk $_url',
          jsonEncode({'name': _url}),
        ].join(String.fromCharCode(10)),
      );
      log.info('code=E_NETWORK', scope: 'source=$_url');
      expectPrivate(log.export());
      expectPrivate(log.exportJson());
      expect(log.entries.last.message, 'code=E_NETWORK');
    });
  });
}
