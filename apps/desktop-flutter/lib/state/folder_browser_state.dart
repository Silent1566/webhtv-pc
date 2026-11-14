import 'package:flutter/foundation.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../services/site_service.dart';

/// 单层目录的独立请求与分页状态；父层由导航栈保留。
class FolderBrowserState extends ChangeNotifier {
  FolderBrowserState({
    required this.service,
    required this.site,
    required this.folder,
    Map<String, String> filters = const {},
  }) : filters = Map.unmodifiable(filters);

  final SiteService service;
  final Site site;
  final Vod folder;
  final Map<String, String> filters;
  List<Vod> _items = const [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  AppError? _error;
  int? _failedPage;
  bool _failedAppend = false;
  int _run = 0;
  bool _disposed = false;

  List<Vod> get items => _items;
  int get page => _page;
  bool get hasMore => _hasMore;
  bool get loading => _loading;
  AppError? get error => _error;
  bool get failedAppend => _failedAppend;

  Future<void> load() => _request(1, append: false);

  Future<void> retry() async {
    final failedPage = _failedPage;
    if (_disposed || _loading || failedPage == null) return;
    await _request(failedPage, append: _failedAppend);
  }

  Future<void> loadMore() async {
    if (_disposed || _loading || !_hasMore || _page == 0) return;
    await _request(_page + 1, append: true);
  }

  Future<void> _request(int nextPage, {required bool append}) async {
    if (_disposed) return;
    final run = ++_run;
    _loading = true;
    _error = null;
    _failedPage = null;
    notifyListeners();
    try {
      final result = (await service.category(
        site,
        typeId: folder.vodId,
        page: nextPage,
        filters: filters,
      )).value;
      if (_disposed || run != _run) return;
      final seen = <String>{};
      final merged = <Vod>[
        for (final item in [if (append) ..._items, ...result.list])
          if (seen.add(item.vodId)) item,
      ];
      final added = !append || merged.length > _items.length;
      _items = List.unmodifiable(merged);
      _page = nextPage;
      final count = result.pageCount;
      _hasMore =
          result.list.isNotEmpty &&
          (added || (count != null && count > 0)) &&
          (count == null || count <= 0 || nextPage < count);
    } catch (error) {
      if (_disposed || run != _run) return;
      _failedPage = nextPage;
      _failedAppend = append;
      _error = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
    } finally {
      if (!_disposed && run == _run) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _run++;
    super.dispose();
  }
}
