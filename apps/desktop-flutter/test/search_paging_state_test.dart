/// 搜索结果分页状态测试（移植自上游安卓「默影视」`SearchPageState.java`）。
///
/// 关键语义必须与上游一致（PC 端只用站点级分页，故去掉了上游「响应站点与请求
/// 站点不一致」的分支——PC 的翻页请求与响应天然同站点）：
/// - `pageCount == 0`（上游未声明页数）时允许一直翻；
/// - **内容指纹重复即判定该站点耗尽**（上游站点常见「越界页码返回末页」）；
/// - 空页不算接受、页码不推进，但**不**标耗尽（可能只是这一页为空）；
/// - 同一时刻只允许一个在途翻页请求。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/state/search_state.dart';

Vod _vod(String id, [String? name]) => Vod(vodId: id, vodName: name ?? '条目$id');

void main() {
  late SearchPagingState paging;

  setUp(() => paging = SearchPagingState());

  group('初始登记与可翻页判定', () {
    test('未登记的站点：第 1 页、页数未知、可继续翻', () {
      expect(paging.pageOf('s-a'), 1);
      expect(paging.pageCountOf('s-a'), 0);
      expect(paging.canLoadMore('s-a'), isTrue);
    });

    test('recordInitial 记录页数与指纹', () {
      paging.recordInitial('s-a', 3, SearchPagingState.pageTokenOf([_vod('1')]));
      expect(paging.pageOf('s-a'), 1);
      expect(paging.pageCountOf('s-a'), 3);
      expect(paging.canLoadMore('s-a'), isTrue);
    });

    test('已到达末页时不可再翻', () {
      paging.recordInitial('s-a', 1);
      expect(paging.canLoadMore('s-a'), isFalse);
    });

    test('页数未知（0）时仍可翻', () {
      paging.recordInitial('s-a', 0);
      expect(paging.canLoadMore('s-a'), isTrue);
    });

    test('非法站点 key 不参与分页（all / 空串）', () {
      paging.recordInitial('all', 5);
      paging.recordInitial('', 5);
      expect(paging.canLoadMore('all'), isFalse);
      expect(paging.canLoadMore(''), isFalse);
      expect(paging.begin('all', 2), isFalse);
    });

    test('页数只会变大，不会被后到的较小值缩小', () {
      paging.recordInitial('s-a', 5);
      paging.recordInitial('s-a', 2);
      expect(paging.pageCountOf('s-a'), 5);
    });
  });

  group('begin 的拒绝条件', () {
    test('请求页码必须是「当前页 + 1」', () {
      paging.recordInitial('s-a', 5);
      expect(paging.begin('s-a', 3), isFalse, reason: '跳页要拒绝');
      expect(paging.begin('s-a', 1), isFalse, reason: '重复当前页要拒绝');
      expect(paging.begin('s-a', 2), isTrue);
    });

    test('已有在途请求时拒绝重入', () {
      paging.recordInitial('s-a', 5);
      expect(paging.begin('s-a', 2), isTrue);
      expect(paging.hasPending, isTrue);
      expect(paging.isPending('s-a'), isTrue);
      expect(paging.begin('s-a', 2), isFalse, reason: '同一时刻只允许一个在途翻页');
    });

    test('不可续翻（已达末页 / 已耗尽）时拒绝', () {
      paging.recordInitial('s-a', 1);
      expect(paging.begin('s-a', 2), isFalse);
    });
  });

  group('complete 的接受与耗尽判定', () {
    test('无在途请求时 complete 不处理', () {
      final completion = paging.complete(hasItems: true, pageCount: 2);
      expect(completion.handled, isFalse);
      expect(completion.accepted, isFalse);
    });

    test('有条目 → 接受，页码推进', () {
      paging.recordInitial('s-a', 3);
      paging.begin('s-a', 2);
      final completion = paging.complete(
        hasItems: true,
        pageCount: 3,
        pageToken: SearchPagingState.pageTokenOf([_vod('2')]),
      );
      expect(completion.handled, isTrue);
      expect(completion.accepted, isTrue);
      expect(completion.page, 2);
      expect(paging.pageOf('s-a'), 2);
      expect(paging.canLoadMore('s-a'), isTrue, reason: '2 < 3 还能翻');
    });

    test('空页 → 不接受、页码不推进、不标耗尽（下次还能重试）', () {
      paging.recordInitial('s-a', 5);
      paging.begin('s-a', 2);
      final completion = paging.complete(hasItems: false, pageCount: 5);
      expect(completion.accepted, isFalse);
      expect(paging.pageOf('s-a'), 1, reason: '页码不推进');
      expect(paging.isExhausted('s-a'), isFalse, reason: '空页不等于耗尽');
      expect(paging.hasPending, isFalse);
    });

    test('内容与已见过的页重复 → 判该站点耗尽，之后不可再翻', () {
      final page1 = SearchPagingState.pageTokenOf([_vod('1'), _vod('2')]);
      paging.recordInitial('s-a', 0, page1);
      paging.begin('s-a', 2);
      // 上游越界页码返回末页：内容与第 1 页完全相同。
      final completion = paging.complete(
        hasItems: true,
        pageCount: 0,
        pageToken: page1,
      );
      expect(completion.repeated, isTrue);
      expect(completion.accepted, isFalse);
      expect(paging.isExhausted('s-a'), isTrue);
      expect(paging.canLoadMore('s-a'), isFalse, reason: '耗尽后必须停住');
      expect(paging.begin('s-a', 2), isFalse);
    });

    test('新内容不同则不算重复', () {
      paging.recordInitial(
        's-a',
        0,
        SearchPagingState.pageTokenOf([_vod('1')]),
      );
      paging.begin('s-a', 2);
      final completion = paging.complete(
        hasItems: true,
        pageCount: 0,
        pageToken: SearchPagingState.pageTokenOf([_vod('2')]),
      );
      expect(completion.accepted, isTrue);
      expect(completion.repeated, isFalse);
      expect(paging.isExhausted('s-a'), isFalse);
    });

    test('页数未知时会一直翻到内容重复为止（模拟上游无限翻页）', () {
      paging.recordInitial(
        's-a',
        0,
        SearchPagingState.pageTokenOf([_vod('1')]),
      );
      var page = 1;
      for (var round = 0; round < 5; round++) {
        expect(paging.canLoadMore('s-a'), isTrue);
        expect(paging.begin('s-a', page + 1), isTrue);
        page++;
        paging.complete(
          hasItems: true,
          pageCount: 0,
          pageToken: SearchPagingState.pageTokenOf([_vod('$page')]),
        );
      }
      expect(paging.pageOf('s-a'), 6);
      // 第 7 页返回与第 1 页相同的内容 → 耗尽，循环终止。
      expect(paging.begin('s-a', 7), isTrue);
      paging.complete(
        hasItems: true,
        pageCount: 0,
        pageToken: SearchPagingState.pageTokenOf([_vod('1')]),
      );
      expect(paging.canLoadMore('s-a'), isFalse);
      expect(paging.begin('s-a', 8), isFalse);
    });
  });

  group('shouldContinue（相似度过滤后自动续翻）', () {
    test('开启相似度 + 原始页有条目 + 过滤后无可见 → 续翻', () {
      paging.recordInitial('s-a', 5, 'p1');
      expect(
        paging.shouldContinue(
          's-a',
          precise: true,
          rawPageHasItems: true,
          visiblePageHasItems: false,
        ),
        isTrue,
      );
    });

    test('相似度为 0（不过滤）时不续翻', () {
      paging.recordInitial('s-a', 5);
      expect(
        paging.shouldContinue(
          's-a',
          precise: false,
          rawPageHasItems: true,
          visiblePageHasItems: false,
        ),
        isFalse,
      );
    });

    test('过滤后有可见结果时不续翻', () {
      paging.recordInitial('s-a', 5);
      expect(
        paging.shouldContinue(
          's-a',
          precise: true,
          rawPageHasItems: true,
          visiblePageHasItems: true,
        ),
        isFalse,
      );
    });

    test('原始页本身为空时不续翻（再翻也是白翻）', () {
      paging.recordInitial('s-a', 5);
      expect(
        paging.shouldContinue(
          's-a',
          precise: true,
          rawPageHasItems: false,
          visiblePageHasItems: false,
        ),
        isFalse,
      );
    });

    test('有在途请求或不可续翻时不续翻', () {
      paging.recordInitial('s-a', 5);
      paging.begin('s-a', 2);
      expect(
        paging.shouldContinue(
          's-a',
          precise: true,
          rawPageHasItems: true,
          visiblePageHasItems: false,
        ),
        isFalse,
        reason: '已有在途请求',
      );
      paging.cancelPending();
      paging.recordInitial('s-b', 1);
      expect(
        paging.shouldContinue(
          's-b',
          precise: true,
          rawPageHasItems: true,
          visiblePageHasItems: false,
        ),
        isFalse,
        reason: '已到末页',
      );
    });
  });

  group('页内容指纹', () {
    test('与条目顺序无关', () {
      final a = SearchPagingState.pageTokenOf([_vod('1'), _vod('2')]);
      final b = SearchPagingState.pageTokenOf([_vod('2'), _vod('1')]);
      expect(a, b);
      expect(a, isNotEmpty);
    });

    test('条目不同则指纹不同', () {
      expect(
        SearchPagingState.pageTokenOf([_vod('1')]),
        isNot(SearchPagingState.pageTokenOf([_vod('2')])),
      );
    });

    test('空列表指纹为空串', () {
      expect(SearchPagingState.pageTokenOf(const []), isEmpty);
    });

    test('id 相同名称不同也算不同条目', () {
      expect(
        SearchPagingState.pageTokenOf([_vod('1', '甲')]),
        isNot(SearchPagingState.pageTokenOf([_vod('1', '乙')])),
      );
    });
  });

  group('clear / cancelPending', () {
    test('clear 清空全部站点状态与在途登记', () {
      paging.recordInitial('s-a', 5, 'p1');
      paging.begin('s-a', 2);
      paging.clear();
      expect(paging.hasPending, isFalse);
      expect(paging.pageOf('s-a'), 1);
      expect(paging.pageCountOf('s-a'), 0);
      expect(paging.isExhausted('s-a'), isFalse);
    });

    test('cancelPending 之后该站点可以重新翻页', () {
      paging.recordInitial('s-a', 5);
      expect(paging.begin('s-a', 2), isTrue);
      paging.cancelPending();
      expect(paging.hasPending, isFalse);
      expect(paging.begin('s-a', 2), isTrue, reason: '取消后必须能重试');
    });
  });

  group('MultiSiteSearchOutcome', () {
    MultiSiteSearchOutcome outcomeWith(List<SiteSearchEntry> entries) =>
        MultiSiteSearchOutcome(
          runId: 1,
          keyword: '关键词',
          results: entries,
        );

    test('replaceEntry 保持站点顺序（谁先翻完页都不会重排）', () {
      final outcome = outcomeWith([
        SiteSearchEntry(siteKey: 's-a', siteName: '甲'),
        SiteSearchEntry(siteKey: 's-b', siteName: '乙'),
        SiteSearchEntry(siteKey: 's-c', siteName: '丙'),
      ]);
      outcome.replaceEntry(
        SiteSearchEntry(siteKey: 's-b', siteName: '乙', page: 2),
      );
      expect(outcome.results.map((e) => e.siteKey), ['s-a', 's-b', 's-c']);
      expect(outcome.entryOf('s-b')!.page, 2);
    });

    test('replaceEntry 对不存在的站点是空操作', () {
      final outcome = outcomeWith([
        SiteSearchEntry(siteKey: 's-a', siteName: '甲'),
      ]);
      outcome.replaceEntry(SiteSearchEntry(siteKey: 's-z', siteName: '新'));
      expect(outcome.results.length, 1);
      expect(outcome.entryOf('s-z'), isNull);
    });

    test('scoped 反映是否限定了范围', () {
      expect(outcomeWith(const []).scoped, isFalse);
      expect(
        MultiSiteSearchOutcome(
          runId: 1,
          keyword: 'k',
          results: const [],
          group: '盘',
        ).scoped,
        isTrue,
      );
      expect(
        MultiSiteSearchOutcome(
          runId: 1,
          keyword: 'k',
          results: const [],
          siteKey: 's-a',
        ).scoped,
        isTrue,
      );
    });

    test('totalItems 随翻页累加', () {
      final outcome = outcomeWith([
        SiteSearchEntry(
          siteKey: 's-a',
          siteName: '甲',
          result: SiteResult(list: [_vod('1')]),
        ),
      ]);
      expect(outcome.totalItems, 1);
      outcome.replaceEntry(
        SiteSearchEntry(
          siteKey: 's-a',
          siteName: '甲',
          page: 2,
          result: SiteResult(list: [_vod('1'), _vod('2')]),
        ),
      );
      expect(outcome.totalItems, 2);
    });
  });

  group('SiteSearchEntry.copyWith', () {
    test('保留未指定字段，只替换指定的', () {
      final entry = SiteSearchEntry(
        siteKey: 's-a',
        siteName: '甲站[盘]',
        groups: const ['盘'],
        result: SiteResult(list: [_vod('1')]),
        pageCount: 3,
        hasMore: true,
      );
      final updated = entry.copyWith(loadingMore: true, page: 2);
      expect(updated.siteKey, 's-a');
      expect(updated.siteName, '甲站[盘]');
      expect(updated.groups, ['盘']);
      expect(updated.result, isNotNull);
      expect(updated.pageCount, 3);
      expect(updated.hasMore, isTrue);
      expect(updated.loadingMore, isTrue);
      expect(updated.page, 2);
    });

    test('clearResult 可以显式清掉结果', () {
      final entry = SiteSearchEntry(
        siteKey: 's-a',
        siteName: '甲',
        result: SiteResult(list: [_vod('1')]),
      );
      expect(entry.copyWith(clearResult: true).result, isNull);
    });
  });
}
