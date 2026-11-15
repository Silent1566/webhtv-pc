import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_error.dart';
import '../core/config_loader.dart';
import 'storage.dart';

enum ConfigSourceAvailability { notLocal, available, missing, unreadable }

class ConfigSourceStatus {
  const ConfigSourceStatus({
    required this.recordId,
    required this.name,
    required this.availability,
    this.path,
  });

  final int recordId;
  final String name;
  final ConfigSourceAvailability availability;
  final String? path;

  bool get needsAttention =>
      availability == ConfigSourceAvailability.missing ||
      availability == ConfigSourceAvailability.unreadable;
}

Future<ConfigSourceStatus> inspectConfigSource(ConfigRecord record) async {
  ConfigSourceStatus status(
    ConfigSourceAvailability availability, [
    String? path,
  ]) => ConfigSourceStatus(
    recordId: record.id,
    name: record.name,
    availability: availability,
    path: path,
  );

  final ConfigSource source;
  try {
    source = ConfigSource.parse(record.origin);
  } on AppError {
    // Persisted inline/bridge identities are not importable local paths.
    return status(ConfigSourceAvailability.notLocal);
  }
  final windowsPath =
      (p.windows.isAbsolute(source.value) &&
          !p.posix.isAbsolute(source.value)) ||
      (source.value.startsWith('/') &&
          p.windows.rootPrefix(source.value.substring(1)).contains(':'));
  if (source.kind != ConfigSourceKind.file ||
      (!Platform.isWindows && windowsPath)) {
    return status(ConfigSourceAvailability.notLocal);
  }

  final file = File(source.value);
  try {
    final handle = await file.open();
    try {
      await handle.read(1);
    } finally {
      await handle.close();
    }
    return status(ConfigSourceAvailability.available, source.value);
  } on FileSystemException catch (error) {
    final code = error.osError?.errorCode;
    final missing = Platform.isWindows
        ? code == 2 || code == 3
        : code == 2 || code == 20;
    return status(
      missing
          ? ConfigSourceAvailability.missing
          : ConfigSourceAvailability.unreadable,
      source.value,
    );
  }
}
