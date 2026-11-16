/// 扫描结果模糊搜索的纯逻辑：多词 AND、分隔符不敏感、命中范围。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/local_spider_scanner.dart';
import 'package:webhtv_pc/ui/local_sources_page.dart';

LocalSourceCandidate _candidate({
  String key = 'cspdemo',
  String name = '演示源',
  String entryName = 'csp_demo.py',
  String absPath = r'D:\spiders\csp_demo.py',
  LocalSourceKind kind = LocalSourceKind.python,
}) => LocalSourceCandidate(
  kind: kind,
  absPath: absPath,
  sourceDir: r'D:\spiders',
  entryName: entryName,
  key: key,
  name: name,
  bytes: 10,
  sha256: 'x',
  modified: DateTime(2025),
);

void main() {
  test('空查询与纯空白查询都放行', () {
    expect(candidateMatchesQuery(_candidate(), ''), isTrue);
    expect(candidateMatchesQuery(_candidate(), '   '), isTrue);
  });

  test('名称、key、入口名、类型与路径都参与匹配', () {
    final candidate = _candidate();
    expect(candidateMatchesQuery(candidate, '演示'), isTrue);
    expect(candidateMatchesQuery(candidate, 'CSPDEMO'), isTrue);
    expect(candidateMatchesQuery(candidate, 'entry'), isFalse);
    expect(candidateMatchesQuery(candidate, 'python'), isTrue);
    expect(candidateMatchesQuery(candidate, ' spiders '), isTrue);
  });

  test('分隔符不敏感：csp_demo 与 cspdemo 互搜', () {
    final candidate = _candidate();
    expect(candidateMatchesQuery(candidate, 'csp_demo'), isTrue);
    expect(candidateMatchesQuery(candidate, 'csp demo'), isTrue);
    expect(candidateMatchesQuery(candidate, 'cspdemo'), isTrue);
    expect(
      candidateMatchesQuery(
        _candidate(key: 'cspDemo', entryName: 'x.js'),
        'csp-demo',
      ),
      isTrue,
    );
  });

  test('多词是 AND：任一没命中就不算匹配', () {
    final candidate = _candidate();
    expect(candidateMatchesQuery(candidate, 'csp demo'), isTrue);
    expect(candidateMatchesQuery(candidate, 'csp nope'), isFalse);
  });
}
