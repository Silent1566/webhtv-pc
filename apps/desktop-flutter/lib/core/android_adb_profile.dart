import 'dart:convert';

import 'package:crypto/crypto.dart';

enum AndroidAdbMode { network, device, avd }

/// A persistent connection description, without local forwarding ports.
class AndroidAdbProfile {
  factory AndroidAdbProfile({
    required AndroidAdbMode mode,
    required String target,
    String adbPath = '',
    String emulatorPath = '',
    String avdHome = '',
    int serverPort = 5037,
    int gatewayPort = 9978,
  }) {
    _checkPort(serverPort);
    _checkPort(gatewayPort);
    return AndroidAdbProfile._(
      mode: mode,
      target: mode == AndroidAdbMode.network
          ? _networkTarget(target)
          : _namedTarget(target, allowSpaces: mode == AndroidAdbMode.avd),
      adbPath: _localReference(adbPath),
      emulatorPath: _localReference(emulatorPath),
      avdHome: _localReference(avdHome),
      serverPort: serverPort,
      gatewayPort: gatewayPort,
    );
  }

  const AndroidAdbProfile._({
    required this.mode,
    required this.target,
    required this.adbPath,
    required this.emulatorPath,
    required this.avdHome,
    required this.serverPort,
    required this.gatewayPort,
  });

  final AndroidAdbMode mode;
  final String target;
  final String adbPath;
  final String emulatorPath;
  final String avdHome;

  /// Borrowed ADB server port in device mode, not a device or media port.
  final int serverPort;
  final int gatewayPort;

  String get connectionKey =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();

  Map<String, Object?> toJson() => {
    'version': 1,
    'mode': mode.name,
    'target': target,
    'adbPath': adbPath,
    'emulatorPath': emulatorPath,
    'avdHome': avdHome,
    'serverPort': serverPort,
    'gatewayPort': gatewayPort,
  };

  static AndroidAdbProfile? fromJson(Object? value) {
    if (value is! Map || value['version'] != 1 || value['target'] is! String) {
      return null;
    }
    final mode = switch (value['mode']) {
      'network' => AndroidAdbMode.network,
      'device' => AndroidAdbMode.device,
      'avd' => AndroidAdbMode.avd,
      _ => null,
    };
    if (mode == null) return null;
    for (final key in ['adbPath', 'emulatorPath', 'avdHome']) {
      if (value[key] != null && value[key] is! String) return null;
    }
    for (final key in ['serverPort', 'gatewayPort']) {
      if (value[key] != null && value[key] is! int) return null;
    }
    try {
      return AndroidAdbProfile(
        mode: mode,
        target: value['target'] as String,
        adbPath: value['adbPath'] as String? ?? '',
        emulatorPath: value['emulatorPath'] as String? ?? '',
        avdHome: value['avdHome'] as String? ?? '',
        serverPort: value['serverPort'] as int? ?? 5037,
        gatewayPort: value['gatewayPort'] as int? ?? 9978,
      );
    } on FormatException {
      return null;
    }
  }

  static String _namedTarget(String value, {required bool allowSpaces}) {
    final target = value.trim();
    if (target.isEmpty ||
        target.length > 256 ||
        target.startsWith('-') ||
        _controls.hasMatch(target) ||
        target.contains('://') ||
        (!allowSpaces && RegExp(r'\s').hasMatch(target))) {
      throw const FormatException('请选择有效的 ADB 设备或 AVD 名称');
    }
    return target;
  }

  static String _networkTarget(String value) {
    final target = _namedTarget(value, allowSpaces: false);
    if (RegExp(r'[/@?#%]').hasMatch(target)) {
      throw const FormatException('ADB 地址必须是主机或主机:端口，不是 HTTP 地址');
    }
    try {
      final uri = Uri.parse('tcp://$target');
      if (!uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('无效的 ADB 网络地址');
      }
      // Uri normalizes an explicit tcp port 0 away; validate the raw suffix.
      final explicitPort = target.startsWith('[')
          ? target.contains(']:')
          : target.contains(':');
      final port = explicitPort
          ? int.tryParse(target.substring(target.lastIndexOf(':') + 1))
          : 5555;
      if (port == null) throw const FormatException('无效的 ADB 端口');
      _checkPort(port);
      return uri.replace(port: port).authority;
    } on FormatException {
      throw const FormatException('ADB 地址或端口无效');
    }
  }

  static String _localReference(String value) {
    final path = value.trim();
    if (path.length > 4096 ||
        _controls.hasMatch(path) ||
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(path)) {
      throw const FormatException('请选择本机已有的 SDK 可执行文件或目录');
    }
    return path;
  }

  static void _checkPort(int value) {
    if (value < 1 || value > 65535) {
      throw const FormatException('端口必须在 1–65535 范围内');
    }
  }

  static final _controls = RegExp(r'[\x00-\x1f\x7f]');

  @override
  String toString() => 'AndroidAdbProfile($mode)';
}
