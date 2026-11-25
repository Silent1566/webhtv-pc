import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_adb_profile.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/android_adb_runtime.dart';
import 'package:webhtv_pc/services/log_service.dart';

import 'android_adb_runtime_fixtures.dart';

/// 受控「自有 ADB 服务」：按被启动参数里的端口绑定协议夹具。
class OwnedServerFixture {
  OwnedServerFixture(this.processes);

  final FakeProcessHost processes;
  FakeAdbServer? server;
  FakeProcess? owned;

  void install() {
    processes.onStart = (executable, arguments, environment) async {
      final port = int.parse(arguments[1].substring(4));
      final fixture = await FakeAdbServer.bind(port: port);
      server = fixture;
      owned = FakeProcess.detached(
        onKill: () async {
          await fixture.close();
        },
      );
      return owned!;
    };
  }
}

void main() {
  late LogService log;

  setUp(() {
    log = LogService();
  });

  tearDown(() async {
    await log.dispose();
  });

  AndroidAdbRuntime runtime({
    required FakeProcessHost processes,
    FutureOr<String> Function(Uri url)? device,
    Duration commandTimeout = const Duration(milliseconds: 400),
    Duration connectTimeout = const Duration(seconds: 2),
    int maxOutputBytes = 64 * 1024,
  }) => AndroidAdbRuntime(
    bridge: fakeBridge(log, device: device ?? (_) => deviceJson()),
    log: log,
    processes: processes,
    commandTimeout: commandTimeout,
    connectTimeout: connectTimeout,
    maxOutputBytes: maxOutputBytes,
  );

  Future<AndroidAdbRuntime> connected(
    FakeAdbServer server, {
    FutureOr<String> Function(Uri url)? device,
    String serial = 'R58M12345',
  }) async {
    final adb = runtime(processes: FakeProcessHost(), device: device);
    addTearDown(adb.close);
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: serial,
        serverPort: server.port,
      ),
    );
    return adb;
  }

  test('listDevices borrows a running server and never spawns adb', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['emulator-5554'] = 'device';
    server.devices['R58M12345'] = 'unauthorized';
    final processes = FakeProcessHost();
    final adb = runtime(processes: processes);
    addTearDown(adb.close);

    expect(await adb.listDevices(serverPort: server.port), [
      'emulator-5554',
      'R58M12345',
    ]);
    expect(server.requests, contains('host:devices'));
    expect(processes.spawns, isEmpty);
  });

  test(
    'listDevices returns no serials when no borrowed server is listening',
    () async {
      final processes = FakeProcessHost();
      final adb = runtime(processes: processes);
      addTearDown(adb.close);
      final port = await unusedPort();

      expect(await adb.listDevices(serverPort: port), isEmpty);
      expect(processes.spawns, isEmpty);
    },
  );

  test('listDevices rejects a truncated SDK reply frame instead of inventing serials', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['emulator-5554'] = 'device';
    server.brokenFrame = true;
    final adb = runtime(processes: FakeProcessHost());
    addTearDown(adb.close);

    await expectLater(
      adb.listDevices(serverPort: server.port),
      throwsA(isA<AppError>()),
    );
  });

  test(
    'listAvds runs the exact SDK list command and returns AVD names',
    () async {
      final processes = FakeProcessHost(
        onStart: (executable, arguments, _) async {
          expect(executable, '/sdk/emulator/emulator');
          expect(arguments, ['-list-avds']);
          return FakeProcess(stdout: 'Pixel_9_API_34\r\nTablet_API_28\n');
        },
      );
      final adb = runtime(processes: processes);
      addTearDown(adb.close);

      expect(await adb.listAvds(emulatorPath: '/sdk/emulator/emulator'), [
        'Pixel_9_API_34',
        'Tablet_API_28',
      ]);
      expect(processes.spawns, hasLength(1));
    },
  );

  test(
    'listAvds kills the SDK command at the deadline and reports it',
    () async {
      final hung = FakeProcess.detached();
      final processes = FakeProcessHost(onStart: (_, _, _) async => hung);
      final adb = runtime(
        processes: processes,
        commandTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(adb.close);

      await expectLater(
        adb.listAvds(emulatorPath: '/sdk/emulator/emulator'),
        throwsA(isA<AppError>()),
      );
      expect(hung.killed, isTrue);
    },
  );

  test(
    'listAvds refuses oversized SDK output instead of truncating names',
    () async {
      final processes = FakeProcessHost(
        onStart: (_, _, _) async => FakeProcess(stdout: 'A' * 200),
      );
      final adb = runtime(processes: processes, maxOutputBytes: 64);
      addTearDown(adb.close);

      await expectLater(
        adb.listAvds(emulatorPath: '/sdk/emulator/emulator'),
        throwsA(isA<AppError>()),
      );
    },
  );

  test(
    'listAvds reports a missing emulator binary instead of an empty list',
    () async {
      final processes = FakeProcessHost()
        ..startError = const ProcessException('emulator', [
          '-list-avds',
        ], 'No such file or directory');
      final adb = runtime(processes: processes);
      addTearDown(adb.close);

      await expectLater(
        adb.listAvds(emulatorPath: '/missing/emulator'),
        throwsA(isA<AppError>()),
      );
      expect(processes.spawns, hasLength(1));
    },
  );

  test('network connect owns a loopback nodaemon server and exposes only a loopback base', () async {
    final processes = FakeProcessHost();
    final fixture = OwnedServerFixture(processes)..install();
    final requested = <Uri>[];
    final adb = runtime(
      processes: processes,
      device: (url) {
        requested.add(url);
        return deviceJson(uuid: 'uuid-9');
      },
    );
    addTearDown(adb.close);
    final profile = AndroidAdbProfile(
      mode: AndroidAdbMode.network,
      target: '192.168.50.3:5555',
      adbPath: '/sdk/adb',
    );

    final device = await adb.connect(profile, expectedUuid: 'uuid-9');

    final spawn = processes.spawns.single;
    expect(spawn.executable, '/sdk/adb');
    expect(spawn.arguments[0], '-L');
    expect(spawn.arguments[1], startsWith('tcp:'));
    expect(spawn.arguments[1], isNot('tcp:5037'));
    expect(spawn.arguments[3], isNotEmpty);
    expect(spawn.arguments.sublist(4), ['server', 'nodaemon']);
    expect(
      fixture.server!.requests,
      contains('host:connect:192.168.50.3:5555'),
    );
    expect(
      fixture.server!.requests.any((r) => r.contains('kill-server')),
      isFalse,
    );
    expect(device.uuid, 'uuid-9');
    expect(
      device.reachableBase,
      'http://127.0.0.1:${fixture.server!.forwards.single[1]}',
    );
    expect(requested.single.host, '127.0.0.1');
    expect(requested.single.toString(), isNot(contains('192.168.50.3')));
    expect(fixture.server!.forwards.single[0], '192.168.50.3:5555');
    expect(fixture.server!.forwards.single[2], '9978');
    expect(adb.profileForUuid('uuid-9')!.target, '192.168.50.3:5555');
    expect(adb.deviceForUuid('uuid-9')!.name, '设备');

    await adb.close();
    expect(fixture.owned!.killed, isTrue);
    await expectLater(
      Socket.connect('127.0.0.1', fixture.server!.port),
      throwsA(isA<SocketException>()),
    );
  });

  test(
    'connect reuses a live session instead of spawning a second owned server',
    () async {
      final processes = FakeProcessHost();
      final fixture = OwnedServerFixture(processes)..install();
      final adb = runtime(processes: processes);
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '192.168.50.3:5555',
        adbPath: '/sdk/adb',
      );

      final first = await adb.connect(profile);
      final second = await adb.connect(profile);

      expect(second.uuid, first.uuid);
      expect(processes.spawns, hasLength(1));
      expect(fixture.server!.forwards, hasLength(1));
    },
  );

  test(
    'concurrent connects coalesce into one owned server and one forward',
    () async {
      final processes = FakeProcessHost();
      final fixture = OwnedServerFixture(processes)..install();
      final adb = runtime(processes: processes);
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '192.168.50.3:5555',
        adbPath: '/sdk/adb',
      );

      final devices = await Future.wait([
        adb.connect(profile),
        adb.connect(profile),
      ]);

      expect(devices.map((device) => device.uuid).toSet(), {'uuid-1'});
      expect(processes.spawns, hasLength(1));
      expect(fixture.server!.forwards, hasLength(1));
    },
  );

  test('device connect borrows the configured localhost server and never starts or kills it', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['emulator-5554'] = 'device';
    server.devices['R58M12345'] = 'device';
    final processes = FakeProcessHost();
    final requested = <Uri>[];
    final adb = runtime(
      processes: processes,
      device: (url) {
        requested.add(url);
        return deviceJson(uuid: 'uuid-3');
      },
    );
    addTearDown(adb.close);
    final profile = AndroidAdbProfile(
      mode: AndroidAdbMode.device,
      target: 'R58M12345',
      serverPort: server.port,
    );

    final device = await adb.connect(profile);

    expect(device.uuid, 'uuid-3');
    expect(processes.spawns, isEmpty);
    expect(server.forwards.single[0], 'R58M12345');
    expect(requested.single.port, int.parse(server.forwards.single[1]));

    await adb.close();
    expect(server.killRequests, isNotEmpty);
    expect(server.forwards, isEmpty);
    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.destroy();
  });

  test(
    'device connect refuses a non-READY serial without choosing another device',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'unauthorized';
      server.devices['emulator-5554'] = 'device';
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      );

      await expectLater(adb.connect(profile), throwsA(isA<AppError>()));
      expect(server.forwards, isEmpty);
      expect(server.requests.any((r) => r.contains('emulator-5554')), isFalse);
      expect(adb.deviceForUuid('uuid-1'), isNull);
    },
  );

  test('expected UUID mismatch removes only the new forward and keeps the borrowed server', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = runtime(
      processes: FakeProcessHost(),
      device: (_) => deviceJson(uuid: 'uuid-other'),
    );
    addTearDown(adb.close);
    final profile = AndroidAdbProfile(
      mode: AndroidAdbMode.device,
      target: 'R58M12345',
      serverPort: server.port,
    );

    await expectLater(
      adb.connect(profile, expectedUuid: 'uuid-1'),
      throwsA(isA<AppError>()),
    );
    expect(server.killRequests, hasLength(1));
    expect(server.forwards, isEmpty);
    expect(adb.profileForUuid('uuid-other'), isNull);
    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.destroy();
  });

  test(
    'a zero forward reply fails the connect instead of exposing port 0',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      server.forwardReply = '0';
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      );

      await expectLater(adb.connect(profile), throwsA(isA<AppError>()));
      expect(adb.deviceForUuid('uuid-1'), isNull);
    },
  );

  test(
    'an existing gateway forward is reused and left untouched on close',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      server.forwards.add(['R58M12345', '27100', '9978']);
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      );

      final device = await adb.connect(profile);

      expect(device.reachableBase, 'http://127.0.0.1:27100');
      expect(server.requests.any((r) => r.contains('forward:tcp:0')), isFalse);
      await adb.close();
      expect(server.forwards, hasLength(1));
      expect(server.killRequests, isEmpty);
    },
  );

  test(
    'close during a pending connect fails it and kills only the owned server',
    () async {
      final processes = FakeProcessHost();
      final fixture = OwnedServerFixture(processes)..install();
      final started = Completer<void>();
      final gate = Completer<void>();
      final adb = runtime(
        processes: processes,
        device: (_) async {
          started.complete();
          await gate.future;
          return deviceJson();
        },
      );
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '192.168.50.3:5555',
        adbPath: '/sdk/adb',
      );

      final pending = adb.connect(profile);
      await started.future;
      await adb.close();
      gate.complete();

      await expectLater(pending, throwsA(isA<AppError>()));
      expect(fixture.owned!.killed, isTrue);
      expect(adb.deviceForUuid('uuid-1'), isNull);
    },
  );

  test(
    'AVD connect finds a running AVD by verified name and never launches one',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['emulator-5554'] = 'device';
      server.devices['emulator-5556'] = 'device';
      server.avdNames['emulator-5554'] = 'Tablet_API_28';
      server.avdNames['emulator-5556'] = 'Pixel_9_API_34';
      final processes = FakeProcessHost();
      final adb = runtime(processes: processes);
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.avd,
        target: 'Pixel_9_API_34',
        serverPort: server.port,
      );

      final device = await adb.connect(profile);

      expect(device.uuid, 'uuid-1');
      expect(processes.spawns, isEmpty);
      expect(server.forwards.single[0], 'emulator-5556');
    },
  );

  test(
    'AVD connect refuses to guess when no AVD name metadata is available',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['emulator-5554'] = 'device';
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.avd,
        target: 'Pixel_9_API_34',
        serverPort: server.port,
      );

      await expectLater(
        adb.connect(profile),
        throwsA(
          isA<AppError>().having((e) => e.message, 'message', contains('序列号')),
        ),
      );
      expect(server.forwards, isEmpty);
      expect(adb.deviceForUuid('uuid-1'), isNull);
    },
  );

  test('explicit AVD launch runs the exact SDK name on an owned server and close never stops the VM', () async {
    final processes = FakeProcessHost();
    FakeAdbServer? server;
    FakeProcess? owned;
    FakeProcess? emulator;
    processes.onStart = (executable, arguments, environment) async {
      if (executable == '/sdk/emulator/emulator' &&
          arguments.first == '-list-avds') {
        return FakeProcess(stdout: 'Pixel_9_API_34\nTablet_API_28\n');
      }
      if (executable == '/sdk/emulator/emulator') {
        emulator = FakeProcess.detached();
        expect(arguments, ['-avd', 'Pixel_9_API_34']);
        expect(environment!['ANDROID_AVD_HOME'], '/avd/home');
        expect(environment['ANDROID_ADB_SERVER_PORT'], isNotNull);
        server?.devices['emulator-5554'] = 'device';
        server?.avdNames['emulator-5554'] = 'Pixel_9_API_34';
        return emulator!;
      }
      final port = int.parse(arguments[1].substring(4));
      final fixture = await FakeAdbServer.bind(port: port);
      server = fixture;
      owned = FakeProcess.detached(
        onKill: () async {
          await fixture.close();
        },
      );
      return owned!;
    };
    final adb = runtime(processes: processes);
    addTearDown(adb.close);
    final profile = AndroidAdbProfile(
      mode: AndroidAdbMode.avd,
      target: 'Pixel_9_API_34',
      adbPath: '/sdk/adb',
      emulatorPath: '/sdk/emulator/emulator',
      avdHome: '/avd/home',
    );

    final device = await adb.connect(profile, launchAvd: true);

    expect(device.uuid, 'uuid-1');
    expect(server!.forwards.single[0], 'emulator-5554');
    final serverPort = processes.spawns[1].arguments[1].substring(4);
    expect(
      processes.spawns[2].environment!['ANDROID_ADB_SERVER_PORT'],
      serverPort,
    );

    await adb.close();
    expect(owned!.killed, isTrue);
    expect(emulator!.killed, isFalse);
  });

  test(
    'AVD launch refuses a name absent from the installed SDK list',
    () async {
      final processes = FakeProcessHost(
        onStart: (_, _, _) async => FakeProcess(stdout: 'Other_API_30\n'),
      );
      final adb = runtime(processes: processes);
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.avd,
        target: 'Pixel_9_API_34',
        adbPath: '/sdk/adb',
        emulatorPath: '/sdk/emulator/emulator',
      );

      await expectLater(
        adb.connect(profile, launchAvd: true),
        throwsA(isA<AppError>()),
      );
      expect(processes.spawns, hasLength(1));
      expect(processes.spawns.single.arguments, ['-list-avds']);
    },
  );

  test(
    'resolver grants only the proven guest origin of its own gateway',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      await adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M12345',
          serverPort: server.port,
        ),
      );
      final gatewayLocal = int.parse(server.forwards.single[1]);

      final resolver = adb.resolverForGateway(
        Uri.parse('http://127.0.0.1:$gatewayLocal'),
        logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
      );
      expect(resolver, isNotNull);

      final local = await resolver!(
        Uri.parse('http://127.0.0.1:5000/proxy/vod/ep1.mp4'),
      );
      expect(local, isNotNull);
      final media = server.forwards.where((row) => row[2] == '5000').single;
      expect(media[0], 'R58M12345');
      expect(media[1], '$local');

      expect(await resolver(Uri.parse('http://127.0.0.1:8080/x')), isNull);
      expect(await resolver(Uri.parse('https://127.0.0.1:5000/x')), isNull);
      expect(await resolver(Uri.parse('http://example.com:5000/x')), isNull);
      expect(await resolver(Uri.parse('http://127.0.0.1/x')), isNull);

      expect(await resolver(Uri.parse('http://localhost:5000/y')), local);
      expect(server.forwards.where((row) => row[2] == '5000'), hasLength(1));
    },
  );

  test(
    'resolverForGateway returns null for an unrelated or unproven origin',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      await adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M12345',
          serverPort: server.port,
        ),
      );
      final gatewayLocal = int.parse(server.forwards.single[1]);
      final gateway = Uri.parse('http://127.0.0.1:$gatewayLocal');

      expect(
        adb.resolverForGateway(
          Uri.parse('http://127.0.0.1:29999'),
          logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
        ),
        isNull,
      );
      expect(
        adb.resolverForGateway(
          Uri.parse('http://example.com:$gatewayLocal'),
          logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
        ),
        isNull,
      );
      expect(
        adb.resolverForGateway(
          gateway,
          logicalOrigin: Uri.parse('ftp://127.0.0.1:5000'),
        ),
        isNull,
      );
      expect(
        adb.resolverForGateway(
          gateway,
          logicalOrigin: Uri.parse('http://10.0.0.5:5000'),
        ),
        isNull,
      );
    },
  );

  test(
    'resolver fails closed after close instead of falling back to a PC port',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      await adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M12345',
          serverPort: server.port,
        ),
      );
      final gatewayLocal = int.parse(server.forwards.single[1]);
      final resolver = adb.resolverForGateway(
        Uri.parse('http://127.0.0.1:$gatewayLocal'),
        logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
      );

      await adb.close();
      final requestsAfterClose = server.requests.length;

      await expectLater(
        resolver!(Uri.parse('http://127.0.0.1:5000/x')),
        throwsA(isA<AppError>()),
      );
      expect(server.requests, hasLength(requestsAfterClose));
      expect(server.forwards.where((row) => row[2] == '5000'), isEmpty);
    },
  );

  test('resolver fails closed when the selected device disappears', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = runtime(processes: FakeProcessHost());
    addTearDown(adb.close);
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );
    final gatewayLocal = int.parse(server.forwards.single[1]);
    final resolver = adb.resolverForGateway(
      Uri.parse('http://127.0.0.1:$gatewayLocal'),
      logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
    )!;

    server.devices.remove('R58M12345');

    await expectLater(
      resolver(Uri.parse('http://127.0.0.1:5000/x')),
      throwsA(isA<AppError>()),
    );
    expect(server.forwards.where((row) => row[2] == '5000'), isEmpty);
  });

  test(
    'resolver fails closed when its gateway forward is reassigned',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      await adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M12345',
          serverPort: server.port,
        ),
      );
      final gatewayLocal = int.parse(server.forwards.single[1]);
      final resolver = adb.resolverForGateway(
        Uri.parse('http://127.0.0.1:$gatewayLocal'),
        logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
      )!;

      server.forwards.removeWhere((row) => row[1] == '$gatewayLocal');

      await expectLater(
        resolver(Uri.parse('http://127.0.0.1:5000/x')),
        throwsA(isA<AppError>()),
      );
      expect(server.forwards.where((row) => row[2] == '5000'), isEmpty);
    },
  );

  test('concurrent resolver calls coalesce into one media forward', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = runtime(processes: FakeProcessHost());
    addTearDown(adb.close);
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );
    final gatewayLocal = int.parse(server.forwards.single[1]);
    final resolver = adb.resolverForGateway(
      Uri.parse('http://127.0.0.1:$gatewayLocal'),
      logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
    )!;

    final locals = await Future.wait([
      resolver(Uri.parse('http://127.0.0.1:5000/a')),
      resolver(Uri.parse('http://127.0.0.1:5000/b')),
    ]);

    expect(locals.toSet(), hasLength(1));
    expect(locals.first, isNotNull);
    expect(server.forwards.where((row) => row[2] == '5000'), hasLength(1));
  });

  // 说明：本用例在 disconnect 实现完成后补写（非 RED 先验），作为按设备隔离的
  // 回归覆盖；其余 26 个用例均为先写测试后实现。
  test(
    'disconnect drops only the selected device and tombstones its resolver',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      server.devices['emulator-5554'] = 'device';
      var uuid = 'uuid-a';
      final adb = runtime(
        processes: FakeProcessHost(),
        device: (_) => deviceJson(uuid: uuid),
      );
      addTearDown(adb.close);
      final first = await adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M12345',
          serverPort: server.port,
        ),
      );
      uuid = 'uuid-b';
      final second = await adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'emulator-5554',
          serverPort: server.port,
        ),
      );
      final gatewayLocal = int.parse(
        server.forwards.firstWhere((row) => row[0] == 'R58M12345')[1],
      );
      final resolver = adb.resolverForGateway(
        Uri.parse('http://127.0.0.1:$gatewayLocal'),
        logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
      )!;

      await adb.disconnect(first.uuid);

      expect(adb.deviceForUuid(first.uuid), isNull);
      expect(adb.deviceForUuid(second.uuid), isNotNull);
      await expectLater(
        resolver(Uri.parse('http://127.0.0.1:5000/x')),
        throwsA(isA<AppError>()),
      );
      expect(server.forwards.where((row) => row[0] == 'R58M12345'), isEmpty);
      expect(
        server.forwards.where((row) => row[0] == 'emulator-5554'),
        hasLength(1),
      );
    },
  );

  test('a failed reconnect keeps an existing same-serial session gateway and media leases', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    var uuid = 'uuid-a';
    final adb = runtime(
      processes: FakeProcessHost(),
      device: (_) => deviceJson(uuid: uuid),
    );
    addTearDown(adb.close);
    final first = await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );
    final gatewayLocal = int.parse(
      server.forwards.firstWhere((row) => row[2] == '9978')[1],
    );
    final resolver = adb.resolverForGateway(
      Uri.parse('http://127.0.0.1:$gatewayLocal'),
      logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
    )!;
    final mediaLocal = await resolver(Uri.parse('http://127.0.0.1:5000/x'));
    expect(mediaLocal, isNotNull);
    expect(adb.deviceForUuid(first.uuid), isNotNull);

    uuid = 'uuid-other';
    await expectLater(
      adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M12345',
          gatewayPort: 9990,
          serverPort: server.port,
        ),
        expectedUuid: 'uuid-a',
      ),
      throwsA(isA<AppError>()),
    );

    expect(server.forwards.where((row) => row[2] == '9978'), hasLength(1));
    expect(server.forwards.where((row) => row[2] == '5000'), hasLength(1));
    expect(server.forwards.where((row) => row[2] == '9990'), isEmpty);
    expect(adb.deviceForUuid('uuid-a'), isNotNull);

    uuid = 'uuid-a';
    expect(await resolver(Uri.parse('http://127.0.0.1:5000/y')), mediaLocal);
  });

  test(
    'concurrent connects with compatible expectations share one preparation',
    () async {
      final processes = FakeProcessHost();
      final fixture = OwnedServerFixture(processes)..install();
      final gate = Completer<void>();
      final adb = runtime(
        processes: processes,
        device: (_) async {
          await gate.future;
          return deviceJson();
        },
      );
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '192.168.50.3:5555',
        adbPath: '/sdk/adb',
      );

      final first = adb.connect(profile);
      final second = adb.connect(profile, expectedUuid: 'uuid-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete();

      final devices = await Future.wait([first, second]);
      expect(devices.map((device) => device.uuid).toSet(), {'uuid-1'});
      expect(processes.spawns, hasLength(1));
      expect(fixture.server!.forwards, hasLength(1));
    },
  );

  test('a conflicting concurrent expectation is rejected instead of opening another server', () async {
    final processes = FakeProcessHost();
    final fixture = OwnedServerFixture(processes)..install();
    final gate = Completer<void>();
    final adb = runtime(
      processes: processes,
      device: (_) async {
        await gate.future;
        return deviceJson();
      },
    );
    addTearDown(adb.close);
    final profile = AndroidAdbProfile(
      mode: AndroidAdbMode.network,
      target: '192.168.50.3:5555',
      adbPath: '/sdk/adb',
    );

    final first = adb.connect(profile, expectedUuid: 'uuid-1');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await expectLater(
      adb.connect(profile, expectedUuid: 'uuid-2'),
      throwsA(isA<AppError>()),
    );
    gate.complete();

    expect((await first).uuid, 'uuid-1');
    expect(processes.spawns, hasLength(1));
    expect(fixture.server!.forwards, hasLength(1));
  });

  test(
    'a new session for the same device UUID replaces and closes the prior one',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['emulator-5554'] = 'device';
      server.devices['R58M12345'] = 'device';
      final adb = runtime(processes: FakeProcessHost());
      addTearDown(adb.close);
      final profileA = AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'emulator-5554',
        serverPort: server.port,
      );
      final profileB = AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      );

      await adb.connect(profileA);
      expect(
        server.forwards.where((row) => row[0] == 'emulator-5554'),
        hasLength(1),
      );

      await adb.connect(profileB);
      expect(
        server.forwards.where((row) => row[0] == 'emulator-5554'),
        isEmpty,
      );
      expect(
        server.forwards.where((row) => row[0] == 'R58M12345'),
        hasLength(1),
      );
      expect(adb.profileForUuid('uuid-1')!.target, 'R58M12345');

      await adb.disconnect('uuid-1');
      expect(server.forwards, isEmpty);
      expect(adb.deviceForUuid('uuid-1'), isNull);
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.destroy();
    },
  );

  test('a managed gateway stays recognized and fails closed after disconnect and close', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = runtime(processes: FakeProcessHost());
    addTearDown(adb.close);
    final profile = AndroidAdbProfile(
      mode: AndroidAdbMode.device,
      target: 'R58M12345',
      serverPort: server.port,
    );
    final device = await adb.connect(profile);
    final gateway = Uri.parse('http://127.0.0.1:${server.forwards.single[1]}');
    final origin = Uri.parse('http://127.0.0.1:5000');
    expect(adb.recognizesGateway(gateway), isTrue);

    await adb.disconnect(device.uuid);
    expect(adb.recognizesGateway(gateway), isTrue);
    final retired = adb.resolverForGateway(gateway, logicalOrigin: origin);
    expect(retired, isNotNull);
    await expectLater(
      retired!(Uri.parse('http://127.0.0.1:5000/x')),
      throwsA(isA<AppError>()),
    );

    final unknown = Uri.parse('http://127.0.0.1:29999');
    expect(adb.recognizesGateway(unknown), isFalse);
    expect(adb.resolverForGateway(unknown, logicalOrigin: origin), isNull);

    await adb.connect(profile);
    await adb.close();
    expect(adb.recognizesGateway(gateway), isTrue);
    final closed = adb.resolverForGateway(gateway, logicalOrigin: origin);
    expect(closed, isNotNull);
    await expectLater(
      closed!(Uri.parse('http://127.0.0.1:5000/x')),
      throwsA(isA<AppError>()),
    );
  });

  test('resolver requires strict loopback origins and refuses userinfo or bogus IPs', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = runtime(processes: FakeProcessHost());
    addTearDown(adb.close);
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );
    final gatewayLocal = int.parse(server.forwards.single[1]);
    final gateway = Uri.parse('http://127.0.0.1:$gatewayLocal');
    final origin = Uri.parse('http://127.0.0.1:5000');
    final resolver = adb.resolverForGateway(gateway, logicalOrigin: origin)!;

    expect(await resolver(Uri.parse('http://127.0.0.1:5000/x')), isNotNull);
    expect(
      await resolver(Uri.parse('http://user:pw@127.0.0.1:5000/x')),
      isNull,
    );
    expect(await resolver(Uri.parse('http://127.999.0.1:5000/x')), isNull);
    expect(
      adb.resolverForGateway(
        Uri.parse('http://user:pw@127.0.0.1:$gatewayLocal'),
        logicalOrigin: origin,
      ),
      isNull,
    );
    expect(
      adb.resolverForGateway(
        Uri.parse('http://127.999.0.1:$gatewayLocal'),
        logicalOrigin: origin,
      ),
      isNull,
    );
    expect(
      adb.resolverForGateway(
        Uri.parse('ftp://127.0.0.1:$gatewayLocal'),
        logicalOrigin: origin,
      ),
      isNull,
    );
  });

  test('default guest HTTP and HTTPS ports are pinned origins', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = runtime(processes: FakeProcessHost());
    addTearDown(adb.close);
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );
    final gateway = Uri.parse('http://127.0.0.1:${server.forwards.single[1]}');

    final httpResolver = adb.resolverForGateway(
      gateway,
      logicalOrigin: Uri.parse('http://127.0.0.1'),
    );
    expect(httpResolver, isNotNull);
    expect(await httpResolver!(Uri.parse('http://localhost/x')), isNotNull);
    expect(server.forwards.where((row) => row[2] == '80'), hasLength(1));
    expect(await httpResolver(Uri.parse('http://127.0.0.1:8080/x')), isNull);

    final httpsResolver = adb.resolverForGateway(
      gateway,
      logicalOrigin: Uri.parse('https://127.0.0.1'),
    );
    expect(httpsResolver, isNotNull);
    expect(
      await httpsResolver!(Uri.parse('https://127.0.0.1:443/y')),
      isNotNull,
    );
    expect(server.forwards.where((row) => row[2] == '443'), hasLength(1));
    expect(await httpsResolver(Uri.parse('http://127.0.0.1:443/z')), isNull);
  });

  test(
    'resolver fails closed when the gateway reports a different device UUID',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      var uuid = 'uuid-a';
      final adb = runtime(
        processes: FakeProcessHost(),
        device: (_) => deviceJson(uuid: uuid),
      );
      addTearDown(adb.close);
      await adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M12345',
          serverPort: server.port,
        ),
      );
      final gatewayLocal = int.parse(server.forwards.single[1]);
      final resolver = adb.resolverForGateway(
        Uri.parse('http://127.0.0.1:$gatewayLocal'),
        logicalOrigin: Uri.parse('http://127.0.0.1:5000'),
      )!;

      uuid = 'uuid-b';

      await expectLater(
        resolver(Uri.parse('http://127.0.0.1:5000/x')),
        throwsA(isA<AppError>()),
      );
      expect(server.forwards.where((row) => row[2] == '5000'), isEmpty);
    },
  );

  test(
    'a launched AVD is reused on reconnect without a second emulator process',
    () async {
      final processes = FakeProcessHost();
      FakeAdbServer? server;
      FakeProcess? owned;
      FakeProcess? emulator;
      final deadPort = await unusedPort();
      processes.onStart = (executable, arguments, environment) async {
        if (executable == '/sdk/emulator/emulator' &&
            arguments.first == '-list-avds') {
          return FakeProcess(stdout: 'Pixel_9_API_34\n');
        }
        if (executable == '/sdk/emulator/emulator') {
          emulator = FakeProcess.detached();
          expect(arguments, ['-avd', 'Pixel_9_API_34']);
          server?.devices['emulator-5554'] = 'device';
          server?.avdNames['emulator-5554'] = 'Pixel_9_API_34';
          return emulator!;
        }
        final port = int.parse(arguments[1].substring(4));
        final fixture = await FakeAdbServer.bind(port: port);
        server = fixture;
        owned = FakeProcess.detached(
          onKill: () async {
            await fixture.close();
          },
        );
        return owned!;
      };
      final adb = runtime(processes: processes);
      addTearDown(adb.close);
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.avd,
        target: 'Pixel_9_API_34',
        adbPath: '/sdk/adb',
        emulatorPath: '/sdk/emulator/emulator',
        serverPort: deadPort,
      );

      final first = await adb.connect(profile, launchAvd: true);
      int launches() => processes.spawns
          .where(
            (spawn) =>
                spawn.arguments.isNotEmpty && spawn.arguments.first == '-avd',
          )
          .length;
      expect(launches(), 1);

      await adb.disconnect(first.uuid);
      expect(emulator!.killed, isFalse);
      expect(owned!.killed, isFalse);

      final second = await adb.connect(profile, launchAvd: false);
      expect(second.uuid, first.uuid);
      expect(launches(), 1);
      expect(server!.forwards.single[0], 'emulator-5554');

      await adb.connect(profile, launchAvd: true);
      expect(launches(), 1);

      await adb.close();
      expect(owned!.killed, isTrue);
      expect(emulator!.killed, isFalse);
    },
  );

  test('close force-kills an owned server that ignores termination', () async {
    final processes = FakeProcessHost();
    late FakeAdbServer server;
    FakeProcess? owned;
    processes.onStart = (executable, arguments, environment) async {
      final port = int.parse(arguments[1].substring(4));
      server = await FakeAdbServer.bind(port: port);
      owned = FakeProcess.stubborn();
      return owned!;
    };
    final adb = runtime(processes: processes);
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '192.168.50.3:5555',
        adbPath: '/sdk/adb',
      ),
    );

    await adb.close().timeout(const Duration(seconds: 5));

    expect(owned!.killed, isTrue);
    expect(processes.forcedKills, [4242]);
    expect(processes.spawns, hasLength(1));
    await server.close();
  });

  test('reverse creation always uses the atomic norebind form', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = await connected(server);

    await adb.ensureReverse('uuid-1', localPort: 44101);
    await adb.ensureReverse('uuid-1', localPort: 44102, guestPort: 8931);

    final forwards = server.deviceRequests
        .where((request) => request.startsWith('reverse:forward'))
        .toList();
    expect(forwards, [
      'reverse:forward:norebind:tcp:0;tcp:44101',
      'reverse:forward:norebind:tcp:8931;tcp:44102',
    ]);
    expect(
      forwards.any((request) => request.startsWith('reverse:forward:tcp:')),
      isFalse,
    );
  });

  test(
    'a foreign reverse row appearing after the list fails the bind atomically',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      server.reverseRaceInsertRow = true;
      final adb = await connected(server);

      await expectLater(
        adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 8930),
        throwsA(
          isA<AppError>().having(
            (error) => error.message,
            'message',
            contains('占用'),
          ),
        ),
      );

      // 别人的行原样保留：没有被改写、没有被删除、没有本模块的租约。
      expect(server.reverseRows, [
        ['8930', '49999'],
      ]);
      expect(
        server.deviceRequests.any(
          (request) => request.startsWith('reverse:killforward'),
        ),
        isFalse,
      );
      expect(
        server.deviceRequests.any(
          (request) => request.startsWith('reverse:forward:tcp:'),
        ),
        isFalse,
      );
      await adb.releaseReverse('uuid-1', 8930);
      expect(server.reverseRows, [
        ['8930', '49999'],
      ]);
    },
  );

  test('ensureReverse allocates a device port when guest is zero', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = await connected(server);

    final guest = await adb.ensureReverse('uuid-1', localPort: 44101);

    expect(guest, 38001);
    expect(server.reverseRows, [
      ['38001', '44101'],
    ]);
    expect(
      server.deviceRequests,
      contains('reverse:forward:norebind:tcp:0;tcp:44101'),
    );
    expect(server.requests, contains('host-serial:R58M12345:transport'));
    // reverse 必须是 transport 之后的 device 服务，不能走主机解析器。
    expect(
      server.requests.any((request) => request.contains('reverse:')),
      isFalse,
    );
    expect(
      server.deviceRequests.any(
        (request) => request.contains('killforward-all'),
      ),
      isFalse,
    );

    await adb.releaseReverse('uuid-1', 38001);
    expect(server.reverseRows, isEmpty);
    expect(server.deviceRequests, contains('reverse:killforward:tcp:38001'));
  });

  test('ensureReverse restores an explicit guest port without rebinding a borrowed row', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    server.reverseRows.add(['8930', '44101']);
    final adb = await connected(server);

    final guest = await adb.ensureReverse(
      'uuid-1',
      localPort: 44101,
      guestPort: 8930,
    );

    expect(guest, 8930);
    expect(
      server.deviceRequests.any(
        (request) => request.startsWith('reverse:forward'),
      ),
      isFalse,
    );
    expect(server.reverseRows, [
      ['8930', '44101'],
    ]);

    await adb.releaseReverse('uuid-1', 8930);
    expect(server.reverseRows, [
      ['8930', '44101'],
    ]);
    expect(
      server.deviceRequests.any(
        (request) => request.startsWith('reverse:killforward'),
      ),
      isFalse,
    );
  });

  test('ensureReverse fails clearly on a conflicting guest port without touching the row', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    server.reverseRows.add(['8930', '40001']);
    final adb = await connected(server);

    await expectLater(
      adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 8930),
      throwsA(isA<AppError>()),
    );
    expect(server.reverseRows, [
      ['8930', '40001'],
    ]);
    expect(
      server.deviceRequests.any(
        (request) => request.startsWith('reverse:forward'),
      ),
      isFalse,
    );
    expect(
      server.deviceRequests.any(
        (request) => request.startsWith('reverse:killforward'),
      ),
      isFalse,
    );

    await expectLater(
      adb.ensureReverse('uuid-1', localPort: 0),
      throwsA(isA<AppError>()),
    );
    await expectLater(
      adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 70000),
      throwsA(isA<AppError>()),
    );
    expect(
      server.deviceRequests.any(
        (request) => request.startsWith('reverse:forward'),
      ),
      isFalse,
    );
  });

  test('reverse release removes only the lease this runtime created', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    server.reverseRows.add(['8930', '40001']);
    final adb = await connected(server);

    expect(await adb.ensureReverse('uuid-1', localPort: 44101), 38001);
    expect(server.reverseRows, hasLength(2));

    await adb.releaseReverse('uuid-1', 38001);
    expect(server.reverseRows, [
      ['8930', '40001'],
    ]);
    expect(
      server.deviceRequests.any((request) => request.contains('8930')),
      isFalse,
    );

    // 释放不属于自己的 guest 端口是 no-op（不删用户行）。
    await adb.releaseReverse('uuid-1', 8930);
    expect(server.reverseRows, [
      ['8930', '40001'],
    ]);
  });

  test('a rejected reverse bind fails clearly and leaves no lease', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    server.reverseForwardFails = true;
    final adb = await connected(server);

    await expectLater(
      adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 8930),
      throwsA(isA<AppError>()),
    );
    expect(server.reverseRows, isEmpty);
    await adb.releaseReverse('uuid-1', 8930);
    expect(
      server.deviceRequests.any(
        (request) => request.startsWith('reverse:killforward'),
      ),
      isFalse,
    );
  });

  test('reverse operations require a live connection and re-verify the device UUID', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    var uuid = 'uuid-1';
    final adb = await connected(server, device: (_) => deviceJson(uuid: uuid));

    await expectLater(
      adb.ensureReverse('uuid-unknown', localPort: 44101),
      throwsA(isA<AppError>()),
    );

    uuid = 'uuid-2';
    await expectLater(
      adb.ensureReverse('uuid-1', localPort: 44101),
      throwsA(isA<AppError>()),
    );
    expect(
      server.deviceRequests.any(
        (request) => request.startsWith('reverse:forward'),
      ),
      isFalse,
    );

    uuid = 'uuid-1';
    expect(await adb.ensureReverse('uuid-1', localPort: 44101), 38001);

    await adb.disconnect('uuid-1');
    await expectLater(
      adb.ensureReverse('uuid-1', localPort: 44101),
      throwsA(isA<AppError>()),
    );

    await adb.close();
    await expectLater(
      adb.ensureReverse('uuid-1', localPort: 44101),
      throwsA(isA<AppError>()),
    );
    await expectLater(
      adb.releaseReverse('uuid-1', 38001),
      throwsA(isA<AppError>()),
    );
  });

  test(
    'reverse frames are reassembled when the SDK reply is fragmented',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      server.reverseRows.add(['8930', '44101']);
      server.fragmentReverseFrames = true;
      final adb = await connected(server);

      expect(
        await adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 8930),
        8930,
      );
      expect(await adb.ensureReverse('uuid-1', localPort: 44102), 38001);
      expect(
        await adb.ensureReverse('uuid-1', localPort: 44103, guestPort: 8931),
        8931,
      );
      await adb.releaseReverse('uuid-1', 38001);
      expect(server.reverseRows.map((row) => row[0]).toSet(), {'8930', '8931'});
    },
  );

  test('a fixed guest port keeps the same device URL across an SDK reconnect with a new local port', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = await connected(server);

    expect(
      await adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 8930),
      8930,
    );
    expect(server.reverseRows, [
      ['8930', '44101'],
    ]);

    // adbd 在 transport 重置后丢弃 reverse 规则：模拟 SDK 重连后的空表。
    server.reverseRows.clear();
    await adb.disconnect('uuid-1');
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );

    final guest = await adb.ensureReverse(
      'uuid-1',
      localPort: 44102,
      guestPort: 8930,
    );
    expect(guest, 8930);
    expect(server.reverseRows, [
      ['8930', '44102'],
    ]);
  });

  test('two PC configurations share one reverse lease safely and one release keeps the other', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = await connected(server);

    expect(
      await adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 8930),
      8930,
    );
    expect(
      await adb.ensureReverse('uuid-1', localPort: 44102, guestPort: 8931),
      8931,
    );
    expect(server.reverseRows, [
      ['8930', '44101'],
      ['8931', '44102'],
    ]);

    await adb.releaseReverse('uuid-1', 8930);
    expect(server.reverseRows, [
      ['8931', '44102'],
    ]);

    await adb.disconnect('uuid-1');
    expect(server.reverseRows, isEmpty);
  });

  test('reverse cleanup preserves borrowed rows and host forwards', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    server.reverseRows.add(['7000', '40009']);
    server.forwards.add(['R58M12345', '27100', '9978']);
    final adb = await connected(server);
    expect(await adb.ensureReverse('uuid-1', localPort: 44101), 38001);

    await adb.disconnect('uuid-1');
    expect(server.reverseRows, [
      ['7000', '40009'],
    ]);
    expect(server.forwards.where((row) => row[1] == '27100'), hasLength(1));
    expect(server.deviceRequests, contains('reverse:killforward:tcp:38001'));
    expect(
      server.deviceRequests.any((request) => request.contains('7000')),
      isFalse,
    );

    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );
    expect(await adb.ensureReverse('uuid-1', localPort: 44102), 38002);

    await adb.close();
    expect(server.reverseRows, [
      ['7000', '40009'],
    ]);
    expect(server.forwards.where((row) => row[1] == '27100'), hasLength(1));
  });

  test('a created reverse receipt releases its row exactly once', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = await connected(server);
    final receipt = await adb.acquireReverse('uuid-1', localPort: 44101);

    expect(receipt.uuid, 'uuid-1');
    expect(receipt.guestPort, 38001);
    expect(receipt.created, isTrue);
    expect(server.reverseRows, [
      ['38001', '44101'],
    ]);
    await Future.wait<void>([receipt.release(), receipt.release()]);
    await receipt.release();
    expect(server.reverseRows, isEmpty);
    expect(
      server.deviceRequests.where((r) => r == 'reverse:killforward:tcp:38001'),
      hasLength(1),
    );
  });

  test('a borrowed reverse receipt never sends killforward', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    server.reverseRows.add(['8930', '44101']);
    final adb = await connected(server);
    final receipt = await adb.acquireReverse(
      'uuid-1',
      localPort: 44101,
      guestPort: 8930,
    );

    expect(receipt.uuid, 'uuid-1');
    expect(receipt.guestPort, 8930);
    expect(receipt.created, isFalse);
    final requests = List<String>.of(server.deviceRequests);
    await receipt.release();
    await receipt.release();
    expect(server.deviceRequests, requests);
    await adb.close();
    expect(server.reverseRows, [
      ['8930', '44101'],
    ]);
    expect(
      server.deviceRequests.where((r) => r.startsWith('reverse:killforward')),
      isEmpty,
    );
  });

  test('caller B borrowing caller A exact row cannot roll it back', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = await connected(server);
    final a = await adb.acquireReverse(
      'uuid-1',
      localPort: 44101,
      guestPort: 8930,
    );
    final b = await adb.acquireReverse(
      'uuid-1',
      localPort: 44101,
      guestPort: 8930,
    );

    expect(a.created, isTrue);
    expect(b.created, isFalse);
    expect(a.guestPort, b.guestPort);
    await b.release();
    expect(server.reverseRows, [
      ['8930', '44101'],
    ]);
    expect(
      server.deviceRequests.where((r) => r.startsWith('reverse:killforward')),
      isEmpty,
    );
    await a.release();
    expect(server.reverseRows, isEmpty);
  });

  for (final shutdown in ['disconnect', 'close']) {
    test('created receipt release after $shutdown is a wire no-op', () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = await connected(server);
      final receipt = await adb.acquireReverse('uuid-1', localPort: 44101);
      if (shutdown == 'disconnect') {
        await adb.disconnect('uuid-1');
      } else {
        await adb.close();
      }
      expect(server.reverseRows, isEmpty);
      final requests = List<String>.of(server.requests);
      final deviceRequests = List<String>.of(server.deviceRequests);
      await receipt.release();
      await receipt.release();
      expect(server.requests, requests);
      expect(server.deviceRequests, deviceRequests);
      expect(
        deviceRequests.where((r) => r == 'reverse:killforward:tcp:38001'),
        hasLength(1),
      );
    });
  }

  test(
    'an old receipt cannot release a recreated lease on the same connection',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = await connected(server);
      final a = await adb.acquireReverse(
        'uuid-1',
        localPort: 44101,
        guestPort: 8930,
      );
      await adb.releaseReverse('uuid-1', 8930);
      final b = await adb.acquireReverse(
        'uuid-1',
        localPort: 44102,
        guestPort: 8930,
      );

      expect(b.created, isTrue);
      final requests = List<String>.of(server.deviceRequests);
      await a.release();
      expect(server.deviceRequests, requests);
      expect(server.reverseRows, [
        ['8930', '44102'],
      ]);
      await b.release();
      expect(server.reverseRows, isEmpty);
    },
  );

  test('a predecessor receipt cannot release a new connection lease', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = await connected(server);
    final a = await adb.acquireReverse(
      'uuid-1',
      localPort: 44101,
      guestPort: 8930,
    );
    await adb.disconnect('uuid-1');
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );
    final c = await adb.acquireReverse(
      'uuid-1',
      localPort: 44102,
      guestPort: 8930,
    );

    expect(c.created, isTrue);
    final requests = List<String>.of(server.deviceRequests);
    await a.release();
    expect(server.deviceRequests, requests);
    expect(server.reverseRows, [
      ['8930', '44102'],
    ]);
    await c.release();
    expect(server.reverseRows, isEmpty);
  });

  test(
    'receipt acquisition fails closed for different local ports on one guest',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = await connected(server);
      final a = await adb.acquireReverse(
        'uuid-1',
        localPort: 44101,
        guestPort: 8930,
      );

      await expectLater(
        adb.acquireReverse('uuid-1', localPort: 44102, guestPort: 8930),
        throwsA(isA<AppError>()),
      );
      expect(server.reverseRows, [
        ['8930', '44101'],
      ]);
      expect(
        server.deviceRequests.where((r) => r.startsWith('reverse:forward')),
        hasLength(1),
      );
      expect(
        server.deviceRequests.where((r) => r.startsWith('reverse:killforward')),
        isEmpty,
      );
      await a.release();
    },
  );

  test(
    'concurrent same-tuple receipts coalesce with exactly one creator',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = await connected(server);
      final receipts = await Future.wait<AndroidReverseLease>([
        adb.acquireReverse('uuid-1', localPort: 44101, guestPort: 8930),
        adb.acquireReverse('uuid-1', localPort: 44101, guestPort: 8930),
      ]);

      expect(receipts.map((receipt) => receipt.guestPort), [8930, 8930]);
      expect(receipts.where((receipt) => receipt.created), hasLength(1));
      expect(receipts.where((receipt) => !receipt.created), hasLength(1));
      expect(
        server.deviceRequests.where((r) => r.startsWith('reverse:forward')),
        hasLength(1),
      );
      await receipts.singleWhere((receipt) => !receipt.created).release();
      expect(server.reverseRows, [
        ['8930', '44101'],
      ]);
      await receipts.singleWhere((receipt) => receipt.created).release();
      expect(server.reverseRows, isEmpty);
    },
  );

  test('two live connection owners on one serial cannot release each other reverse row', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = runtime(
      processes: FakeProcessHost(),
      device: (url) {
        final row = server.forwards.singleWhere(
          (row) => row[1] == '${url.port}',
        );
        return deviceJson(uuid: row[2] == '9978' ? 'uuid-A' : 'uuid-C');
      },
    );
    addTearDown(adb.close);
    for (final port in [9978, 9990]) {
      await adb.connect(
        AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M12345',
          serverPort: server.port,
          gatewayPort: port,
        ),
      );
    }
    expect(adb.deviceForUuid('uuid-A'), isNotNull);
    expect(adb.deviceForUuid('uuid-C'), isNotNull);
    final a = await adb.acquireReverse(
      'uuid-A',
      localPort: 44101,
      guestPort: 8930,
    );
    final c = await adb.acquireReverse(
      'uuid-C',
      localPort: 44101,
      guestPort: 8930,
    );
    expect(a.created, isTrue);
    expect(c.created, isFalse);

    await c.release();
    await adb.releaseReverse('uuid-C', 8930);
    expect(server.reverseRows, [
      ['8930', '44101'],
    ]);
    expect(
      server.deviceRequests.where((r) => r.startsWith('reverse:killforward')),
      isEmpty,
    );
    final skipped = log.entries
        .where((entry) => entry.message.contains('8930'))
        .last;
    expect(skipped.level, LogLevel.info);
    expect(skipped.message, isNot(contains('44101')));
    expect(skipped.message, isNot(contains('${server.port}')));
    await adb.disconnect('uuid-C');
    expect(server.reverseRows, [
      ['8930', '44101'],
    ]);
    await a.release();
    expect(server.reverseRows, isEmpty);
    expect(
      server.deviceRequests.where((r) => r == 'reverse:killforward:tcp:8930'),
      hasLength(1),
    );
  });

  for (final shutdown in ['disconnect', 'close']) {
    for (final guestPort in [0, 8930]) {
      test(
        'late reverse bind guest=$guestPort is rolled back before $shutdown completes',
        () async {
          final server = await FakeAdbServer.bind();
          addTearDown(server.close);
          server.devices['R58M12345'] = 'device';
          server.reverseRows.add(['7000', '40009']);
          final adb = await connected(server);
          final binding = Completer<void>();
          final resume = Completer<void>();
          server.beforeReverseForward = () async {
            binding.complete();
            await resume.future;
          };
          final receipt = adb.acquireReverse(
            'uuid-1',
            localPort: 44101,
            guestPort: guestPort,
          );
          final rejected = expectLater(receipt, throwsA(isA<AppError>()));
          await binding.future;
          var finished = false;
          final closing =
              (shutdown == 'disconnect'
                      ? adb.disconnect('uuid-1')
                      : adb.close())
                  .then((_) {
                    finished = true;
                  });
          await Future<void>.delayed(Duration.zero);
          expect(
            finished,
            isFalse,
            reason: 'shutdown must drain the in-flight owner operation',
          );
          resume.complete();
          await rejected;
          await closing;
          expect(finished, isTrue);
          expect(server.reverseRows, [
            ['7000', '40009'],
          ]);
          final actual = guestPort == 0 ? 38001 : guestPort;
          expect(
            server.deviceRequests.where(
              (r) => r == 'reverse:killforward:tcp:$actual',
            ),
            hasLength(1),
          );
          expect(
            server.deviceRequests.where((r) => r.contains('killforward-all')),
            isEmpty,
          );
          expect(await adb.listDevices(serverPort: server.port), ['R58M12345']);
        },
      );
    }
  }

  test(
    'a live owner cannot borrow a reverse operation whose owner is closing',
    () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      final adb = runtime(
        processes: FakeProcessHost(),
        device: (url) {
          final row = server.forwards.singleWhere(
            (row) => row[1] == '${url.port}',
          );
          return deviceJson(uuid: row[2] == '9978' ? 'uuid-A' : 'uuid-C');
        },
      );
      addTearDown(adb.close);
      for (final port in [9978, 9990]) {
        await adb.connect(
          AndroidAdbProfile(
            mode: AndroidAdbMode.device,
            target: 'R58M12345',
            serverPort: server.port,
            gatewayPort: port,
          ),
        );
      }
      final binding = Completer<void>();
      final resume = Completer<void>();
      server.beforeReverseForward = () async {
        if (!binding.isCompleted) {
          binding.complete();
          await resume.future;
        }
      };
      final a = adb.acquireReverse('uuid-A', localPort: 44101, guestPort: 8930);
      final rejected = expectLater(a, throwsA(isA<AppError>()));
      await binding.future;
      final closing = adb.disconnect('uuid-A');
      await expectLater(
        adb.acquireReverse('uuid-C', localPort: 44101, guestPort: 8930),
        throwsA(isA<AppError>()),
      );
      resume.complete();
      await rejected;
      await closing;
      expect(server.reverseRows, isEmpty);
      final c = await adb.acquireReverse(
        'uuid-C',
        localPort: 44101,
        guestPort: 8930,
      );
      expect(c.created, isTrue);
      await c.release();
      expect(server.reverseRows, isEmpty);
    },
  );

  test('reverse drain timeout reports uncertainty instead of successful disconnect', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final verifying = Completer<void>();
    final resume = Completer<void>();
    var stalled = false;
    final adb = runtime(
      processes: FakeProcessHost(),
      commandTimeout: const Duration(milliseconds: 20),
      connectTimeout: const Duration(milliseconds: 20),
      device: (_) async {
        if (stalled) {
          verifying.complete();
          await resume.future;
        }
        return deviceJson();
      },
    );
    addTearDown(() => expectLater(adb.close(), throwsA(isA<AppError>())));
    await adb.connect(
      AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M12345',
        serverPort: server.port,
      ),
    );
    stalled = true;
    final acquiring = adb.acquireReverse(
      'uuid-1',
      localPort: 44101,
      guestPort: 8930,
    );
    final rejected = expectLater(acquiring, throwsA(isA<AppError>()));
    await verifying.future;
    await expectLater(adb.disconnect('uuid-1'), throwsA(isA<AppError>()));
    stalled = false;
    resume.complete();
    await rejected;
    expect(server.reverseRows, isEmpty);
    expect(
      server.deviceRequests.where((r) => r.startsWith('reverse:forward')),
      isEmpty,
    );
  });

  for (final shutdown in ['disconnect', 'close']) {
    test('$shutdown drains an in-flight created receipt release', () async {
      final server = await FakeAdbServer.bind();
      addTearDown(server.close);
      server.devices['R58M12345'] = 'device';
      server.reverseRows.add(['7000', '40009']);
      final adb = await connected(server);
      final receipt = await adb.acquireReverse(
        'uuid-1',
        localPort: 44101,
        guestPort: 8930,
      );
      final killing = Completer<void>();
      final resume = Completer<void>();
      server.beforeReverseKill = () async {
        killing.complete();
        await resume.future;
      };
      final releasing = receipt.release();
      await killing.future;
      var finished = false;
      final closing =
          (shutdown == 'disconnect' ? adb.disconnect('uuid-1') : adb.close())
              .then((_) {
                finished = true;
              });
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(finished, isFalse);
      resume.complete();
      await releasing;
      await closing;
      expect(server.reverseRows, [
        ['7000', '40009'],
      ]);
      expect(
        server.deviceRequests.where((r) => r == 'reverse:killforward:tcp:8930'),
        hasLength(1),
      );
    });
  }

  for (final guest in [0, 8930]) {
    test(
      'unacknowledged bind guest=$guest reports shutdown uncertainty without guessing ownership',
      () async {
        final server = await FakeAdbServer.bind();
        addTearDown(server.close);
        server.devices['R58M12345'] = 'device';
        final adb = runtime(
          processes: FakeProcessHost(),
          commandTimeout: const Duration(milliseconds: 100),
        );
        addTearDown(() => expectLater(adb.close(), throwsA(isA<AppError>())));
        await adb.connect(
          AndroidAdbProfile(
            mode: AndroidAdbMode.device,
            target: 'R58M12345',
            serverPort: server.port,
          ),
        );
        final bound = Completer<void>();
        final resume = Completer<void>();
        server.afterReverseForward = () async {
          bound.complete();
          await resume.future;
        };
        final receipt = adb.acquireReverse(
          'uuid-1',
          localPort: 44101,
          guestPort: guest,
        );
        final failed = receipt.then<AppError?>(
          (_) => null,
          onError: (Object error) => error as AppError,
        );
        await bound.future;
        final creationError = await failed;
        expect(creationError, isNotNull);
        expect(creationError!.kind, AppErrorKind.bridgeUnreachable);
        await expectLater(adb.disconnect('uuid-1'), throwsA(isA<AppError>()));
        expect(server.reverseRows, hasLength(1));
        expect(
          server.deviceRequests.where(
            (r) => r.startsWith('reverse:killforward'),
          ),
          isEmpty,
        );
        final closeError = await adb.close().then<AppError?>(
          (_) => null,
          onError: (Object error) => error as AppError,
        );
        expect(closeError, isNotNull);
        expect(closeError!.kind, AppErrorKind.bridgeUnreachable);
        expect(closeError.cause, same(creationError));
        expect(closeError.userMessage, contains('手动检查'));
        expect(closeError.toString(), isNot(contains('44101')));
        expect(closeError.toString(), isNot(contains('8930')));
        expect(closeError.toString(), isNot(contains('http')));
        await expectLater(adb.close(), throwsA(same(closeError)));
        expect(await adb.listDevices(serverPort: server.port), ['R58M12345']);
        resume.complete();
      },
    );
  }

  for (final mode in ['receipt', 'close']) {
    test(
      'missing owned cleanup acknowledgement via $mode latches a sanitized close failure',
      () async {
        final server = await FakeAdbServer.bind();
        addTearDown(server.close);
        server.devices['R58M12345'] = 'device';
        server.reverseRows.add(['7000', '40009']);
        final adb = runtime(
          processes: FakeProcessHost(),
          commandTimeout: const Duration(milliseconds: 100),
        );
        addTearDown(() => expectLater(adb.close(), throwsA(isA<AppError>())));
        await adb.connect(
          AndroidAdbProfile(
            mode: AndroidAdbMode.device,
            target: 'R58M12345',
            serverPort: server.port,
          ),
        );
        final receipt = await adb.acquireReverse(
          'uuid-1',
          localPort: 44101,
          guestPort: 8930,
        );
        final killed = Completer<void>();
        final resume = Completer<void>();
        server.afterReverseKill = () async {
          killed.complete();
          await resume.future;
        };
        final failed = (mode == 'receipt' ? receipt.release() : adb.close())
            .then<AppError?>(
              (_) => null,
              onError: (Object error) => error as AppError,
            );
        await killed.future;
        final releaseError = await failed;
        expect(releaseError, isNotNull);
        final closeError = await adb.close().then<AppError?>(
          (_) => null,
          onError: (Object error) => error as AppError,
        );
        expect(closeError, isNotNull);
        expect(closeError!.userMessage, contains('手动检查'));
        if (mode == 'receipt') {
          expect(closeError.cause, same(releaseError));
        } else {
          expect(closeError, same(releaseError));
        }
        expect(closeError.toString(), isNot(contains('8930')));
        expect(closeError.toString(), isNot(contains('44101')));
        await expectLater(adb.close(), throwsA(same(closeError)));
        await receipt.release();
        expect(server.reverseRows, [
          ['7000', '40009'],
        ]);
        expect(
          server.deviceRequests.where(
            (r) => r == 'reverse:killforward:tcp:8930',
          ),
          hasLength(1),
        );
        expect(
          server.deviceRequests.where((r) => r.contains('killforward-all')),
          isEmpty,
        );
        resume.complete();
      },
    );
  }

  test('concurrent ensureReverse calls with one guest port coalesce', () async {
    final server = await FakeAdbServer.bind();
    addTearDown(server.close);
    server.devices['R58M12345'] = 'device';
    final adb = await connected(server);

    final guests = await Future.wait([
      adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 8930),
      adb.ensureReverse('uuid-1', localPort: 44101, guestPort: 8930),
    ]);

    expect(guests, [8930, 8930]);
    expect(
      server.deviceRequests
          .where((request) => request.startsWith('reverse:forward'))
          .length,
      1,
    );
    expect(server.reverseRows, [
      ['8930', '44101'],
    ]);
  });
}
