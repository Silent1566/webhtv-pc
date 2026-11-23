/// 「软件更新」明细页（ADR-0015）。
///
/// 这一页只做两件事：把 [AppState] 里的更新事实投影成文案，把用户的点击
/// 交给 [AppState]。判据（哪个版本更新、该装哪个文件）在 `core/app_update.dart`，
/// 网络与磁盘动作在 `services/app_update_service.dart`。
///
/// 两条硬约束：
/// - **构建不联网**：打开/重建/滚动本页一个请求都不发，只有用户点「检查更新」
///   与壳层首帧后的 [AppState.maybeAutoCheckForUpdates] 会真的检查；
/// - **安装永远来自一次点击**：本页没有「自动装」的路径，下载完也只是把结果
///   说清楚（需要重启的会写进结果文案）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../state/app_state.dart';
import 'settings_layout.dart';
import 'toast.dart';
import 'tokens.dart';

class AppUpdatePage extends StatelessWidget {
  const AppUpdatePage({super.key, required this.state});

  final AppState state;

  /// 路由与入口行的标题。
  static const String title = '软件更新';

  /// 页面说明：只碰程序本体，站点配置与用户数据不在这次更新里。
  static const String description = '检查应用本体更新；只更新程序，不动站源与用户数据。';

  /// 设置「维护」分类那一行的摘要。
  ///
  /// 口径只写在这里一处：分类页与页面正文都从同一份状态推文案，否则「行上写
  /// 已是最新、进页面看到发现新版本」这种自相矛盾迟早会出现。
  static String summary(AppState state) => summaryOf(
    version: state.appUpdateIdentity.version,
    isReleaseBuild: state.appUpdateIdentity.isReleaseBuild,
    check: state.updateCheck,
    lastCheckError: state.updatePreferences.lastCheckError,
  );

  /// 摘要的纯函数形态：五档状态各写一句话。
  ///
  /// 单独留一个入参形态而不是只收 [AppState]：widget 测试里的构建永远是开发
  /// 构建（APP_TAG 是编译期注入的），「未检查 / 已是最新」两档若只能经
  /// AppState 走，就永远测不到。
  static String summaryOf({
    required String version,
    required bool isReleaseBuild,
    required AppUpdateCheck? check,
    String? lastCheckError,
  }) {
    if (check != null) {
      if (check.failed) return '上次检查失败：${check.message ?? '未知原因'}';
      if (check.hasUpdate) {
        final tag = check.release?.tag ?? '';
        return tag.isEmpty ? '发现新版本' : '可更新到 $tag';
      }
      if (check.verdict == AppUpdateVerdict.developmentBuild) {
        return '当前 v$version · 开发构建';
      }
      return '当前 v$version · 已是最新';
    }
    final error = lastCheckError;
    if (error != null && error.isNotEmpty) return '上次检查失败：$error';
    if (!isReleaseBuild) return '当前 v$version · 开发构建';
    return '当前 v$version · 未检查';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final release = state.updateCheck?.release;
      return SettingsDetailScaffold(
        title: title,
        description: description,
        children: [
          SettingsSection(
            title: '本机版本',
            description: '通道只影响「查到哪条发布」；测试版包含预发布构建，可能不稳定。',
            children: [
              Text(
                _identityText(),
                key: const ValueKey('settings-update-identity'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              SwitchListTile(
                key: const ValueKey('settings-update-auto-check'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('启动时自动检查更新'),
                subtitle: const Text('每 24 小时最多检查一次；只检查，不自动下载或安装'),
                value: state.updatePreferences.autoCheck,
                onChanged: (value) =>
                    unawaited(state.setUpdateAutoCheck(value)),
              ),
              const SizedBox(height: AppSpace.sm),
              SettingsField(
                label: '更新通道',
                child: Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (final channel in AppUpdateChannel.values)
                      ChoiceChip(
                        key: ValueKey(
                          'settings-update-channel-${channel.name}',
                        ),
                        label: Text(channel.label),
                        selected: state.updatePreferences.channel == channel,
                        onSelected: _busy
                            ? null
                            : (selected) {
                                if (!selected) return;
                                unawaited(state.setUpdateChannel(channel));
                              },
                      ),
                  ],
                ),
              ),
              Text(
                _statusText(),
                key: const ValueKey('settings-update-status'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (state.updateCheck?.source case final source?)
                Text(
                  '信息来源：$source',
                  key: const ValueKey('settings-update-source'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (state.updateCheck?.fromCache == true)
                Text(
                  _cacheHint(state.updateCheck!),
                  key: const ValueKey('settings-update-cache-hint'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (state.updateCheck?.retryAt case final retryAt?)
                Text(
                  'GitHub API 可重试时间：${formatAppUpdateTime(retryAt)}；静态索引仍可检查',
                  key: const ValueKey('settings-update-retry-at'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: AppSpace.md),
              SettingsActions(
                children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('settings-update-check'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(state.checkForUpdates()),
                    icon: const Icon(Icons.refresh),
                    label: Text(state.updateChecking ? '正在检查…' : '检查更新'),
                  ),
                  // 检查失败、通道里没版本、或者只是想自己看：发布页是兜底入口，
                  // 因此它永远可点，不跟着检查状态置灰。
                  OutlinedButton.icon(
                    key: const ValueKey('settings-update-release-page'),
                    onPressed: () => unawaited(
                      state.openExternalUrl(state.updateReleasePage.toString()),
                    ),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('打开 Release 页面'),
                  ),
                ],
              ),
            ],
          ),
          if (release != null)
            SettingsSection(
              title: state.updateCheck!.failed ? '缓存版本（仅供参考）' : '可用版本',
              children: [
                _NewVersionBlock(
                  release: release,
                  historical: state.updateCheck!.failed,
                ),
                _ReleaseNotes(release: release),
              ],
            ),
          SettingsSection(
            title: '下载与安装',
            description:
                '下载校验通过才会安装：Windows 便携包在退出后自动换装，'
                'Linux AppImage 原地替换，deb 交给系统安装器。',
            children: [
              SettingsActions(
                children: [
                  FilledButton.icon(
                    key: const ValueKey('settings-update-install'),
                    onPressed: _canInstall ? () => unawaited(_install()) : null,
                    icon: Icon(
                      state.updateInstalling
                          ? Icons.hourglass_top
                          : Icons.download_for_offline_outlined,
                    ),
                    label: Text(_installLabel()),
                  ),
                ],
              ),
              if (state.updateDownloading) ...[
                const SizedBox(height: AppSpace.md),
                LinearProgressIndicator(
                  key: const ValueKey('settings-update-progress'),
                  value: state.updateDownloadProgress,
                  minHeight: 6,
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  _progressText(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_resultText() case final result?) ...[
                const SizedBox(height: AppSpace.md),
                Text(
                  result,
                  key: const ValueKey('settings-update-result'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: state.updateInstallResult?.ok == false
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
              ],
            ],
          ),
          SettingsSection(
            title: 'GitHub 下载加速',
            description:
                '使用第三方服务加速公开的 GitHub 更新下载；第三方会看到公开下载 URL。'
                '速度因网络而异，失败自动直连。不影响全局出站代理。',
            children: [
              SwitchListTile(
                key: const ValueKey('settings-update-proxy-enabled'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 GitHub 下载代理'),
                value: state.updatePreferences.githubProxy.enabled,
                onChanged: _busy
                    ? null
                    : (enabled) => unawaited(
                        _saveProxy(
                          state.updatePreferences.githubProxy.copyWith(
                            enabled: enabled,
                          ),
                        ),
                      ),
              ),
              ListTile(
                key: const ValueKey('settings-update-proxy-url'),
                contentPadding: EdgeInsets.zero,
                title: const Text('下载代理地址'),
                subtitle: Text(state.updatePreferences.githubProxy.baseUrl),
                trailing: const Icon(Icons.edit_outlined),
                enabled: !_busy && state.updatePreferences.githubProxy.enabled,
                onTap: _busy || !state.updatePreferences.githubProxy.enabled
                    ? null
                    : () => unawaited(_selectProxy(context)),
              ),
            ],
          ),
        ],
      );
    },
  );

  bool get _busy =>
      state.updateChecking || state.updateDownloading || state.updateInstalling;

  Future<void> _saveProxy(AppUpdateProxySettings settings) async {
    if (!await state.setUpdateGithubProxy(settings)) {
      showToast(
        '下载代理设置保存失败',
        detail: '设置未更改，请在更新操作结束后重试，并检查设置目录是否可写。',
        kind: ToastKind.error,
      );
    }
  }

  Future<void> _selectProxy(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('下载代理地址'),
        children: [
          for (final url in appUpdateProxyPresets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, url),
              child: Row(
                children: [
                  Expanded(child: Text(Uri.parse(url).host)),
                  if (url == state.updatePreferences.githubProxy.baseUrl)
                    const Icon(Icons.check),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'custom'),
            child: const Text('自定义 HTTPS 地址'),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    if (selected == 'custom') {
      await showDialog<void>(
        context: context,
        builder: (_) => _UpdateProxyAddressDialog(state: state),
      );
    } else {
      await _saveProxy(
        state.updatePreferences.githubProxy.copyWith(baseUrl: selected),
      );
    }
  }

  String _cacheHint(AppUpdateCheck check) {
    final saved = check.cachedAt;
    final age = saved == null ? null : check.checkedAt.difference(saved);
    final ageText = age == null
        ? '时间未知'
        : age.inDays > 0
        ? '${age.inDays} 天'
        : age.inHours > 0
        ? '${age.inHours} 小时'
        : '${age.inMinutes.clamp(0, 59)} 分钟';
    final time = saved == null ? '' : ' · 保存于 ${formatAppUpdateTime(saved)}';
    final stateText = check.failed ? '仅供参考，尚未确认最新版本' : '已使用缓存';
    return '$stateText · 缓存年龄 $ageText$time';
  }

  bool get _canInstall {
    final check = state.updateCheck;
    if (check == null) return false;
    // 「已是最新」时置灰：再点一次只会把同一个包重新下一个遍。开发构建例外——
    // 它本来就要手动装一次发布包才能进入更新通道。
    if (!check.hasUpdate &&
        check.verdict != AppUpdateVerdict.developmentBuild) {
      return false;
    }
    return !_busy;
  }

  String _identityText() {
    final identity = state.appUpdateIdentity;
    if (!identity.isReleaseBuild) {
      return 'v${identity.version} · 开发构建（不参与通道比较，可在 Release 页面手动下载）';
    }
    return 'v${identity.version} · ${identity.tag}';
  }

  /// 状态文本：把 [AppUpdateVerdict] 的四种结论投影成一句中文。
  String _statusText() {
    final check = state.updateCheck;
    if (check == null) {
      final error = state.updatePreferences.lastCheckError;
      if (error != null && error.isNotEmpty) return '上次检查失败：$error';
      return '未检查过';
    }
    final tag = check.release?.tag ?? '';
    return switch (check.verdict) {
      AppUpdateVerdict.updateAvailable => tag.isEmpty ? '发现新版本' : '发现新版本 $tag',
      AppUpdateVerdict.upToDate => tag.isEmpty ? '已是最新' : '已是最新（$tag）',
      AppUpdateVerdict.developmentBuild => '当前为开发构建，不参与通道比较',
      AppUpdateVerdict.failed => '检查失败：${check.message ?? '未知原因'}',
    };
  }

  String _installLabel() {
    if (state.updateDownloading) return '正在下载…';
    if (state.updateInstalling) return '正在安装…';
    return '下载并安装';
  }

  String _progressText() {
    final total = state.updateDownloadTotal;
    final received = formatAppUpdateBytes(state.updateDownloadReceived);
    if (total == null || total <= 0) return '已下载 $received';
    return '已下载 $received / ${formatAppUpdateBytes(total)}';
  }

  /// 页面内的结果文本：安装结果优先，其次下载失败原因。
  ///
  /// 通知只负责「刚才那一下」；页面文本负责「现在是什么状态」，用户滚一屏
  /// 回来仍然读得到失败原因。
  String? _resultText() {
    final install = state.updateInstallResult;
    if (install != null) {
      final message = install.message;
      if (message != null && message.isNotEmpty) return message;
      return install.ok ? '更新已就绪。' : '安装失败。';
    }
    final error = state.updateDownloadError;
    if (error != null && error.isNotEmpty) return error;
    return null;
  }

  /// 一次点击完成「下载 → 校验 → 安装」；结果同时进页面文本与右下角通知。
  Future<void> _install() async {
    final result = await state.downloadAndInstallUpdate();
    if (result == null) {
      showToast(
        '更新包下载失败',
        detail: state.updateDownloadError ?? '请稍后重试，或到 Release 页面手动下载',
        kind: ToastKind.error,
      );
      return;
    }
    if (result.ok) {
      showToast('更新已下载并校验通过', detail: result.message, kind: ToastKind.success);
      return;
    }
    showToast('安装更新失败', detail: result.message, kind: ToastKind.error);
  }
}

class _UpdateProxyAddressDialog extends StatefulWidget {
  const _UpdateProxyAddressDialog({required this.state});

  final AppState state;

  @override
  State<_UpdateProxyAddressDialog> createState() =>
      _UpdateProxyAddressDialogState();
}

class _UpdateProxyAddressDialogState extends State<_UpdateProxyAddressDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.state.updatePreferences.githubProxy.baseUrl,
  );
  String? _error;
  String _status = '有效修改即生效并自动保存';
  int _revision = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _change(String text) async {
    final revision = ++_revision;
    final normalized = AppUpdateProxySettings.normalizeBaseUrl(text);
    setState(() {
      _error = normalized == null ? '请输入 HTTPS 地址，不含账号、查询参数或片段' : null;
      _status = normalized == null ? '无效地址未保存' : '正在自动保存…';
    });
    if (normalized == null) return;
    final saved = await widget.state.setUpdateGithubProxy(
      widget.state.updatePreferences.githubProxy.copyWith(baseUrl: normalized),
    );
    if (!mounted || revision != _revision) return;
    setState(() {
      _status = saved ? '已自动保存' : '自动保存失败，设置未更改，请修改后重试';
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('自定义下载代理'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: 'HTTPS 代理前缀',
            hintText: defaultAppUpdateProxyUrl,
            errorText: _error,
            errorMaxLines: 3,
          ),
          onChanged: _change,
        ),
        const SizedBox(height: AppSpace.sm),
        Text(_status, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  );
}

/// 「可更新到」标题：版本、通道与发布时间。
class _NewVersionBlock extends StatelessWidget {
  const _NewVersionBlock({required this.release, this.historical = false});

  final bool historical;

  final AppRelease release;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final publishedAt = release.publishedAt;
    return Padding(
      key: const ValueKey('settings-update-new-version'),
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${historical ? '历史版本' : '可更新到'} ${release.tag}',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('通道：${release.channel.label}'),
              ),
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  publishedAt == null
                      ? '发布时间未知'
                      : '发布于 ${formatAppUpdateTime(publishedAt)}',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 发布说明：可选择复制，但高度封顶 —— 一条 Release 的正文可以有几百行，
/// 让它按内容撑开会把「下载并安装」按钮挤出几屏之外。
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes({required this.release});

  final AppRelease release;

  /// 说明区高度上限（逻辑像素）。
  static const double maxHeight = 240;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = release.body.trim();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.mdAll,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: SelectableText(
            body.isEmpty ? '这条发布没有填写说明。' : body,
            key: const ValueKey('settings-update-notes'),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

/// 检查时间与发布时间共用的一种短格式（本地时区，精确到分钟）。
String formatAppUpdateTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
