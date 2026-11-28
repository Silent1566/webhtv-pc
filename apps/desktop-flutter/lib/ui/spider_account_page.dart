/// 手动网盘账号（夸克 / 百度）配置页。
///
/// 为什么是独立页面而不是只有一个输入框：安卓端 PanConfig 的「手动/清除」动作条目
/// 直接弹输入框，但桌面上这个值**是应用级共享的**——保存或清除都会改变所有兼容
/// 站源读到的 Cookie。所以先在一页里给出当前状态、影响范围，再进输入框确认；
/// 清除还单独要一次自己的确认。说明和动作在同一页，用户在选择之前就看完后果。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/spider_account.dart';
import '../services/spider_account_store.dart';
import '../state/app_state.dart';
import 'glass_dialog.dart';
import 'settings_layout.dart';
import 'tokens.dart';

/// 一个已通过核心校验的账号动作对应的配置页。
///
/// 不接收 provider 键名或任意偏好键：可写范围完全由 [SpiderAccountAction] 决定。
class SpiderAccountPage extends StatefulWidget {
  const SpiderAccountPage({
    super.key,
    required this.state,
    required this.action,
  });

  final AppState state;
  final SpiderAccountAction action;

  @override
  State<SpiderAccountPage> createState() => _SpiderAccountPageState();
}

class _SpiderAccountPageState extends State<SpiderAccountPage> {
  bool _reading = true;
  bool _configured = false;
  bool _statusFailed = false;
  bool _busy = false;
  String? _notice;
  int _statusGeneration = 0;

  SpiderAccountProvider get _provider => widget.action.provider;

  bool get _clearEntry =>
      widget.action.operation == SpiderAccountOperation.clear;

  @override
  void initState() {
    super.initState();
    _readStatus();
  }

  /// 只读状态，不打印值：页面上永远只有「已配置 / 未配置」。
  Future<void> _readStatus() async {
    final generation = ++_statusGeneration;
    try {
      final value = await widget.state.spiderAccounts.read(_provider);
      if (!mounted || generation != _statusGeneration) return;
      setState(() {
        _reading = false;
        _statusFailed = false;
        _configured = value != null && value.isNotEmpty;
      });
    } catch (_) {
      if (!mounted || generation != _statusGeneration) return;
      setState(() {
        _reading = false;
        _statusFailed = true;
      });
    }
  }

  /// 输入框自己的校验：先给即时反馈，真实边界仍以 store 为准。
  String? _validate(String raw) {
    var value = raw.trim();
    const prefix = 'cookie:';
    if (value.toLowerCase().startsWith(prefix)) {
      value = value.substring(prefix.length).trim();
    }
    if (value.isEmpty) return '内容为空：请填写 Cookie，或改用「清除账号」';
    if (value.contains('\r') || value.contains('\n')) {
      return '内容不能包含换行：请把 Cookie 放在同一行';
    }
    if (utf8.encode(value).length > SpiderAccountStore.maxValueBytes) {
      return '内容超过 ${SpiderAccountStore.maxValueBytes} 字节上限';
    }
    return null;
  }

  /// 返回给输入框的错误文案：只描述原因，绝不回显输入或底层异常文本。
  Future<String?> _saveValue(String value) async {
    final error = _validate(value);
    if (error != null) return error;
    try {
      await widget.state.spiderAccounts.save(_provider, value);
      return null;
    } on SpiderAccountStoreException catch (error) {
      return '保存失败：${error.message}';
    } catch (_) {
      return '保存失败，请稍后重试（已保存的内容没有被改动）';
    }
  }

  Future<void> _openEditor() async {
    if (_busy) return;
    final saved = await showGlassDialog<bool>(
      context: context,
      builder: (_) => _SecretDialog(provider: _provider, save: _saveValue),
    );
    // 取消/返回：不写、不刷新、不离开。
    if (!mounted || saved != true) return;
    await _afterWrite(staleNotice: '保存成功，刷新未完成：账号已写入，列表可能仍显示旧状态；返回后可手动刷新。');
  }

  Future<void> _clear() async {
    if (_busy) return;
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (_) => _ClearConfirmDialog(provider: _provider),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    String? error;
    try {
      await widget.state.spiderAccounts.clear(_provider);
    } catch (_) {
      error = '清除失败，请稍后重试（已有内容没有被改动）';
    }
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _notice = error;
      });
      return;
    }
    await _afterWrite(staleNotice: '清除成功，刷新未完成：账号已更新，列表可能仍显示旧状态；返回后可手动刷新。');
  }

  /// 写成功之后：刷新选中分类（配置与站点保持不变），成功就返回；刷新失败只提示，
  /// 已经写进去的值不回滚。
  Future<void> _afterWrite({required String staleNotice}) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    var refreshed = true;
    try {
      await widget.state.refreshSpiderAccountCategory();
    } catch (_) {
      refreshed = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _readStatus();
    if (!mounted) return;
    if (refreshed) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _notice = staleNotice);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.extension<AppSemanticColors>();
    final edit = FilledButton.icon(
      key: const ValueKey('spider-account-edit'),
      onPressed: _busy ? null : _openEditor,
      icon: const Icon(Icons.vpn_key_outlined),
      label: const Text('编辑 Cookie'),
    );
    final clear = OutlinedButton.icon(
      key: const ValueKey('spider-account-clear'),
      onPressed: _busy ? null : _clear,
      icon: const Icon(Icons.delete_outline),
      label: const Text('清除账号'),
    );
    return SettingsDetailScaffold(
      title: '${_provider.label}账号',
      description: _clearEntry
          ? '清除应用级保存的${_provider.label} Cookie。清除不会碰站源自己的其它设置。'
          : '手动填写${_provider.label} Cookie。它由应用统一保存，不是某一个站源的私有配置。',
      children: [
        if (widget.action.scanOnly) ...[
          _ScanOnlyNotice(provider: _provider),
          const SizedBox(height: AppSpace.xl),
        ],
        SettingsSection(title: '当前状态', children: [_statusRow(theme, semantic)]),
        SettingsSection(
          title: '影响范围',
          description:
              '保存后，所有使用 ${_provider.preferenceKey} 的兼容站源都会读取这份 Cookie，'
              '站源各自保存的同名值不再单独生效；其它偏好键、站点选择与本地编辑的配置不变。'
              '清除写入的是空值，兼容站源不会再回退到旧 Cookie。',
          children: [
            Text(
              'Cookie 只保存在本机；默认遮蔽，也不写入日志或错误提示。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        SettingsActions(children: _clearEntry ? [clear, edit] : [edit, clear]),
        if (_notice != null) ...[
          const SizedBox(height: AppSpace.lg),
          Text(
            _notice!,
            key: const ValueKey('spider-account-notice'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: semantic == null
                  ? theme.colorScheme.error
                  : semantic.statusDegraded,
            ),
          ),
        ],
      ],
    );
  }

  Widget _statusRow(ThemeData theme, AppSemanticColors? semantic) {
    if (_reading) {
      return Text(
        '正在读取…',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    if (_statusFailed) {
      return Row(
        children: [
          Icon(
            Icons.help_outline,
            size: 18,
            color:
                semantic?.statusUnknown ?? theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              '暂时无法读取当前状态（不会显示已保存的内容）',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            key: const ValueKey('spider-account-status-retry'),
            onPressed: _readStatus,
            child: const Text('重试'),
          ),
        ],
      );
    }
    final color = _configured
        ? (semantic?.statusOk ?? theme.colorScheme.primary)
        : (semantic?.statusUnknown ?? theme.colorScheme.outline);
    return Row(
      key: const ValueKey('spider-account-status'),
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpace.sm),
        Text(_configured ? '已配置' : '未配置', style: theme.textTheme.titleSmall),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Text(
            _configured
                ? '应用级 Cookie 已保存，正在兼容站源上生效'
                : '还没有应用级 Cookie：兼容站源没有这份账号',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 扫码/注册条目在桌面端的边界说明。
///
/// 这四个条目在安卓端打开的是扫码登录或注册页，依赖 App 的 Activity；桌面宿主没有
/// 这条能力，所以必须**明说不支持**，并把手动填写指成受支持的路径——不能静默换成
/// 一个和入口名字对不上的普通详情页，也不能给一个点不动的按钮。
class _ScanOnlyNotice extends StatelessWidget {
  const _ScanOnlyNotice({required this.provider});

  final SpiderAccountProvider provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.extension<AppSemanticColors>();
    final accent = semantic?.statusDegraded ?? theme.colorScheme.tertiary;
    return Container(
      key: const ValueKey('spider-account-scan-only'),
      padding: const EdgeInsets.all(AppSpace.lg + 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.mdAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.qr_code_2_outlined, size: 20, color: accent),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('桌面端不能完成扫码或注册', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpace.xs),
                Text(
                  '这个条目在安卓端打开的是${provider.label}扫码登录/注册（需要 App 的 Activity），'
                  '桌面端没有这条能力。下方手动填写的 Cookie 是支持的路径。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 密钥输入：默认遮蔽，显示是一次显式动作。
class _SecretDialog extends StatefulWidget {
  const _SecretDialog({required this.provider, required this.save});

  final SpiderAccountProvider provider;
  final Future<String?> Function(String value) save;

  @override
  State<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<_SecretDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _reveal = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.save(_controller.text);
    } catch (_) {
      error = '保存失败，请稍后重试';
    }
    if (!mounted) return;
    if (error != null) {
      // 失败留在输入框里：用户可以直接重试，不需要重新粘贴。
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    setState(() => _busy = false);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassAlertDialog(
      constraints: const BoxConstraints(maxWidth: 568),
      title: Text('${widget.provider.label} Cookie'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '应用级共享：保存后，所有使用 ${widget.provider.preferenceKey} 的兼容站源都会读取这份 Cookie，'
              '站源各自保存的同名值不再单独生效。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              key: const ValueKey('spider-account-secret'),
              controller: _controller,
              autofocus: true,
              obscureText: !_reveal,
              autocorrect: false,
              enableSuggestions: false,
              maxLines: 1,
              onChanged: (_) {
                if (_error != null) {
                  setState(() => _error = null);
                }
              },
              decoration: InputDecoration(
                labelText: 'Cookie（一行）',
                hintText: '粘贴后保存',
                errorText: _error,
                suffixIcon: IconButton(
                  key: const ValueKey('spider-account-reveal'),
                  tooltip: _reveal ? '隐藏' : '显示',
                  onPressed: () => setState(() => _reveal = !_reveal),
                  icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              '默认遮蔽；只有点「显示」才明文显示这一次输入的内容。内容不会进入日志，失败提示也不回显它。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('spider-account-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('spider-account-save'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

/// 清除自己的确认：这是全局动作，不能借空保存顺带完成。
class _ClearConfirmDialog extends StatelessWidget {
  const _ClearConfirmDialog({required this.provider});

  final SpiderAccountProvider provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassAlertDialog(
      constraints: const BoxConstraints(maxWidth: 508),
      title: Text('清除${provider.label}账号？'),
      content: SizedBox(
        width: 460,
        child: Text(
          '这会对所有使用 ${provider.preferenceKey} 的兼容站源生效：它们不再读到这份 Cookie，'
          '也不会回退到站源旧的本地值。其它设置与站点不受影响。',
          style: theme.textTheme.bodyMedium,
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('spider-account-clear-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('保留'),
        ),
        FilledButton(
          key: const ValueKey('spider-account-clear-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('清除'),
        ),
      ],
    );
  }
}
