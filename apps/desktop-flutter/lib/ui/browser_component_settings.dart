import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/sniff/browser_process.dart';
import '../core/sniff/sniff_transport.dart';
import '../core/sniff/sniff_types.dart';
import '../services/app_paths.dart';
import '../services/browser_component_store.dart';
import '../services/sniff_runtime.dart';
import 'settings_layout.dart';
import 'toast.dart';
import 'tokens.dart';

Future<BrowserComponent> _installBrowser(
  String root,
  String source,
  bool zip,
) async {
  // Store 持有函数字段，只传路径可避免把不可发送的实例带进 isolate。
  final result =
      await Isolate.run<
        ({BrowserComponent? component, String? message, String? detail})
      >(() async {
        final store = BrowserComponentStore(rootDirectory: root);
        try {
          final component = zip
              ? await store.installFromZip(File(source))
              : await store.installFromDirectory(Directory(source));
          return (component: component, message: null, detail: null);
        } on SniffException catch (error) {
          // 以数据返回错误，避免 isolate 把 message/detail 包装成 RemoteError。
          return (
            component: null,
            message: error.message,
            detail: error.detail,
          );
        } catch (error) {
          return (component: null, message: error.toString(), detail: null);
        }
      });
  if (result.component == null) {
    throw SniffException(result.message!, detail: result.detail);
  }
  return result.component!;
}

Future<String?> _browserVersion(String path) =>
    Isolate.run(() => chromiumVersionOf(path));

String _reason(Object error) {
  if (error is SniffException) {
    return [error.message, if (error.detail != null) error.detail!].join('\n');
  }
  return error.toString();
}

class BrowserComponentSettingsSection extends StatefulWidget {
  const BrowserComponentSettingsSection({
    super.key,
    required this.paths,
    this.store,
    this.transport,
    this.versionReader,
    this.onInstalled,
  });

  final AppPaths paths;
  final BrowserComponentStore? store;
  final SniffTransport? transport;
  final Future<String?> Function(String)? versionReader;
  final ValueChanged<BrowserComponent>? onInstalled;

  @override
  State<BrowserComponentSettingsSection> createState() =>
      _BrowserComponentSettingsSectionState();
}

class _BrowserComponentSettingsSectionState
    extends State<BrowserComponentSettingsSection> {
  late final _store =
      widget.store ?? BrowserComponentStore.forApp(widget.paths);
  List<BrowserComponent> _components = [];
  final Map<String, String?> _versions = {};
  final Map<String, String?> _validation = {};
  bool _loading = true;
  bool _loadedOnce = false;
  bool _busy = false;
  String? _progress;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loadedOnce) {
      _loadedOnce = true;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    try {
      final components = await _store.installed();
      if (!mounted) return;
      setState(() {
        _components = components;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _reason(error);
      });
    }
  }

  Future<void> _refreshStatus() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 真探测只由用户动作触发，首帧读取快照不会在 widget 生命周期里创建计时器。
      final status = await refreshSniffBrowserStatus(
        transport: widget.transport,
      );
      final versions = <String, String?>{};
      for (final command in status?.usables ?? <BrowserCommand>[]) {
        versions[command.executablePath] =
            await (widget.versionReader ?? _browserVersion)(
              command.executablePath,
            );
      }
      if (mounted) {
        setState(() {
          _versions.clear();
          _versions.addAll(versions);
        });
      }
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = _reason(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _browserLabel(BrowserCommand command) {
    for (final component in _components) {
      if (component.executablePath == command.executablePath) {
        return component.displayName;
      }
    }
    final version = _versions[command.executablePath];
    return version == null ? command.label : '${command.label}（$version）';
  }

  Future<void> _validate(BrowserComponent component) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final issue = await _store.validate(component);
      if (mounted) setState(() => _validation[component.id] = issue);
    } catch (error) {
      if (mounted) setState(() => _error = _reason(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall(BrowserComponent component) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('browser-component-uninstall-confirm'),
        title: const Text('卸载浏览器内核？'),
        content: Text(
          '将删除 ${component.displayName} 的组件文件，不影响来源目录。\n'
          '卸载唯一可用的内核后，Web 嗅探需要重新安装浏览器。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('browser-component-uninstall-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('browser-component-uninstall-confirm-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _store.uninstall(component);
      _validation.remove(component.id);
      await _refresh();
      if (mounted) await _refreshStatus();
    } catch (error) {
      if (mounted) setState(() => _error = _reason(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndInstall(bool zip) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String? source;
      if (zip) {
        final files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['zip'],
        );
        source = files.isEmpty ? null : files.first.path;
      } else {
        source = await FilePicker.getDirectoryPath();
      }
      if (source == null || source.isEmpty || !mounted) return;
      setState(() => _progress = zip ? '正在解压并复制浏览器文件…' : '正在复制浏览器文件…');
      final component = await _installBrowser(
        _store.rootDirectory,
        source,
        zip,
      );
      await _refresh();
      if (mounted) await _refreshStatus();
      showToast('已安装：${component.displayName}', kind: ToastKind.success);
      if (mounted) widget.onInstalled?.call(component);
    } catch (error) {
      if (mounted) setState(() => _error = _reason(error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<SniffBrowserStatus?>(
      valueListenable: sniffBrowserStatus,
      builder: (context, status, _) {
        final available = status?.hasUsable ?? false;
        return Column(
          key: const ValueKey('browser-component-section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              const Text(
                '正在读取已装组件…',
                key: ValueKey('browser-component-loading'),
              )
            else ...[
              ListTile(
                key: ValueKey(
                  status == null
                      ? 'browser-component-system-unknown'
                      : available
                      ? 'browser-component-system-available'
                      : 'browser-component-system-unavailable',
                ),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  status == null
                      ? Icons.info_outline
                      : available
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  color: status == null
                      ? theme.colorScheme.onSurfaceVariant
                      : available
                      ? context.semanticColors.statusOk
                      : theme.colorScheme.error,
                ),
                title: Text(
                  status == null
                      ? '尚未检测系统浏览器'
                      : available
                      ? '系统浏览器可用'
                      : '系统浏览器不可用',
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (status != null &&
                        status.usables.isEmpty &&
                        status.issues.isEmpty)
                      const Text('未找到 Chrome / Chromium / Edge。'),
                    for (final command in status?.usables ?? <BrowserCommand>[])
                      Text(_browserLabel(command)),
                    for (final issue in status?.issues ?? <String>[])
                      Text(issue),
                    if (!available)
                      const Text('可在下方安装便携 Chromium 内核，或安装系统浏览器后点「检测」。'),
                  ],
                ),
              ),
              if (status != null && _components.isEmpty && !available)
                const Text(
                  '需要 Chromium 内核浏览器：安装后可直接点播放，无需重启',
                  key: ValueKey('browser-component-empty'),
                ),
              const SizedBox(height: AppSpace.md),
              Text('已装组件', style: theme.textTheme.titleSmall),
              if (_components.isEmpty)
                const Text(
                  '尚未安装任何组件。',
                  key: ValueKey('browser-component-none'),
                ),
              for (final component in _components)
                Padding(
                  key: ValueKey('browser-component-row-${component.id}'),
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(component.displayName),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '来源：${component.source ?? component.directory}',
                            ),
                            if (_validation.containsKey(component.id))
                              Text(
                                _validation[component.id] ?? '可用',
                                key: ValueKey(
                                  'browser-component-validation-${component.id}',
                                ),
                                style: TextStyle(
                                  color: _validation[component.id] == null
                                      ? context.semanticColors.statusOk
                                      : theme.colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                      ),
                      SettingsActions(
                        children: [
                          TextButton(
                            key: ValueKey(
                              'browser-component-revalidate-${component.id}',
                            ),
                            onPressed: _busy
                                ? null
                                : () => _validate(component),
                            child: const Text('重新校验'),
                          ),
                          TextButton(
                            key: ValueKey(
                              'browser-component-uninstall-${component.id}',
                            ),
                            onPressed: _busy
                                ? null
                                : () => _uninstall(component),
                            child: const Text('卸载'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
            if (_progress != null) ...[
              const SizedBox(height: AppSpace.md),
              const LinearProgressIndicator(
                key: ValueKey('browser-component-progress'),
              ),
              Text(
                _progress!,
                key: const ValueKey('browser-component-progress-label'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpace.sm),
              SelectableText(
                _error!,
                key: const ValueKey('browser-component-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            SettingsActions(
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('browser-component-install-directory'),
                  onPressed: _busy ? null : () => _pickAndInstall(false),
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('安装本地目录…'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('browser-component-install-zip'),
                  onPressed: _busy ? null : () => _pickAndInstall(true),
                  icon: const Icon(Icons.folder_zip_outlined),
                  label: const Text('安装 zip…'),
                ),
                TextButton(
                  key: const ValueKey('browser-component-refresh'),
                  onPressed: _busy || _loading ? null : _refreshStatus,
                  child: Text(status == null ? '检测' : '重新检测'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

Future<bool> showBrowserComponentDialog(
  BuildContext context, {
  required AppPaths paths,
  BrowserComponentStore? store,
}) async {
  // 弹窗由用户点击打开，刷新快照不会让普通设置页首帧启动进程。
  unawaited(
    refreshSniffBrowserStatus().catchError((Object error) {
      final status = SniffBrowserStatus(usables: [], issues: [_reason(error)]);
      sniffBrowserStatus.value = status;
      return status;
    }),
  );
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('browser-component-dialog'),
          title: const Text('浏览器内核'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: BrowserComponentSettingsSection(
                paths: paths,
                store: store,
                onInstalled: (_) => Navigator.pop(context, true),
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('browser-component-dialog-close'),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('关闭'),
            ),
          ],
        ),
      ) ??
      false;
}
