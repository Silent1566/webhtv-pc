import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'phase5_sync_ui_test.dart' as fixture;
import 'tmdb_root_key_ingress_test.dart' as root;

class CredentialBridge extends fixture.FakeBridge {
  String candidate = root.secret;
  Completer<void>? hold;
  Completer<void>? arrived;
  @override
  Future<BridgeConversion> fetchGatewayConfig(
    String base, {
    String? selfBase,
    String? interfaceKey,
    void Function(BridgeStage)? onStage,
  }) async {
    arrived?.complete();
    await hold?.future;
    if (fetchFailure != null) throw fetchFailure!;
    return convertGatewayConfig(
      jsonText: jsonEncode({
        'tmdb_api_key': candidate,
        'sites': [
          {
            'key': 'bridge-site',
            'name': 'bridge',
            'type': 4,
            'api': '$base/vod',
          },
        ],
      }),
      reachableBase: base,
      selfBase: selfBase,
    );
  }
}

void main() {
  late Directory temp;
  late AppState state;
  late CredentialBridge bridge;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tmdb-subscription-bridge-');
    bridge = CredentialBridge();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
      log: LogService(),
      androidBridgeService: bridge,
    );
    await state.bootstrap();
  });
  tearDown(() {
    state.dispose();
    temp.deleteSync(recursive: true);
  });

  Future<int> activateImported({bool fallback = false}) async {
    bridge.hasSourceCatalog = !fallback;
    expect(
      await state.syncState.importSites(bridge.device.reachableBase),
      isTrue,
    );
    final id = state.syncState.lastImportRecordId!;
    expect(await state.activateConfigRecord(id), isTrue);
    expect(state.tmdbConfig.apiKey, '');
    return id;
  }

  for (final fallback in [false, true]) {
    test(
      'current bridge reimport accepts transient key; failed import retains it (fallback=$fallback)',
      () async {
        final id = await activateImported(fallback: fallback);
        expect(
          await state.syncState.importSites(bridge.device.reachableBase),
          isTrue,
        );
        expect(state.tmdbConfig.isReady, isTrue);
        expect(state.tmdbConfig.apiKey, root.secret);
        expect(await state.refreshConfigRecord(id), isTrue);
        expect(state.tmdbConfig.apiKey, root.secret);
        expect(
          jsonEncode(state.database!.activeConfig()!.json),
          isNot(contains(root.secret)),
        );
        expect(
          jsonEncode(await state.exportSyncedSettings(allowSensitive: true)),
          isNot(contains(root.secret)),
        );
        bridge.fetchFailure = AppError(
          AppErrorKind.bridgeUnreachable,
          'fixture failure',
        );
        expect(
          await state.syncState.importSites(bridge.device.reachableBase),
          isFalse,
        );
        expect(
          state.syncState
                  .conversionFor(bridge.device.reachableBase)
                  ?.tmdbApiKeyCandidate ??
              '',
          '',
        );
        expect(state.activeRecord!.id, id);
        expect(state.tmdbConfig.apiKey, root.secret);
      },
    );
    test(
      'late bridge response after delete cannot resurrect record or credential (fallback=$fallback)',
      () async {
        final id = await activateImported(fallback: fallback);
        bridge.arrived = Completer<void>();
        bridge.hold = Completer<void>();
        final pending = state.syncState.importSites(
          bridge.device.reachableBase,
        );
        await bridge.arrived!.future;
        await state.deleteConfigRecord(id);
        bridge.hold!.complete();
        expect(await pending, isFalse);
        final base = bridge.device.reachableBase;
        expect(
          state.syncState.conversionFor(base)?.tmdbApiKeyCandidate ?? '',
          '',
        );
        expect(
          state.syncState
                  .conversionOf(base, fallback ? '' : 'fake-source-key')
                  ?.tmdbApiKeyCandidate ??
              '',
          '',
        );
        expect(state.savedConfigs.where((record) => record.id == id), isEmpty);
        expect(state.savedConfigs, isEmpty);
        expect(state.tmdbConfig.apiKey, '');
      },
    );
  }
}
