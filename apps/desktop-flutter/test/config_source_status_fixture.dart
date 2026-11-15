import 'dart:io';

import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';

final configSourceFixtureNow = DateTime(2026, 11, 14, 12);
const configSourceFixtureJson = <String, Object?>{
  'sites': <Object?>[
    {'key': 'cached', 'name': '缓存站点', 'type': 1, 'api': 'https://fixture.test/api'},
  ],
};

class ConfigSourceFixtureState extends AppState {
  ConfigSourceFixtureState(AppPaths paths) : super(paths: paths, log: LogService());

  @override
  Future<void> loadHome(Site site) async {}

  @override
  List<ConfigRecord> get savedConfigs => super.savedConfigs.map((record) => ConfigRecord(
    id: record.id, name: record.name, origin: record.origin,
    updatedAt: configSourceFixtureNow, siteCount: record.siteCount,
    liveCount: record.liveCount, json: record.json, isActive: record.isActive,
    sourceKey: record.sourceKey, bridgeDevice: record.bridgeDevice,
    bridgeInterfaceKey: record.bridgeInterfaceKey,
    bridgeConfigUrl: record.bridgeConfigUrl,
  )).toList();
}

Future<ConfigSourceFixtureState> createConfigSourceFixture(String scenario) async {
  final root = Directory('${Platform.environment['XDG_STATE_HOME']!}/../profiles/$scenario');
  await root.create(recursive: true);
  final paths = AppPaths.resolve(overrides: {
    'config': '${root.path}/config', 'data': '${root.path}/data',
    'cache': '${root.path}/cache', 'state': '${root.path}/state',
  });
  LogService.logDirectoryOverride = paths.logDir;
  var state = ConfigSourceFixtureState(paths);
  await state.bootstrap();
  for (final record in state.database!.listConfigs()) {
    state.database!.deleteConfig(record.id);
  }
  final missing = state.database!.saveConfig(
    name: '家庭配置',
    origin: '${root.path}/sources/家庭收藏/已移走的配置文件/很长的来源目录/电视播放配置.json',
    json: configSourceFixtureJson, siteCount: 1,
  );
  state.database!.saveConfig(
    name: '家庭配置', origin: 'https://fixture.test/config.json?token=secret',
    json: configSourceFixtureJson, siteCount: 1,
  );
  final available = File('${root.path}/sources/可用配置.json');
  await available.parent.create(recursive: true);
  await available.writeAsString('{"sites":[]}');
  state.database!.saveConfig(
    name: '本地备用', origin: available.path,
    json: configSourceFixtureJson, siteCount: 1,
  );
  await state.activateConfigRecord(missing);
  state.dispose();
  state = ConfigSourceFixtureState(paths);
  await state.bootstrap();
  await File('${paths.configDir}/usage-boundary-accepted').writeAsString('fixture');
  return state;
}
