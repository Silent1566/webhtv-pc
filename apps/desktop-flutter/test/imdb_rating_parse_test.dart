import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/imdb_rating.dart';

void main() {
  group('parseImdbTitlePage', () {
    test('JSON-LD aggregateRating 取到分值与人气', () {
      const html = '''
<html><head><script type="application/ld+json">
{"@context":"https://schema.org","@type":"Movie","name":"X",
 "aggregateRating":{"@type":"AggregateRating","ratingValue":8.1,"ratingCount":12345}}
</script></head><body></body></html>''';
      final rating = parseImdbTitlePage(html);
      expect(rating.value, '8.1');
      expect(rating.votes, '12,345');
    });

    test('JSON-LD 里的字符串分值同样可用', () {
      const html =
          '{"aggregateRating":{"ratingValue":"7.4","ratingCount":"70773"}}';
      final rating = parseImdbTitlePage(html);
      expect(rating.value, '7.4');
      expect(rating.votes, '70,773');
    });

    test('没有 JSON-LD 时退到内嵌 ratingsSummary', () {
      const html =
          '{"data":{"title":{"ratingsSummary":{"aggregateRating":6.5,"voteCount":998}}}}';
      final rating = parseImdbTitlePage(html);
      expect(rating.value, '6.5');
      expect(rating.votes, '998');
    });

    test('字符串里的花括号不会截断对象', () {
      const html =
          '{"aggregateRating":{"note":"weird { brace","ratingValue":9.0,"ratingCount":1000}}';
      final rating = parseImdbTitlePage(html);
      expect(rating.value, '9.0');
      expect(rating.votes, '1,000');
    });

    test('分值越界或缺失时返回空值', () {
      expect(
        parseImdbTitlePage('{"aggregateRating":{"ratingValue":0}}').isEmpty,
        isTrue,
      );
      expect(
        parseImdbTitlePage('{"aggregateRating":{"ratingValue":11.2}}').isEmpty,
        isTrue,
      );
      expect(
        parseImdbTitlePage('{"aggregateRating":{"popularity":3}}').isEmpty,
        isTrue,
      );
    });

    test('不把非法数字前缀当作有效评分', () {
      for (final value in ['8.1oops', '8.1.2', '8e2']) {
        expect(
          parseImdbTitlePage('{"aggregateRating":{"ratingValue":"$value"}}')
              .isEmpty,
          isTrue,
        );
      }
    });

    test('null 评分对象不会借用下一个无关对象', () {
      expect(
        parseImdbTitlePage(
          '{"aggregateRating":null,"unrelated":{"ratingValue":8.5}}',
        ).isEmpty,
        isTrue,
      );
    });

    test('空页面与乱码页面不抛异常', () {
      expect(parseImdbTitlePage('').isEmpty, isTrue);
      expect(parseImdbTitlePage('   ').isEmpty, isTrue);
      expect(parseImdbTitlePage('<html>forbidden</html>').isEmpty, isTrue);
      expect(parseImdbTitlePage('{"aggregateRating":').isEmpty, isTrue);
    });

    test('只有人气没有分值时保留分值为空', () {
      const html = '{"aggregateRating":{"@type":"AggregateRating"}}';
      expect(parseImdbTitlePage(html).isEmpty, isTrue);
    });
  });

  group('parseImdbGraphqlRating', () {
    test('ratingsSummary 取到分值与投票数', () {
      final rating = parseImdbGraphqlRating({
        'data': {
          'title': {
            'ratingsSummary': {'aggregateRating': 7.6, 'voteCount': 1234},
          },
        },
      });
      expect(rating.value, '7.6');
      expect(rating.votes, '1,234');
    });

    test('字符串数字同样可用', () {
      final rating = parseImdbGraphqlRating({
        'data': {
          'title': {
            'ratingsSummary': {'aggregateRating': '8.0', 'voteCount': '90000'},
          },
        },
      });
      expect(rating.value, '8.0');
      expect(rating.votes, '90,000');
    });

    test('null 分值、缺字段、错误响应都退化为空值', () {
      expect(
        parseImdbGraphqlRating({
          'data': {
            'title': {
              'ratingsSummary': {'aggregateRating': null, 'voteCount': 10},
            },
          },
        }).isEmpty,
        isTrue,
      );
      expect(
        parseImdbGraphqlRating({
          'errors': ['boom'],
        }).isEmpty,
        isTrue,
      );
      expect(
        parseImdbGraphqlRating({
          'data': {'title': null},
        }).isEmpty,
        isTrue,
      );
      expect(parseImdbGraphqlRating(null).isEmpty, isTrue);
      expect(parseImdbGraphqlRating('nope').isEmpty, isTrue);
    });
  });
}
