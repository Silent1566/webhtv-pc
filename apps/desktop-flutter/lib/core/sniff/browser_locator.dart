/// 定位本机已安装的 Chromium 内核浏览器（Edge/Chrome/Chromium/Brave）。
///
/// 为什么用系统浏览器而不是内嵌一份：桌面端要的是「页面真的能跑」——编解码器、
/// 证书库、站点通行状态都由用户已装的内核提供，再塞一份 CEF 只会多出上百 MB
/// 的发布体积和一份独立的安全更新责任。
///
/// 为什么定位单独成文件：定位结果（可执行路径）与启动参数、DevTools 端点发现
/// 方式强耦合，但不该进上层编排；这里只回答「本机哪个可执行文件真的能用」。
library;

import 'dart:io';

import 'sniff_transport.dart';

/// 显式指定浏览器可执行文件的环境变量（设置项与 CI 共用同一入口）。
const String sniffBrowserEnvKey = 'WEBHTV_SNIFF_BROWSER';

/// Linux PATH 上认的命令名，顺序即优先级（stable 优先于滚动版）。
const List<String> _linuxCommandNames = [
  'google-chrome-stable',
  'google-chrome',
  'chromium',
  'chromium-browser',
  'brave-browser',
  'microsoft-edge',
];

/// Linux 上不进 PATH 的常见安装位置（snap 与厂商 tar 包）。
const List<String> _linuxAbsolutePaths = [
  '/snap/bin/chromium',
  '/snap/bin/google-chrome',
  '/snap/bin/microsoft-edge',
  '/snap/bin/brave',
  '/opt/google/chrome/chrome',
  '/opt/microsoft/msedge/msedge',
  '/opt/brave.com/brave/brave',
];

/// macOS 的应用包内可执行文件。
const List<String> _macAbsolutePaths = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
];

/// Windows 里相对各安装根的浏览器可执行文件。
const List<String> _windowsRelativePaths = [
  r'Microsoft\Edge\Application\msedge.exe',
  r'Google\Chrome\Application\chrome.exe',
  r'Chromium\Application\chrome.exe',
];

/// 只解析显式指定的浏览器（参数 override 或 `WEBHTV_SNIFF_BROWSER`）。
///
/// 与 [locateBrowser] 的差别：找不到时返回 null，**不回落**到平台候选——组合
/// 排序需要单独知道「用户显式指定了哪个」，才能把它排在已安装组件之前。
Future<BrowserCommand?> locateExplicitBrowser({
  String? override,
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  for (final explicit in [override, env[sniffBrowserEnvKey]]) {
    final command = _resolve(explicit, env);
    if (command != null) return command;
  }
  return null;
}

/// 按优先级列出本机全部可用候选（去重）。
///
/// 与 [locateBrowser] 的差别：这里不提前替上层挑一个，而是把候选交给嗅探引擎
/// 逐个探测/启动——「存在且可执行」不等于「真的能跑」（snap 包装脚本、
/// 坏软链、架构不匹配的内核都会在这里被下一个候选接住）。
Future<List<BrowserCommand>> locateBrowsers({
  String? override,
  Map<String, String>? environment,
  List<String>? candidates,
}) async {
  final env = environment ?? Platform.environment;
  final seen = <String>{};
  final result = <BrowserCommand>[];
  for (final explicit in [override, env[sniffBrowserEnvKey]]) {
    final command = _resolve(explicit, env);
    if (command != null && seen.add(command.executablePath)) result.add(command);
  }
  for (final candidate in candidates ?? _platformCandidates(env)) {
    final command = _resolve(candidate, env);
    if (command != null && seen.add(command.executablePath)) result.add(command);
  }
  return result;
}

/// 找到本机可用的浏览器；找不到返回 `null`（能力缺失，不是异常）。
///
/// 优先级：`override` → [sniffBrowserEnvKey] → 平台候选路径。显式指定但不可用时
/// 继续往下找——一个失效的环境变量不该把整机可用的浏览器藏起来。
///
/// [environment] 与 [candidates] 只为测试注入：生产调用不传，走 `Platform.environment`
/// 与平台候选表，测试不必依赖本机装了什么。
Future<BrowserCommand?> locateBrowser({
  String? override,
  Map<String, String>? environment,
  List<String>? candidates,
}) async {
  final env = environment ?? Platform.environment;
  for (final explicit in [override, env[sniffBrowserEnvKey]]) {
    final command = _resolve(explicit, env);
    if (command != null) return command;
  }
  for (final candidate in candidates ?? _platformCandidates(env)) {
    final command = _resolve(candidate, env);
    if (command != null) return command;
  }
  return null;
}

/// 可执行文件的人类可读名称（诊断与日志用）。
String browserLabel(String executablePath) {
  final lower = executablePath.toLowerCase();
  if (lower.contains('chromium')) return 'Chromium';
  if (lower.contains('brave')) return 'Brave Browser';
  if (lower.contains('msedge') || lower.contains('microsoft edge')) {
    return 'Microsoft Edge';
  }
  if (lower.contains('chrome')) return 'Google Chrome';
  return executablePath.split(RegExp(r'[\\/]')).last;
}

List<String> _platformCandidates(Map<String, String> env) {
  if (Platform.isWindows) return _windowsCandidates(env);
  if (Platform.isMacOS) return _macAbsolutePaths;
  return [..._linuxCommandNames, ..._linuxAbsolutePaths];
}

List<String> _windowsCandidates(Map<String, String> env) {
  final roots = <String>[];
  for (final key in [
    'ProgramFiles(x86)',
    'ProgramFiles',
    'LOCALAPPDATA',
  ]) {
    final value = env[key];
    if (value != null && value.trim().isNotEmpty) roots.add(value.trim());
  }
  return [
    for (final root in roots)
      for (final relative in _windowsRelativePaths) '$root\\$relative',
  ];
}

/// 把一条候选（裸命令名、绝对路径、带 `~` 或 `%VAR%` 的路径）解析成可用命令。
BrowserCommand? _resolve(String? raw, Map<String, String> env) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final expanded = _expand(trimmed, env);
  final paths = _isPathLike(expanded) ? [expanded] : _which(expanded, env);
  for (final path in paths) {
    if (_isRunnable(path)) {
      return BrowserCommand(executablePath: path, label: browserLabel(path));
    }
  }
  return null;
}

/// 展开 `~`、`$VAR` 与 `%VAR%`（Windows 环境变量块常见 `%ProgramFiles%` 写法）。
String _expand(String raw, Map<String, String> env) {
  var value = raw;
  if (value.isNotEmpty &&
      value[0] == '~' &&
      (value.length == 1 || value[1] == '/' || value[1] == '\\')) {
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home != null && home.isNotEmpty) value = '$home${value.substring(1)}';
  }
  value = value.replaceAllMapped(
    RegExp(r'%([^%]+)%'),
    (match) => env[match[1]!] ?? match[0]!,
  );
  value = value.replaceAllMapped(
    RegExp(r'\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*)'),
    (match) => env[match[1] ?? match[2]!] ?? match[0]!,
  );
  return value;
}

bool _isPathLike(String value) =>
    value.contains('/') || value.contains('\\');

List<String> _which(String name, Map<String, String> env) {
  final pathValue = env['PATH'];
  if (pathValue == null || pathValue.isEmpty) return const [];
  final separator = Platform.isWindows ? ';' : ':';
  final result = <String>[];
  for (final entry in pathValue.split(separator)) {
    final dir = entry.trim();
    if (dir.isEmpty) continue;
    result.add('$dir${Platform.pathSeparator}$name');
    if (Platform.isWindows && !name.toLowerCase().endsWith('.exe')) {
      result.add('$dir\\$name.exe');
    }
  }
  return result;
}

/// 存在且可执行才算找到：PATH 上残留的坏软链、只读占位文件都不能当浏览器。
bool _isRunnable(String path) {
  FileStat stat;
  try {
    stat = FileStat.statSync(path);
  } on FileSystemException {
    return false;
  }
  if (stat.type != FileSystemEntityType.file) return false;
  // Windows 的 mode 位没有可执行语义，存在即可（扩展名已由候选表约束）。
  if (Platform.isWindows) return true;
  return stat.mode & 0x49 != 0;
}
