/// Phase 5 · 分类筛选 UI（§7.4.7 分页与筛选）。
///
/// 缺陷背景（用户反馈）：**网关返回了筛选数据，但分类页完全没有渲染**。
/// 实测 `木偶[盘]` 首页返回 `filters: {"1":[{key:"class",name:"剧情",value:[…]}]}`，
/// 而 `grep "filters" lib/ui/` 零命中——整条数据链路（解析 → 服务 → 状态层）
/// 都已实现，唯一缺口是 UI。
///
/// 本文件锁住三件事：
/// 1. 筛选项**可见**（每个维度一行标题 + 垂直选项列表，纯 A 方案）；
/// 2. 点击筛选项**真的发出带筛选的请求**（不是只改 UI 状态）；
/// 3. **切分类保留筛选**（用户选了"2024"换分类后仍按 2024 筛），回首页才清空。
///
/// 请求形态用**真实 HTTP 捕获**断言：`type=4` 的筛选必须走
/// `ext=<base64url(json)>`——实测只有这一种编码会被网关接受（其余候选返回未筛选全量）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 捕获请求并返回可控响应的假 HTTP 客户端。
///
/// 只实现 `HttpApiClient` 需要的 `get`/`post`（`package:http` 的 `BaseClient`
/// 已提供其余方法的默认实现）。
class _CapturingClient extends http.BaseClient {
  _CapturingClient(this._handler);

  final FutureOr<Object?> Function(Uri uri, String? body) _handler;
  final List<Uri> requests = [];
  final List<String?> bodies = [];

  Uri get last => requests.last;
  Map<String, String> get lastQuery => last.queryParameters;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    String? body;
    if (request is http.Request) body = request.body;
    bodies.add(body);
    final payload = await _handler(request.url, body);
    if (payload is int) {
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{"code":-1,"msg":"injected"}')),
        payload,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }
}

/// 首页响应：带 `class` 与**按 type_id 分组的 filters**（真实网关形态）。
Map<String, Object?> _homePayload() => {
  'class': [
    {'type_id': '1', 'type_name': '电影'},
    {'type_id': '2', 'type_name': '电视剧'},
  ],
  'filters': {
    '1': [
      {
        'key': 'class',
        'name': '剧情',
        'value': [
          {'n': '全部', 'v': ''},
          {'n': '喜剧', 'v': '喜剧'},
          {'n': '爱情', 'v': '爱情'},
        ],
      },
      {
        'key': 'area',
        'name': '地区',
        'value': [
          {'n': '全部', 'v': ''},
          {'n': '大陆', 'v': '大陆'},
        ],
      },
    ],
    '2': [
      {
        'key': 'class',
        'name': '剧情',
        'value': [
          {'n': '全部', 'v': ''},
          {'n': '悬疑', 'v': '悬疑'},
        ],
      },
    ],
  },
  'list': [
    {'vod_id': 'v1', 'vod_name': '影片一', 'vod_pic': ''},
  ],
  'page': 1,
  'pagecount': 1,
  'total': 1,
};

/// 分类响应：带上**该分类特有**的 filters。
///
/// 刻意让每个 `type_id` 的维度不同（并带 `来自分类` 标记），这样"分类响应优先于
/// 首页"这条断言才有鉴别力——否则两种来源内容相同，断言等于没测。
Map<String, Object?> _categoryPayload(String tid) => {
  'class': [
    {'type_id': '1', 'type_name': '电影'},
    {'type_id': '2', 'type_name': '电视剧'},
  ],
  'filters': {
    tid: [
      {
        'key': 'class',
        'name': '来自分类-$tid',
        'value': [
          {'n': '全部', 'v': ''},
          {'n': '分类专属$tid', 'v': '分类专属$tid'},
        ],
      },
    ],
  },
  'list': [
    {'vod_id': 'v-$tid', 'vod_name': '分类影片 $tid', 'vod_pic': ''},
  ],
  'page': 1,
  'pagecount': 2,
  'total': 20,
};

/// 分类**分页**响应：按 `pg` 返回不同页，末页为空（真实站点行为）。
///
/// 刻意把 `pagecount` 回成 `当前页 + 1`，因为真机就是这样：实测
/// `闪电[盘]` 同一分类连翻，pg=1→pagecount=2、pg=2→pagecount=3、pg=3→pagecount=4，
/// `total` 同步从 92 涨到 112、132。用这种“不可信”的元数据才能拦住
/// “以 pagecount 判到底”的错误实现。
Map<String, Object?> _pagedCategoryPayload(String tid, int pg) {
  if (pg > 2) {
    return {
      'class': [
        {'type_id': '1', 'type_name': '电影'},
      ],
      'list': const [],
      'page': pg,
      'pagecount': pg + 1,
      'total': 92 + pg * 20,
    };
  }
  return {
    'class': [
      {'type_id': '1', 'type_name': '电影'},
    ],
    'list': [
      for (var i = 0; i < 3; i++)
        {
          'vod_id': 'p$pg-v$i',
          'vod_name': '第 $pg 页第 $i 部',
          'vod_pic': '',
        },
    ],
    'page': pg,
    'pagecount': pg + 1,
    'total': 92 + pg * 20,
  };
}

void main() {
  late Directory temp;
  late _CapturingClient client;
  late AppState state;

  /// 启动一个带**已导入配置**的 `AppState`，并注入捕获客户端。
  ///
  /// 关键：必须先 `importConfig` 才会 `_attachSiteService()` 装配 `SiteService`。
  /// 只调 `selectSite` 不会建立站点服务，`loadHome` 会静默返回（实测踩过：
  /// 结果 `homeResult == null` 且零请求，看起来像产品缺陷，其实是测试少了一步）。
  Future<void> boot({Object? Function(Uri, String?)? handler}) async {
    temp = Directory.systemTemp.createTempSync('webhtv-filter');
    client = _CapturingClient(
      handler ??
          (uri, _) => uri.queryParameters.containsKey('t')
              ? _categoryPayload(uri.queryParameters['t']!)
              : _homePayload(),
    );
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
      httpClient: client,
    );
    await state.bootstrap();
    // 以内联 JSON 导入配置（不经网络），站点指向捕获客户端的假网关。
    await state.importConfig(
      jsonEncode({
        'name': '筛选测试配置',
        'sites': [
          {
            'key': 'bridge_site',
            'name': '桥接站点',
            'type': SiteType.jsonApiBase64Ext,
            'api': 'http://127.0.0.1:19978/vod/api?key=bridge_site',
            'searchable': 1,
            'filterable': 1,
          },
        ],
      }),
      displayName: '筛选测试配置',
    );
    expect(
      state.selectedSite?.key,
      'bridge_site',
      reason: '前置条件：导入后应选中该站点（否则站点服务未装配）',
    );
    // 导入会自动加载首页；清掉这次请求，后续断言只看筛选相关请求。
    client.requests.clear();
  }

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('筛选数据解析（§7.4.7）', () {
    test('首页 filters 按 type_id 分组被解析出来', () async {
      await boot();

      final filters = state.homeResult?.filters;
      expect(filters, isNotNull);
      expect(filters!.keys.toSet(), {'1', '2'});
      expect(filters['1']!.first.key, 'class');
      expect(filters['1']!.first.name, '剧情');
      expect(
        filters['1']!.first.options.map((o) => o.name).toList(),
        ['全部', '喜剧', '爱情'],
      );
    });

    test('筛选对象按 ext=base64url 发出（唯一被网关接受的编码）', () async {
      await boot();
      await state.loadCategory('1');
      client.requests.clear();

      client.requests.clear();
      await state.setCategoryFilter('class', '喜剧');

      expect(client.requests, hasLength(1), reason: '筛选应即时发一次请求');
      final q = client.lastQuery;
      expect(q['ac'], 'detail');
      expect(q['t'], '1');
      expect(q['pg'], '1');
      expect(q.containsKey('ext'), isTrue, reason: 'type=4 必须用 ext 传筛选');

      // 解码校验：ext 必须是 base64url(JSON)，内容是 {class: 喜剧}
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(q['ext']!)),
      );
      expect(jsonDecode(decoded), {'class': '喜剧'});
    });

    test('选「全部」（空值）等于清除该维度', () async {
      await boot();
      await state.loadCategory('1');
      client.requests.clear();
      await state.setCategoryFilter('class', '喜剧');
      expect(state.categoryFilters, {'class': '喜剧'});

      await state.setCategoryFilter('class', '');
      expect(state.categoryFilters, isEmpty);
      // 清除后不再带 ext（空筛选不发送）。
      expect(client.lastQuery.containsKey('ext'), isFalse);
    });
  });

  group('滚动加载下一页（§7.4.7 分页）', () {
    /// 站点**忽略 `pg` 参数**、反复回同一页（实测存在）：必须以“没有新条目”停止，
    /// 否则滚动到底会无休止地重发同一个请求。
    Future<void> bootIgnoringPage() => boot(
      handler: (uri, _) {
        final pg = int.tryParse(uri.queryParameters['pg'] ?? '1') ?? 1;
        // 无论 pg 是多少都回第一页的内容。
        return _pagedCategoryPayload(uri.queryParameters['t']!, 1)
          ..['page'] = pg;
      },
    );

    test('loadCategory 重置分页状态，loadMoreCategory 追加而不是替换', () async {
      await boot(
        handler: (uri, _) {
          final q = uri.queryParameters;
          if (!q.containsKey('t')) return _homePayload();
          return _pagedCategoryPayload(
            q['t']!,
            int.tryParse(q['pg'] ?? '1') ?? 1,
          );
        },
      );

      await state.loadCategory('1');
      expect(state.categoryResult!.list, hasLength(3));
      expect(state.categoryPage, 1);
      expect(state.categoryHasMore, isTrue, reason: '第一页非空 → 先假定还有下一页');

      await state.loadMoreCategory();
      expect(
        state.categoryResult!.list,
        hasLength(6),
        reason: '追加必须保留第一页（替换会让已看过的内容从列表里消失）',
      );
      expect(state.categoryPage, 2);
      expect(
        state.categoryResult!.list.map((v) => v.vodId),
        ['p1-v0', 'p1-v1', 'p1-v2', 'p2-v0', 'p2-v1', 'p2-v2'],
        reason: '顺序必须保持“旧页在前”',
      );
    });

    test('末页为空 → categoryHasMore 收敛为 false（不会无限加载）', () async {
      await boot(
        handler: (uri, _) {
          final q = uri.queryParameters;
          if (!q.containsKey('t')) return _homePayload();
          return _pagedCategoryPayload(
            q['t']!,
            int.tryParse(q['pg'] ?? '1') ?? 1,
          );
        },
      );

      await state.loadCategory('1');
      await state.loadMoreCategory();
      expect(state.categoryHasMore, isTrue);

      // 第 3 页为空 → 到底。
      await state.loadMoreCategory();
      expect(
        state.categoryHasMore,
        isFalse,
        reason: '空页是终止信号，否则滚动到底会一直请求下去',
      );
      expect(state.categoryResult!.list, hasLength(6), reason: '空页不得改变已有列表');
    });

    test('站点忽略 pg（反复回同一页）→ 无新条目即停止，不无限重发', () async {
      await bootIgnoringPage();

      await state.loadCategory('1');
      expect(state.categoryResult!.list, hasLength(3));

      await state.loadMoreCategory();
      expect(
        state.categoryHasMore,
        isFalse,
        reason: '第二页没有带来新条目 → 站点不支持分页或已到底',
      );
      expect(
        state.categoryResult!.list,
        hasLength(3),
        reason: '重复条目必须被去重，不得在列表里出现两份',
      );

      // 再调也不会再发请求（hasMore 已收敛）。
      final before = client.requests.length;
      await state.loadMoreCategory();
      expect(client.requests.length, before, reason: 'hasMore=false 时不得再发请求');
    });

    test('追加失败不写 lastError、不毁掉已加载列表', () async {
      var failNext = false;
      await boot(
        handler: (uri, _) {
          final q = uri.queryParameters;
          if (!q.containsKey('t')) return _homePayload();
          if (failNext) return 500;
          return _pagedCategoryPayload(
            q['t']!,
            int.tryParse(q['pg'] ?? '1') ?? 1,
          );
        },
      );

      await state.loadCategory('1');
      final firstPage = state.categoryResult!.list;
      expect(firstPage, hasLength(3));

      failNext = true;
      await state.loadMoreCategory();
      expect(state.lastError, isNull, reason: '追加失败不得用错误横幅换掉用户正在看的列表');
      expect(state.categoryResult!.list, hasLength(3), reason: '失败后保留已加载内容');
      expect(state.categoryHasMore, isFalse, reason: '失败后不再反复重试同一页');
    });

    test('切分类作废在途的下一页响应（不得拼到新分类后面）', () async {
      // 第 2 页的响应挂起，直到切到分类 2 之后才返回。
      final gate = Completer<void>();
      await boot(
        handler: (uri, _) async {
          final q = uri.queryParameters;
          if (!q.containsKey('t')) return _homePayload();
          final tid = q['t']!;
          final pg = int.tryParse(q['pg'] ?? '1') ?? 1;
          if (tid == '1' && pg == 2) await gate.future;
          return _pagedCategoryPayload(tid, pg);
        },
      );

      await state.loadCategory('1');
      final pending = state.loadMoreCategory();

      // 在迟到响应到达前切到分类 2。
      await state.loadCategory('2');
      expect(state.selectedTypeId, '2');
      final afterSwitch = state.categoryResult!.list.map((v) => v.vodId).toList();

      gate.complete();
      await pending;

      expect(
        state.categoryResult!.list.map((v) => v.vodId).toList(),
        afterSwitch,
        reason: '属于分类 1 的迟到页不得追加到分类 2 的列表里',
      );
    });
  });

  group('筛选与分类联动（保留语义）', () {
    test('切分类**保留**筛选条件（TVBox 惯例）', () async {
      await boot();
      await state.loadCategory('1');
      client.requests.clear();
      await state.setCategoryFilter('class', '喜剧');

      client.requests.clear();
      client.requests.clear();
      await state.loadCategory('2');

      expect(state.selectedTypeId, '2');
      expect(
        state.categoryFilters,
        {'class': '喜剧'},
        reason: '换分类不应清掉用户的筛选',
      );
      final q = client.lastQuery;
      expect(q['t'], '2');
      expect(q.containsKey('ext'), isTrue, reason: '切分类后仍须带筛选');
    });

    test('回首页（默认推荐）清空筛选', () async {
      await boot();
      await state.loadCategory('1');
      client.requests.clear();
      await state.setCategoryFilter('class', '喜剧');

      state.selectDefaultListing();
      expect(state.selectedTypeId, isNull);
      expect(state.categoryFilters, isEmpty, reason: '离开分类上下文，筛选作废');
    });

    test('clearCategoryFilters 一次清空全部维度并重载', () async {
      await boot();
      await state.loadCategory('1');
      client.requests.clear();
      await state.setCategoryFilter('class', '喜剧');
      await state.setCategoryFilter('area', '大陆');
      expect(state.categoryFilters.length, 2);

      await state.clearCategoryFilters();
      expect(state.categoryFilters, isEmpty);
      expect(client.lastQuery.containsKey('ext'), isFalse);
    });

    test('相同筛选值不重复发请求（幂等）', () async {
      await boot();
      await state.loadCategory('1');
      client.requests.clear();
      await state.setCategoryFilter('class', '喜剧');

      client.requests.clear();
      await state.setCategoryFilter('class', '喜剧');
      expect(client.requests, isEmpty, reason: '值未变不应重发');
    });

    test('未选分类时设置筛选不发请求（没有 t 参数无从筛选）', () async {
      await boot();

      client.requests.clear();
      await state.setCategoryFilter('class', '喜剧');
      expect(client.requests, isEmpty);
      expect(state.categoryFilters, isEmpty);
    });
  });

  group('筛选维度归属（按 type_id 取子集）', () {
    test('分类请求返回的 filters 优先于首页（拿得到更精确的一组）', () async {
      await boot();
      client.requests.clear();
      await state.loadCategory('2');

      // 分类响应里带的是「来自分类-2」+「分类专属2」；首页那份是「剧情」+「喜剧」。
      // 断言拿到的是分类那一份，才能证明"更精确的来源优先"。
      final groups = state.categoryResult!.filters['2']!;
      expect(groups, hasLength(1));
      expect(groups.first.name, '来自分类-2');
      expect(
        groups.first.options.map((o) => o.value).toList(),
        ['', '分类专属2'],
      );
    });

    test('首页 filters 缺少当前 type_id 时回退到唯一那一组（宁多不少）', () async {
      await boot(
        handler: (uri, _) => uri.queryParameters.containsKey('t')
            ? _categoryPayload(uri.queryParameters['t']!)
            : {
                'class': [
                  {'type_id': '1', 'type_name': '电影'},
                ],
                // 只有一组，但键名与 type_id 不一致（部分站点如此）。
                'filters': {
                  'movie': [
                    {
                      'key': 'year',
                      'name': '年份',
                      'value': [
                        {'n': '全部', 'v': ''},
                        {'n': '2024', 'v': '2024'},
                      ],
                    },
                  ],
                },
                'list': [
                  {'vod_id': 'v1', 'vod_name': '影片一'},
                ],
              },
      );

      final filters = state.homeResult!.filters;
      expect(filters.length, 1);
      expect(filters.values.first.first.key, 'year');
    });
  });

  group('首页无推荐内容时自动进入第一个分类（用户反馈 2026-10-09）', () {
    /// 首页只回 `class` 不回 `list`（实测 126 站点里 40 个如此）：
    /// 用户进站点看到的应是**有内容**的第一个分类，而不是「请选择一个分类」空态。
    Map<String, Object?> emptyHomePayload() => {
      'class': [
        {'type_id': '1', 'type_name': '电影'},
        {'type_id': '2', 'type_name': '电视剧'},
      ],
      'list': const [],
      'page': 1,
      'pagecount': 1,
      'total': 0,
    };

    test('首页无 list → 自动加载并选中第一个分类', () async {
      await boot(
        handler: (uri, _) {
          final q = uri.queryParameters;
          if (!q.containsKey('t')) return emptyHomePayload();
          return _pagedCategoryPayload(q['t']!, 1);
        },
      );
      await state.loadHome(state.selectedSite!);

      expect(
        state.selectedTypeId,
        '1',
        reason: '应自动选中第一个分类，而不是停在空态',
      );
      expect(state.categoryResult!.list, isNotEmpty);
      expect(state.homeResult!.list, isEmpty, reason: '首页本身确实没有推荐内容');
    });

    test('首页有推荐内容时不抢占（不得替用户跳走）', () async {
      await boot(); // 默认 handler：首页带 1 条 list
      await state.loadHome(state.selectedSite!);

      expect(state.selectedTypeId, isNull, reason: '有推荐内容就应停在首页');
      expect(state.homeResult!.list, isNotEmpty);
    });

    test('首页无 list 且无分类 → 不发多余请求，停在空态', () async {
      await boot(
        handler: (uri, _) => {
          'class': const [],
          'list': const [],
          'page': 1,
          'pagecount': 1,
          'total': 0,
        },
      );
      client.requests.clear();
      await state.loadHome(state.selectedSite!);

      expect(state.selectedTypeId, isNull);
      expect(
        client.requests.where((u) => u.queryParameters.containsKey('t')),
        isEmpty,
        reason: '没有分类可选时不得发分类请求',
      );
    });
  });
}
