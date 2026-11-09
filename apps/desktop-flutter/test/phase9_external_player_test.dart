import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/external_player.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-phase9-external');
    settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, Object?> readRaw() {
    final file = File(settingsPath);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  group('探测（ExternalPlayers.detect）', () {
    test('非 Windows 一律返回空表', () {
      final found = ExternalPlayers.detect(
        registeredCommands: const {},
        operatingSystem: 'linux',
        environment: const {'ProgramFiles': r'C:\Program Files'},
        exists: (_) => true,
      );
      expect(found, isEmpty, reason: 'POSIX 发行版差异不做探测，交给手动指定');
    });

    test('按安装根目录找到播放器，顺序即优先级', () {
      const env = {
        'ProgramFiles': r'C:\Program Files',
        'ProgramFiles(x86)': r'C:\Program Files (x86)',
      };
      final found = ExternalPlayers.detect(
        registeredCommands: const {},
        operatingSystem: 'windows',
        environment: env,
        exists: (path) =>
            path == r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe' ||
            path == r'C:\Program Files\VideoLAN\VLC\vlc.exe',
      );
      expect(found.map((p) => p.name).toList(), ['PotPlayer', 'VLC']);
      expect(
        found.first.executable,
        r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
      );
    });

    test('32 位程序目录也是合法安装位置', () {
      final found = ExternalPlayers.detect(
        registeredCommands: const {},
        operatingSystem: 'windows',
        environment: const {
          'ProgramFiles': r'C:\Program Files',
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
        },
        exists: (path) =>
            path == r'C:\Program Files (x86)\VideoLAN\VLC\vlc.exe',
      );
      expect(found.single.name, 'VLC');
    });

    test('用户级安装目录（%LOCALAPPDATA%\\Programs）也被覆盖', () {
      final found = ExternalPlayers.detect(
        registeredCommands: const {},
        operatingSystem: 'windows',
        environment: const {
          'ProgramFiles': r'C:\Program Files',
          'LOCALAPPDATA': r'C:\Users\someone\AppData\Local',
        },
        exists: (path) =>
            path == r'C:\Users\someone\AppData\Local\Programs\mpv\mpv.exe',
      );
      expect(found.single.name, 'mpv');
    });

    test('PotPlayer 64 位缺失时回落到 32 位可执行文件', () {
      final found = ExternalPlayers.detect(
        registeredCommands: const {},
        operatingSystem: 'windows',
        environment: const {'ProgramFiles': r'C:\Program Files'},
        exists: (path) =>
            path == r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini.exe',
      );
      expect(found.single.executable, endsWith('PotPlayerMini.exe'));
    });

    test('同一 exe 被多个相同根目录命中时只出现一次', () {
      final found = ExternalPlayers.detect(
        registeredCommands: const {},
        operatingSystem: 'windows',
        environment: const {
          'ProgramFiles': r'C:\Program Files',
          'ProgramW6432': r'C:\Program Files',
        },
        exists: (path) => path == r'C:\Program Files\VideoLAN\VLC\vlc.exe',
      );
      expect(found.length, 1);
    });

    test('三个根目录都缺席时返回空表而不是瞎猜', () {
      final found = ExternalPlayers.detect(
        registeredCommands: const {},
        operatingSystem: 'windows',
        environment: const {},
        exists: (_) => true,
      );
      expect(found, isEmpty);
    });
  });

  group('注册表检测回归', () {
    test('失效 App Paths 后继续查浏览器协议的带空格路径', () {
      final found = ExternalPlayers.detect(
        operatingSystem: 'windows',
        environment: const {'ProgramFiles': r'C:\Program Files'},
        registeredCommands: const {
          'PotPlayer': [
            '"G:\\PotPlayer\\PotPlayerMini64.exe" ',
            r'G:\Pure Codec\x64\PotPlayerMini64.exe "%1"',
          ],
        },
        exists: (path) => path == r'G:\Pure Codec\x64\PotPlayerMini64.exe',
      );
      expect(found.single.name, 'PotPlayer');
      expect(found.single.executable, r'G:\Pure Codec\x64\PotPlayerMini64.exe');
    });

    test('带引号的 App Paths 允许非默认安装盘', () {
      final found = ExternalPlayers.detect(
        operatingSystem: 'windows',
        environment: const {},
        registeredCommands: const {
          'PotPlayer': [r'"D:\Media Apps\PotPlayerMini64.exe"'],
        },
        exists: (path) => path == r'D:\Media Apps\PotPlayerMini64.exe',
      );
      expect(found.single.executable, r'D:\Media Apps\PotPlayerMini64.exe');
    });

    test('协议命令剥离参数并展开环境变量', () {
      final found = ExternalPlayers.detect(
        operatingSystem: 'windows',
        environment: const {'LOCALAPPDATA': r'D:\User Apps'},
        registeredCommands: const {
          'PotPlayer': [r'"%localappdata%\PotPlayer\Player.exe" "%1"'],
        },
        exists: (path) => path == r'D:\User Apps\PotPlayer\Player.exe',
      );
      expect(found.single.executable, r'D:\User Apps\PotPlayer\Player.exe');
    });

    test('注册路径和不同的默认安装路径全部保留', () {
      final found = ExternalPlayers.detect(
        operatingSystem: 'windows',
        environment: const {'ProgramFiles': r'C:\Program Files'},
        registeredCommands: const {
          'PotPlayer': [r'"D:\PotPlayer\PotPlayerMini64.exe" "%1"'],
        },
        exists: (path) =>
            path == r'D:\PotPlayer\PotPlayerMini64.exe' ||
            path == r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
      );
      expect(found.map((p) => p.executable).toList(), [
        r'D:\PotPlayer\PotPlayerMini64.exe',
        r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
      ]);
    });

    test('同族多登记、多目录及等价路径去重，基础名称不带编号', () {
      final found = ExternalPlayers.detect(
        operatingSystem: 'windows',
        environment: const {'ProgramFiles': r'C:\Program Files'},
        registeredCommands: const {
          'PotPlayer': [
            r'"D:\Portable\PotPlayerMini64.exe" "%1"',
            r'"d:/portable/POTPLAYERMINI64.EXE"',
            r'"D:\Portable\inner\..\PotPlayerMini64.exe"',
            r'"E:\Portable\PotPlayerMini.exe"',
          ],
        },
        exists: (_) => true,
      );
      expect(
        found.where((p) => p.name == 'PotPlayer').map((p) => p.executable),
        [
          r'D:\Portable\PotPlayerMini64.exe',
          r'E:\Portable\PotPlayerMini.exe',
          r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
          r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini.exe',
        ],
      );
      expect(found.map((p) => p.name).toSet(), {
        'PotPlayer',
        'VLC',
        'mpv',
        'MPC-BE',
        'MPC-HC',
      });
    });

    test('所有注册项失效时回落到默认目录', () {
      final found = ExternalPlayers.detect(
        operatingSystem: 'windows',
        environment: const {'ProgramFiles': r'C:\Program Files'},
        registeredCommands: const {
          'PotPlayer': [r'"D:\Removed\PotPlayerMini64.exe" "%1"'],
        },
        exists: (path) =>
            path == r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
      );
      expect(
        found.single.executable,
        r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
      );
    });

    test('没有可执行文件路径的协议命令不被当作播放器', () {
      final found = ExternalPlayers.detect(
        operatingSystem: 'windows',
        environment: const {},
        registeredCommands: const {
          'PotPlayer': ['potplayer://%1', '"D:\\Broken\\Player.exe'],
        },
        exists: (_) => true,
      );
      expect(found, isEmpty);
    });
  });

  group('启动（ExternalPlayers.launch）', () {
    test('未配置播放器时拒绝并说明原因', () async {
      final result = await ExternalPlayers.launch(
        executable: '  ',
        url: 'http://a/1.m3u8',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('还没有选择外部播放器'));
    });

    test('独立程序路径之外的旧配置不允许启动脚本或带参数命令', () async {
      for (final path in [
        r'D:\Players\run.cmd',
        r'"D:\Players\player.exe" --arg',
        'player.exe',
      ]) {
        var started = false;
        final result = await ExternalPlayers.launch(
          executable: path,
          url: 'http://127.0.0.1:9/media',
          exists: (_) => true,
          starter: (_, _) async {
            started = true;
            return _FakeProcess();
          },
        );
        expect(result.ok, isFalse, reason: path);
        expect(started, isFalse);
      }
    });

    test('非 http(s) 地址拒绝交给外部进程', () async {
      final result = await ExternalPlayers.launch(
        executable: r'D:\PotPlayer\PotPlayerMini64.exe',
        url: r'D:\movie.mkv',
        exists: (_) => true,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('http(s)'));
    });

    test('可执行文件不存在时拒绝，且不启动进程', () async {
      var started = false;
      final result = await ExternalPlayers.launch(
        executable: r'D:\gone\Player.exe',
        url: 'http://127.0.0.1:9/p/token/abc',
        exists: (path) => false,
        starter: (_, _) async {
          started = true;
          throw UnimplementedError('不该被调用');
        },
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('播放器文件不存在'));
      expect(started, isFalse);
    });

    test('改成任意显示名的 PotPlayer 仍按文件名使用唯一协议参数', () async {
      const renamed = ExternalPlayer(
        name: '自定义名称 VLC',
        executable: r'D:\PotPlayer\PotPlayerMini64.exe',
      );
      String? usedExe;
      List<String>? usedArgs;
      final result = await ExternalPlayers.launch(
        executable: renamed.executable,
        url: 'http://127.0.0.1:51234/p/token/YWJj',
        exists: (_) => true,
        starter: (executable, arguments) async {
          usedExe = executable;
          usedArgs = arguments;
          return _FakeProcess();
        },
      );
      expect(result.ok, isTrue);
      expect(usedExe, r'D:\PotPlayer\PotPlayerMini64.exe');
      expect(usedArgs, ['potplayer://http://127.0.0.1:51234/p/token/YWJj']);
    });

    test('32 位 PotPlayer 路径大小写不同仍使用协议调用', () async {
      List<String>? usedArgs;
      final result = await ExternalPlayers.launch(
        executable: r'D:\播放器\POTPLAYERMINI.EXE',
        url: 'http://media.example/p/token/1@16514?name=a%20b.mp4',
        exists: (_) => true,
        starter: (_, arguments) async {
          usedArgs = arguments;
          return _FakeProcess();
        },
      );
      expect(result.ok, isTrue);
      expect(usedArgs, [
        'potplayer://http://media.example/p/token/1@16514?name=a%20b.mp4',
      ]);
    });

    test('mpv 继续接收原始媒体 URL 而不是 PotPlayer 协议', () async {
      List<String>? usedArgs;
      final result = await ExternalPlayers.launch(
        executable: r'D:\mpv\mpv.exe',
        url: 'http://127.0.0.1:51234/p/token/YWJj',
        exists: (_) => true,
        starter: (_, arguments) async {
          usedArgs = arguments;
          return _FakeProcess();
        },
      );
      expect(result.ok, isTrue);
      expect(usedArgs, ['http://127.0.0.1:51234/p/token/YWJj']);
    });

    test('启动抛错时把原因带回，不吞掉', () async {
      final result = await ExternalPlayers.launch(
        executable: r'D:\PotPlayer\PotPlayerMini64.exe',
        url: 'https://cdn.example.com/a.m3u8',
        exists: (_) => true,
        starter: (_, _) async => throw const ProcessException('x', ['y']),
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('启动播放器失败'));
    });

    test('地址前后空白不影响启动', () async {
      List<String>? usedArgs;
      final result = await ExternalPlayers.launch(
        executable: r'D:\VLC\vlc.exe',
        url: '  https://cdn.example.com/a.m3u8  ',
        exists: (_) => true,
        starter: (_, arguments) async {
          usedArgs = arguments;
          return _FakeProcess();
        },
      );
      expect(result.ok, isTrue);
      expect(usedArgs, ['https://cdn.example.com/a.m3u8']);
    });
  });

  group('持久化（ui 段）', () {
    test('从未设置过时缺席，不写盘', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.externalPlayerPath, isNull);
      await store.rememberSite('muou');
      final ui = (readRaw()['ui'] as Map?) ?? const {};
      expect(
        ui.containsKey('externalPlayerPath'),
        isFalse,
        reason: '缺席 = 未配置，不得固化进文件',
      );
    });

    test('写入后能原样读回', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberExternalPlayerPath(
        r'D:\PotPlayer\PotPlayerMini64.exe',
      );

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.externalPlayerPath, r'D:\PotPlayer\PotPlayerMini64.exe');
    });

    test('传空串等于清除配置', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberExternalPlayerPath(r'D:\VLC\vlc.exe');
      await store.rememberExternalPlayerPath('   ');

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.externalPlayerPath, isNull);
      final ui = (readRaw()['ui'] as Map?) ?? const {};
      expect(ui.containsKey('externalPlayerPath'), isFalse);
    });

    test('非字符串 / 空值不污染状态', () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'ui': {'externalPlayerPath': 42},
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.externalPlayerPath, isNull);
    });
  });
}

/// `Process.start` 的替身：`launch` 只关心「有没有成功拉起」，不碰它的流。
class _FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
