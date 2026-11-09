/// 外部本地播放器（PotPlayer / VLC / mpv 等）。
///
/// 职责只有两件：**探测**本机装着哪些常见播放器，**启动**其中一个去打开一个
/// 已经解析好的媒体地址。
///
/// 不在这里做的事：
/// - 不解析站点、不碰 Header。地址由调用方给——播放器页交的是**本地代理地址**，
///   Header 注入已经在代理层完成（`proxy_server.dart`）。外部播放器拿不到
///   Cookie/Referer，所以也不能直接把站点原始地址给它；
/// - 不管代理会话生命周期。会话活多久由 `AppState` 决定，本层只负责拉起进程；
/// - 不读设置。选哪个播放器、路径存哪，都是调用方的事。
///
/// 平台：只探测 Windows。Linux/macOS 返回空表，由「手动指定」兜底——探测路径
/// 写死一整套 POSIX 发行版差异（`/usr/bin` vs `/usr/local/bin` vs `.app` 包）
/// 收益远小于成本，而手动指定一条路径就够了。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 一个可用的外部播放器。
class ExternalPlayer {
  const ExternalPlayer({required this.name, required this.executable});

  /// 显示名，用于菜单与设置页。
  final String name;

  /// 可执行文件的绝对路径。
  final String executable;

  @override
  String toString() => 'ExternalPlayer($name, $executable)';

  @override
  bool operator ==(Object other) =>
      other is ExternalPlayer &&
      other.name == name &&
      other.executable == executable;

  @override
  int get hashCode => Object.hash(name, executable);
}

/// 启动结果。
///
/// 失败必须带回原因：静默返回 `false` 会让用户点完不知道发生了什么，
/// 而这条路径的失败原因（路径失效、地址不是 http、进程起不来）各不相同，
/// 提示文案也不同。
class ExternalPlayerLaunchResult {
  const ExternalPlayerLaunchResult.success() : ok = true, error = null;

  const ExternalPlayerLaunchResult.failure(this.error) : ok = false;

  final bool ok;
  final String? error;
}

/// 外部播放器探测与启动。
abstract final class ExternalPlayers {
  /// 已知播放器：显示名 → 相对安装根目录的候选路径。
  ///
  /// 登记路径先列出，再列出默认目录；顺序即列表优先级。
  static const Map<String, List<String>> _knownPlayerPaths = {
    'PotPlayer': [
      r'DAUM\PotPlayer\PotPlayerMini64.exe',
      r'DAUM\PotPlayer\PotPlayerMini.exe',
    ],
    'VLC': [r'VideoLAN\VLC\vlc.exe'],
    'mpv': [r'mpv\mpv.exe'],
    'MPC-BE': [r'MPC-BE x64\mpc-be64.exe', r'MPC-BE\mpc-be.exe'],
    'MPC-HC': [r'MPC-HC\mpc-hc64.exe', r'MPC-HC\mpc-hc.exe'],
  };

  /// 探测本机已安装的播放器。
  ///
  /// [registeredCommands] 可注入注册表读出的命令，避免测试依赖宿主安装情况。
  static List<ExternalPlayer> detect({
    bool Function(String path)? exists,
    Map<String, String>? environment,
    String? operatingSystem,
    Map<String, List<String>>? registeredCommands,
  }) {
    final os = operatingSystem ?? Platform.operatingSystem;
    if (os != 'windows') return const [];

    final env = environment ?? Platform.environment;
    final fileExists = exists ?? _fileExists;
    final commands = registeredCommands ?? _readRegisteredCommands();
    final roots = <String>[
      ?_nonEmpty(env['ProgramFiles']),
      ?_nonEmpty(env['ProgramFiles(x86)']),
      ?_nonEmpty(env['ProgramW6432']),
      if (_nonEmpty(env['LOCALAPPDATA']) case final local?) '$local\\Programs',
    ];

    final found = <ExternalPlayer>[];
    final seen = <String>{};
    void add(String name, String? candidate) {
      if (candidate == null || !fileExists(candidate)) return;
      if (seen.add(normalizeExecutablePath(candidate))) {
        found.add(ExternalPlayer(name: name, executable: candidate));
      }
    }

    for (final entry in _knownPlayerPaths.entries) {
      for (final command in commands[entry.key] ?? const <String>[]) {
        add(entry.key, _executableFromCommand(command, env));
      }
      for (final relative in entry.value) {
        for (final root in roots) {
          add(entry.key, '$root\\$relative');
        }
      }
    }
    return found;
  }

  /// 只接受独立的绝对程序路径，不能包含命令参数或脚本。
  static bool isExecutablePath(String path) {
    final value = path.trim();
    if (value.isEmpty || value.contains(RegExp(r'["\x00-\x1f<>|?*]'))) {
      return false;
    }
    final windows =
        RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(value) || value.startsWith(r'\\');
    if (windows || Platform.isWindows) {
      return windows &&
          value.toLowerCase().endsWith('.exe') &&
          !value.substring(2).contains(':');
    }
    return value.startsWith('/') &&
        !RegExp(r'\.(bat|cmd|ps1|sh)$', caseSensitive: false).hasMatch(value);
  }

  /// Windows 路径身份只用于比较，不改变显示或启动路径。
  static String normalizeExecutablePath(String path) {
    final value = path.trim();
    if (Platform.isWindows || p.windows.isAbsolute(value)) {
      return p.windows.normalize(value).replaceAll('\\', '/').toLowerCase();
    }
    return p.posix.normalize(value);
  }

  static String? _executableFromCommand(
    String command,
    Map<String, String> environment,
  ) {
    final expanded = command.trim().replaceAllMapped(RegExp(r'%([^%]+)%'), (
      match,
    ) {
      final key = match[1]!.toLowerCase();
      for (final entry in environment.entries) {
        if (entry.key.toLowerCase() == key) return entry.value;
      }
      return match[0]!;
    });
    final match = RegExp(
      r'^(?:"([^"]+\.exe)"|([^"\r\n]+?\.exe))(?=\s|$)',
      caseSensitive: false,
    ).firstMatch(expanded);
    return match?.group(1) ?? match?.group(2);
  }

  static Map<String, List<String>> _readRegisteredCommands() {
    const appPathRoots = [
      r'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths',
      r'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths',
      r'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
    ];
    const protocols = {
      'PotPlayer': ['potplayer', 'potplayer64'],
      'VLC': ['vlc'],
      'mpv': ['mpv'],
    };
    final keys = <String, List<String>>{
      for (final entry in _knownPlayerPaths.entries)
        entry.key: [
          for (final name
              in entry.value.map((path) => path.split(r'\').last).toSet())
            for (final root in appPathRoots) '$root\\$name',
          for (final protocol in protocols[entry.key] ?? const <String>[])
            'Registry::HKEY_CLASSES_ROOT\\$protocol\\shell\\open\\command',
        ],
    };
    final script =
        '''
\$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(\$false)
\$keys = ConvertFrom-Json '${jsonEncode(keys)}'
\$result = @{}
foreach (\$player in \$keys.PSObject.Properties) {
  \$values = @()
  foreach (\$key in \$player.Value) {
    if (Test-Path -LiteralPath \$key) {
      \$value = (Get-Item -LiteralPath \$key).GetValue('')
      if (\$value -is [string]) { \$values += \$value }
    }
  }
  \$result[\$player.Name] = \$values
}
ConvertTo-Json -InputObject \$result -Compress
''';
    final encoded = base64Encode([
      for (final unit in script.codeUnits) ...[unit & 0xff, unit >> 8],
    ]);
    try {
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final result = Process.runSync(
        '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          encoded,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return const {};
      final decoded = jsonDecode((result.stdout as String).trim());
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is List)
            entry.key as String: (entry.value as List)
                .whereType<String>()
                .toList(),
      };
    } catch (_) {
      return const {};
    }
  }

  /// 启动播放器打开 [url]。
  ///
  /// 输入只接受 http(s) 媒体地址；PotPlayer 的启动参数包装为其原生协议。
  /// 本地文件路径与其他输入协议不在本能力范围内。
  static Future<ExternalPlayerLaunchResult> launch({
    required String executable,
    required String url,
    bool Function(String path)? exists,
    Future<Process> Function(String executable, List<String> arguments)?
    starter,
  }) async {
    final target = url.trim();
    final exe = executable.trim();
    if (exe.isEmpty) {
      return const ExternalPlayerLaunchResult.failure('还没有选择外部播放器');
    }
    if (!isExecutablePath(exe)) {
      return const ExternalPlayerLaunchResult.failure('播放器路径必须是独立程序文件路径');
    }
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      return const ExternalPlayerLaunchResult.failure(
        '当前地址不是 http(s)，无法交给外部播放器',
      );
    }
    final fileExists = exists ?? _fileExists;
    if (!fileExists(exe)) {
      return ExternalPlayerLaunchResult.failure('播放器文件不存在：$exe');
    }
    final fileName = exe.split(RegExp(r'[/\\]')).last.toLowerCase();
    // 与 alist-tvbox 浏览器入口一致；其他播放器仍接收普通媒体 URL。
    final argument =
        fileName == 'potplayermini64.exe' || fileName == 'potplayermini.exe'
        ? 'potplayer://$target'
        : target;
    try {
      await (starter ?? _startDetached)(exe, [argument]);
      return const ExternalPlayerLaunchResult.success();
    } catch (error) {
      return ExternalPlayerLaunchResult.failure('启动播放器失败：$error');
    }
  }

  static Future<Process> _startDetached(
    String executable,
    List<String> arguments,
  ) => Process.start(executable, arguments, mode: ProcessStartMode.detached);

  static bool _fileExists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
