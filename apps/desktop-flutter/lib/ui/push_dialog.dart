/// 「推送播放」对话框：地址粘贴与本地文件选择合并的唯一起播入口。
///
/// 为什么把本地文件并进来（用户 2026-11-20 决策）：顶栏原本「打开本地文件」占
/// 一个位置，而推送（手机推地址 / 本机粘贴地址）本就和它是一件事的两种来源。
/// 两个入口分开摆，用户会以为「手机推来的」和「我硬盘上的」是互不相干的两条路；
/// 现在只剩一条：**从哪来都进这个对话框**。
///
/// 对话框不做导航：`submitPush` 成功只把请求落成 `pendingPush` 数据，由
/// `AppShell` 投影成 `PlayerPage` 路由。局域网推送走同一条消费路径，因此
/// 「本机输入」与「手机推来」的行为不会有分叉。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import 'tokens.dart';

class PushDialog extends StatefulWidget {
  const PushDialog({
    super.key,
    required this.state,
    required this.pickLocalFile,
  });

  final AppState state;

  /// 本地文件选择器（默认走原生 `file_picker`）。
  ///
  /// 与 `AppShell.pickLocalMediaFile` 同一个理由注入：原生文件对话框在测试里
  /// 起不来，只有换成替身才能验证「选文件 → 走同一条推送链路」本身。
  final Future<String?> Function() pickLocalFile;

  @override
  State<PushDialog> createState() => _PushDialogState();
}

class _PushDialogState extends State<PushDialog> {
  final _url = TextEditingController();
  final _title = TextEditingController();
  bool _busy = false;
  bool _copied = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    super.dispose();
  }

  /// 落地一次推送；失败**不关窗**，原因留在按钮下方。
  ///
  /// 为什么不关窗再弹 toast：地址打错是常态，关窗等于让用户重开对话框、
  /// 重新粘贴；而失败原因（本地文件不存在 / 地址缺失）必须和刚填的地址同屏。
  Future<void> _submit(String url, String title) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var ok = false;
    try {
      ok = await widget.state.submitPush(url: url, title: title);
    } catch (error) {
      // 状态层正常会自己落 `lastError`；这里只兜住「抛出来」的意外，
      // 否则按钮会永远停在忙态。
      widget.state.log.warning('推送提交失败：$error', scope: 'player');
    }
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = widget.state.lastError?.userMessage ?? '无法播放这个地址';
      });
      return;
    }
    // 导航由壳层消费 `pendingPush` 完成（它延到下一帧才压栈）。这里先把忙态
    // 落回去再关窗：万一 pop 没落到本对话框，按钮也不会永远停在「打开中…」。
    setState(() => _busy = false);
    Navigator.of(context).pop();
  }

  Future<void> _pickLocal() async {
    final picked = (await widget.pickLocalFile())?.trim() ?? '';
    // 取消选择不是错误：静默返回，用户还在对话框里，地址栏也没被动过。
    if (!mounted || picked.isEmpty) return;
    await _submit(picked, _title.text.trim());
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 设置里刚打开「接收推送」时地址才出现：对话框开着也要跟着刷新，
    // 否则用户得关窗重开才能看到本机地址。
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => AlertDialog(
        key: const ValueKey('push-dialog'),
        title: const Text('推送播放'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '手机/安卓 App 经局域网推来的地址、或本机粘贴的地址/本地文件，'
                  '都从这里起播。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpace.lg),
                _receiveAddress(context),
                const SizedBox(height: AppSpace.lg),
                TextField(
                  key: const ValueKey('push-dialog-url'),
                  controller: _url,
                  autofocus: true,
                  onSubmitted: (_) => _submit(_url.text.trim(), _title.text.trim()),
                  decoration: const InputDecoration(
                    labelText: '播放地址',
                    hintText: 'http / magnet / 本地路径',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                TextField(
                  key: const ValueKey('push-dialog-title'),
                  controller: _title,
                  onSubmitted: (_) => _submit(_url.text.trim(), _title.text.trim()),
                  decoration: const InputDecoration(
                    labelText: '剧名（可选）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  '推送后先进入「推送详情」页：核对剧名与元数据，确认后再点播放；'
                  '没匹配上可以在那一页手动指定，或用剧名到站点里搜。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Text(
                    _error!,
                    key: const ValueKey('push-dialog-error'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpace.xs,
                children: [
                  TextButton(
                    key: const ValueKey('push-dialog-pick-file'),
                    onPressed: _busy ? null : _pickLocal,
                    child: const Text('选择本地文件…'),
                  ),
                  TextButton(
                    key: const ValueKey('push-dialog-close'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                  FilledButton(
                    key: const ValueKey('push-dialog-play'),
                    onPressed: _busy
                        ? null
                        : () => _submit(_url.text.trim(), _title.text.trim()),
                    child: Text(_busy ? '打开中…' : '打开详情'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 「本机接收地址」：开与不开是两种状态，不共用一套控件。
  ///
  /// 没开时**不给按钮**：剪贴板里没有地址可复制，一个灰按钮或一个点了没反应的
  /// 按钮，只会让用户以为功能坏了。这里直接把去哪个开关打开写清楚。
  Widget _receiveAddress(BuildContext context) {
    final theme = Theme.of(context);
    final address = widget.state.syncState.pushPageUrl?.trim() ?? '';
    if (address.isEmpty) {
      return Text(
        '未开启接收推送：设置 · 连接 → 安卓设备接入 → 开启接收推送播放',
        key: const ValueKey('push-dialog-receive-off'),
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('本机接收地址', style: theme.textTheme.labelMedium),
        const SizedBox(height: AppSpace.xs),
        Row(
          children: [
            Expanded(
              // 可选中：地址要能被单独拷走（整段复制按钮只是省事的一条路）。
              child: SelectableText(
                address,
                key: const ValueKey('push-dialog-receive-url'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            TextButton.icon(
              key: const ValueKey('push-dialog-copy-url'),
              onPressed: () => _copy(address),
              icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
              label: Text(_copied ? '已复制' : '复制'),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          '手机浏览器打开它即可推送；安卓端也可直接推送到这台 PC',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
