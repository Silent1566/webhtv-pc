/// 手动截图工具：「软件更新」明细页的 PNG 证据（ADR-0015）。
///
/// 用法（在 apps/desktop-flutter 下）：
///   ../../.tools/flutter/bin/flutter test tool/app_update_capture_test.dart \
///     --dart-define=APP_TAG=v0.1.0-202611231630
/// 输出：<仓库根>/.local/update-md-visual/after/update-<亮度>-<宽>x<高>.png
///
/// 为什么带 APP_TAG：它是编译期注入的构建身份，缺省为空 = 开发构建，而开发
/// 构建永远不会得到「发现新版本」这个结论。截图要拍的是**发布构建看到新版本**
/// 的真实形态，于是这份身份必须和假服务返回的结论一致。
///
/// 四张都拍到「有新版本结果」的状态（版本说明 + 发布说明 + 可点的下载并安装），
/// 覆盖暗/亮 x 480x640 / 1440x900。数据由本地假服务直接给出，本工具零网络、
/// 零进程（安装不在截图范围内）。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_update.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/app_update_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app_update_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

const _captureKey = ValueKey('update-capture-root');
const _cjkFontEnv = 'CAPTURE_CJK_FONT';
const _defaultCjkFont =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
const _materialFonts =
    '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';

const String _tag = 'v0.1.0-202611240900';
const int _assetSize = 4 * 1024 * 1024;

const List<({String name, Brightness brightness, Size size})> _scenarios = [
  (name: 'update', brightness: Brightness.dark, size: Size(480, 640)),
  (name: 'update', brightness: Brightness.light, size: Size(480, 640)),
  (name: 'update', brightness: Brightness.dark, size: Size(1440, 900)),
  (name: 'update', brightness: Brightness.light, size: Size(1440, 900)),
  (name: 'cached-error', brightness: Brightness.dark, size: Size(480, 640)),
];

Directory _repoRoot() {
  var directory = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    if (File('${directory.path}/apps/desktop-flutter/pubspec.yaml')
        .existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('无法定位仓库根目录');
}

AppReleaseAsset _asset(String name) => AppReleaseAsset(
  name: name,
  size: _assetSize,
  downloadUri: Uri.parse('https://downloads.test/$name'),
  sha256: 'a' * 64,
);

AppRelease _release() => AppRelease(
  tag: _tag,
  title: _tag,
  body: [
    '## 本次更新',
    '',
    '- 修复窄窗下设置页分类条换行后被裁切的问题；',
    '- 修复切换播放源后备选线路仍指向旧站点的问题；',
    '- 播放器按钮排版支持把「下一集」移到最左；',
    '- 追剧日历在跨月时按本地时区归集。',
    '',
    '## 已知问题',
    '',
    '- Windows 便携包更新后需要重启一次才会出现在开始菜单；',
    '- deb 发行形态仍需系统安装器完成安装（应用不会自动提权）。',
  ].join('\n'),
  pageUri: Uri.parse(
    'https://github.com/Silent1566/webhtv-pc/releases/tag/$_tag',
  ),
  publishedAt: DateTime.utc(2026, 11, 24, 1, 30),
  prerelease: false,
  draft: false,
  assets: [
    _asset('webhtv-pc-windows-x64.zip'),
    _asset('webhtv-pc-linux-x64.AppImage'),
    _asset('webhtv-pc-linux-x64.deb'),
    _asset('webhtv-pc-macos-arm64.zip'),
  ],
  tagInfo: AppReleaseTag.tryParse(_tag),
);

/// 只回答 check：截图不下载、不安装，因此另外两个方法不会被调用。
class _CaptureUpdateService extends AppUpdateService {
  _CaptureUpdateService(this.result);

  final AppUpdateCheck result;

  @override
  Future<AppUpdateCheck> check({
    required AppUpdateIdentity identity,
    required AppUpdateChannel channel,
  }) async => result;

  @override
  Future<AppUpdateDownload> download(
    AppRelease release,
    AppReleaseAsset asset, {
    required Directory destination,
    void Function(int received, int? total)? onProgress,
  }) async => throw StateError('截图不得下载');

  @override
  Future<AppUpdateInstallResult> install(
    AppUpdateDownload download, {
    required AppUpdateInstallEnvironment environment,
  }) async => throw StateError('截图不得安装');
}

Future<void> _loadFonts() async {
  final cjk = File(Platform.environment[_cjkFontEnv] ?? _defaultCjkFont);
  if (!cjk.existsSync()) {
    throw StateError('缺少中文字体 ${cjk.path}；可用 $_cjkFontEnv 指定 TTC/OTF 路径');
  }
  final bytes = cjk.readAsBytesSync();
  if (bytes.isEmpty) throw StateError('中文字体为空：${cjk.path}');
  for (final family in const [
    'CaptureSans',
    'Roboto',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'Segoe UI',
  ]) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
  final icons = File('${_repoRoot().path}/$_materialFonts');
  if (!icons.existsSync()) throw StateError('缺少 Material 图标字体：${icons.path}');
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(icons.readAsBytesSync().buffer)));
  await iconLoader.load();
}

ThemeData _captureTheme(Brightness brightness) {
  final base = buildAppTheme(brightness);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'CaptureSans'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'CaptureSans'),
  );
}

/// 捕获边界必须在 MaterialApp 之上：包在 home 里只拍得到当前页。
Widget _captureRoot(Brightness brightness, AppState state) => RepaintBoundary(
  key: _captureKey,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _captureTheme(brightness),
    home: AppUpdatePage(state: state),
  ),
);

Future<void> _writePng(WidgetTester tester, File target) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      target.writeAsBytesSync(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
  expect(target.lengthSync(), greaterThan(1024), reason: '截图疑似空白：$target');
}

class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _OfflineHttpClient();
}

class _OfflineHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter || invocation.memberName == #close) return null;
    throw StateError('截图禁止网络访问：${invocation.memberName}');
  }
}

void main() {
  final output = Directory('${_repoRoot().path}/.local/update-md-visual/after');
  final previousHttpOverrides = HttpOverrides.current;

  setUpAll(() async {
    HttpOverrides.global = _OfflineHttpOverrides();
    output.createSync(recursive: true);
    await _loadFonts();
  });

  tearDownAll(() {
    HttpOverrides.global = previousHttpOverrides;
  });

  for (final scenario in _scenarios) {
    final file =
        '${scenario.name}-${scenario.brightness.name}-'
        '${scenario.size.width.toInt()}x${scenario.size.height.toInt()}';
    testWidgets('capture $file', (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'webhtv-update-capture-',
      );
      final previousLogDirectory = LogService.logDirectoryOverride;
      addTearDown(() {
        LogService.logDirectoryOverride = previousLogDirectory;
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      );
      LogService.logDirectoryOverride = paths.logDir;
      final service = _CaptureUpdateService(
        AppUpdateCheck(
          verdict: scenario.name == 'cached-error'
              ? AppUpdateVerdict.failed
              : AppUpdateVerdict.updateAvailable,
          fromCache: scenario.name == 'cached-error',
          cachedAt: scenario.name == 'cached-error'
              ? DateTime.utc(2026, 11, 22, 2)
              : null,
          retryAt: scenario.name == 'cached-error'
              ? DateTime.utc(2026, 11, 24, 3)
              : null,
          source: '静态索引',
          message: scenario.name == 'cached-error'
              ? '静态索引连接超时，备用代理也暂时无法连接；GitHub API 请求限流。'
                    '当前仅显示两天前保存的历史缓存，尚未确认最新版本，不能下载或安装；'
                    '请稍后检查，或打开 Release 页面手动查看。'
              : null,
          identity: const AppUpdateIdentity(
            version: '0.1.0',
            tag: 'v0.1.0-202611231630',
          ),
          checkedAt: DateTime.utc(2026, 11, 24, 2),
          release: _release(),
        ),
      );
      final state = AppState(
        paths: paths,
        log: LogService(),
        externalPlayerDetector: () => const [],
        updateService: service,
      );
      addTearDown(state.dispose);
      await tester.runAsync(state.bootstrap);
      // 页面本身不联网：先让状态里已经有「发现新版本」的结果，再挂页面。
      await tester.runAsync(state.checkForUpdates);
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_captureRoot(scenario.brightness, state));
      await tester.pumpAndSettle();
      expect(find.byType(ErrorWidget), findsNothing);
      expect(tester.takeException(), isNull, reason: '渲染异常（含布局溢出）时不出图');
      await _writePng(tester, File('${output.path}/$file.png'));
      final pageScroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      pageScroll.jumpTo(pageScroll.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('settings-update-proxy-url')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _writePng(tester, File('${output.path}/$file-proxy.png'));
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-update-notes-expand')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await _writePng(tester, File('${output.path}/$file-notes.png'));
      await tester.tap(
        find.byKey(const ValueKey('settings-update-notes-expand')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _writePng(tester, File('${output.path}/$file-full-notes.png'));
    });
  }
}
