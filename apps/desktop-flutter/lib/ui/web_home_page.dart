/// HTML 首页注入（webHome）的页面宿主。
///
/// 对齐安卓「站点注入 → webHome」：一个本地 `index.html` 目录作为站点首页，
/// 页面通过 `fm` / `fongmiNative` 桥向宿主取能力。PC 侧实现要点：
///
/// - 用 WebView2（`webview_windows`）承载页面，虚拟主机名 `webhome.local`
///   直接映射到源目录，**不新开 HTTP 端口**（比自建 server 少一个暴露面，
///   相对路径仍按目录解析）；访问权限用 `WebviewHostResourceAccessKind.allow`，
///   越出目录的路径由 WebView2 拒绝；
/// - 桥脚本用 `addScriptToExecuteOnDocumentCreated` 注入，保证早于页面自身脚本，
///   页面按安卓写法调用 `fm.request(...)` 即可；
/// - 页面是不可信代码：只允许 `net.request` / `player.playUrl` / `app.info`，
///   其余方法返回 `unsupported`（见 [WebHomeBridge]）；
/// - WebView2 运行时缺失时**如实报错**并给出处置建议，不静默失败。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

import '../services/web_home_bridge.dart';
import '../services/web_home_store.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'player_page.dart';
import 'toast.dart';

/// 虚拟主机名（固定，便于页面判断运行环境）。
const String webHomeVirtualHost = 'webhome.local';

class WebHomePage extends StatefulWidget {
  const WebHomePage({super.key, required this.state, required this.source});

  final AppState state;
  final WebHomeSource source;

  @override
  State<WebHomePage> createState() => _WebHomePageState();
}

class _WebHomePageState extends State<WebHomePage> {
  final WebviewController _controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late final WebHomeBridge _bridge;
  Future<void>? _initialization;

  bool _initializing = true;
  bool _loading = false;
  String? _error;
  String _title = '';

  @override
  void initState() {
    super.initState();
    _title = widget.source.name;
    _bridge = WebHomeBridge(
      sourceKey: widget.source.key,
      log: widget.state.log,
      playHandler: _onPlay,
    );
    unawaited(_initialization = _init());
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _bridge.dispose();
    unawaited(_disposeController());
    super.dispose();
  }

  Future<void> _disposeController() async {
    await _initialization;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    if (_controller.value.isInitialized) await _controller.dispose();
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() {
      _initializing = false;
      _loading = false;
      _error = _explain(error);
    });
  }

  Future<void> _controllerAction(Future<void> Function() action) async {
    if (!mounted || _initializing || !_controller.value.isInitialized) return;
    try {
      await action();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _init() async {
    try {
      if (!_controller.value.isInitialized) await _controller.initialize();
      if (!mounted) return;
      if (!widget.source.isRemote) {
        await _controller.addVirtualHostNameMapping(
          webHomeVirtualHost,
          widget.state.webHomeDirectory(widget.source.key),
          WebviewHostResourceAccessKind.allow,
        );
        if (!mounted) return;
      }
      if (_subscriptions.isEmpty) {
        await _controller.addScriptToExecuteOnDocumentCreated(
          webHomeBridgeScript,
        );
        if (!mounted) return;
        _subscriptions.add(
          _controller.webMessage.listen((message) async {
            if (!mounted) return;
            try {
              final reply = await _bridge.handleMessage('$message');
              if (!mounted) return;
              if (reply != null) await _controller.postWebMessage(reply);
            } catch (error) {
              _showError(error);
            }
          }),
        );
        _subscriptions.add(
          _controller.title.listen((value) {
            if (mounted && value.trim().isNotEmpty) {
              setState(() => _title = value.trim());
            }
          }),
        );
        _subscriptions.add(_controller.onLoadError.listen(_showError));
        _subscriptions.add(
          _controller.loadingState.listen((value) {
            if (!mounted) return;
            setState(() {
              if (value == LoadingState.loading) {
                _loading = true;
                _error = null;
              } else if (value == LoadingState.navigationCompleted) {
                _loading = false;
              }
            });
          }),
        );
      }
      if (!mounted) return;
      setState(() => _loading = true);
      await _controller.loadUrl(
        widget.source.isRemote
            ? widget.source.remoteUrl
            : 'https://$webHomeVirtualHost/${widget.source.entry}',
      );
      if (!mounted) return;
      // loadUrl只提交导航；完成和网络错误由原生事件通知。
      setState(() => _initializing = false);
    } catch (error) {
      _showError(error);
    }
  }

  /// 把底层异常翻译成用户能照做的建议。
  String _explain(Object error) {
    final text = '$error';
    if (text.toLowerCase().contains('webview2')) {
      return '缺少 WebView2 运行时。请安装 Microsoft Edge WebView2 Runtime 后重试。\n\n$text';
    }
    return '页面加载失败：$text';
  }

  Future<void> _onPlay(
    String url,
    Map<String, String> headers,
    String title,
  ) async {
    if (!mounted) return;
    if (url.toLowerCase().endsWith('.m3u8') ||
        url.toLowerCase().endsWith('.mp4') ||
        url.startsWith('http')) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: widget.state,
            request: PlaybackRequest(
              url: url,
              title: title,
              siteKey: 'webhome:${widget.source.key}',
              vodId: widget.source.key,
              vodName: widget.source.name,
              episodeName: title,
              flag: '',
              headers: headers,
              directUrl: true,
            ),
          ),
        ),
      );
      return;
    }
    if (mounted) showToast('无法识别的播放地址：$url', kind: ToastKind.error);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title.isEmpty ? widget.source.name : _title),
        actions: [
          IconButton(
            key: const ValueKey('webhome-reload'),
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed:
                !_initializing &&
                    _controller.value.isInitialized &&
                    _error == null
                ? () => unawaited(_controllerAction(_controller.reload))
                : null,
          ),
          IconButton(
            key: const ValueKey('webhome-devtools'),
            tooltip: '开发者工具（排查页面问题）',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed:
                !_initializing &&
                    _controller.value.isInitialized &&
                    _error == null
                ? () => unawaited(_controllerAction(_controller.openDevTools))
                : null,
          ),
        ],
      ),
      body: Padding(
        padding: formPagePadding(context),
        child: _error != null
            ? _ErrorCard(
                message: _error!,
                sourceKey: widget.source.key,
                entryName: widget.source.isRemote
                    ? widget.source.remoteUrl
                    : widget.source.entry,
                onRetry: _retry,
              )
            : Stack(
                children: [
                  if (!_initializing) Webview(_controller),
                  if (_initializing || _loading)
                    const Center(child: CircularProgressIndicator()),
                ],
              ),
      ),
    );
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _initializing = true;
    });
    await (_initialization = _init());
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    required this.sourceKey,
    required this.entryName,
    required this.onRetry,
  });

  final String message;
  final String sourceKey;
  final String entryName;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.orange),
                    const SizedBox(width: 8),
                    Text(
                      'HTML 源无法显示',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(message),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('webhome-retry'),
                      onPressed: () => unawaited(onRetry()),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '源 key：$sourceKey · 入口：$entryName',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
