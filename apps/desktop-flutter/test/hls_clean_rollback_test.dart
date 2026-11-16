import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ad_rules.dart';

void main() {
  const rules = AdRuleSet(adHosts: ['ads.example']);
  final playlist = Uri.parse('https://cdn.good/main.m3u8');
  HlsCleanResult clean(String text) =>
      cleanHlsPlaylist(text: text, playlistUri: playlist, rules: rules);
  String manifest(List<String> hosts, {bool ended = true}) {
    final body = hosts.indexed
        .map((entry) => '#EXTINF:10,\nhttps://${entry.$2}/${entry.$1}.ts\n')
        .join();
    return '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n$body'
        '${ended ? '#EXT-X-ENDLIST\n' : ''}';
  }

  test('超过一半的候选分片回退到完全相同的原文', () {
    final text = manifest([
      'ads.example',
      'ads.example',
      'ads.example',
      'cdn.good',
    ]);
    final result = clean(text);
    expect(result.text, text);
    expect(result.removedSegments, 0);
    expect(result.changed, isFalse);
  });
  test('全部候选被删时仍返回原文，不返回空媒体清单', () {
    final text = manifest(['ads.example', 'ads.example']);
    expect(clean(text).text, text);
    expect(clean(text).removedSegments, 0);
  });
  test('规则级恰好一半仍可删，清单全局标签与正片侧 KEY/MAP 保留', () {
    // KEY/MAP 写在**保留的**首个分片之前：它们属于正片，删广告不能带走。
    final text = manifest(['cdn.good', 'ads.example']).replaceFirst(
      '#EXTINF:10,',
      '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:10,',
    );
    final result = clean(text);
    expect(result.removedSegments, 1);
    expect(result.text.startsWith('#EXTM3U\n'), isTrue);
    expect(result.text, contains('#EXT-X-VERSION:3'));
    expect(result.text, contains('#EXT-X-TARGETDURATION:10'));
    expect(result.text, contains('#EXT-X-KEY:'));
    expect(result.text, contains('#EXT-X-MAP:'));
    expect(result.text, isNot(contains('ads.example')));
  });
  test('少量广告正常删，清洗结果的 EXTINF 与 URI 数一致', () {
    final result = clean(manifest(['cdn.good', 'ads.example', 'cdn.good']));
    expect(result.removedSegments, 1);
    expect(
      result.text
          .split('\n')
          .where((line) => line.startsWith('#EXTINF'))
          .length,
      2,
    );
    expect(result.text, isNot(contains('ads.example')));
  });
  test('直播滑动清单不清洗，即使规则命中', () {
    final text = manifest([
      'cdn.good',
      'ads.example',
      'cdn.good',
    ], ended: false);
    expect(clean(text).text, text);
    expect(clean(text).changed, isFalse);
  });
  test('主清单不能把 variant URI 当作分片删除', () {
    const text =
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nhttps://ads.example/v1.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200\nhttps://cdn.good/v2.m3u8\n';
    expect(clean(text).text, text);
  });
  test('EXTINF 中间隔着 KEY 也不能掩盖悬空分片', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good']).replaceFirst(
      '#EXTINF:10,',
      '#EXTINF:10,\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:10,',
    );
    expect(clean(text).text, text);
    expect(clean(text).changed, isFalse);
  });
  test('末尾悬空 EXTINF 后隔着注释仍必须回退', () {
    final text = manifest([
      'cdn.good',
      'ads.example',
      'cdn.good',
    ]).replaceFirst('#EXT-X-ENDLIST', '#EXTINF:10,\n# comment\n#EXT-X-ENDLIST');
    expect(clean(text).text, text);
    expect(clean(text).changed, isFalse);
  });
  test('AES-128 未声明 IV 时不能删分片改变媒体序号', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good']).replaceFirst(
      '#EXTINF:10,',
      '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:10,',
    );
    expect(clean(text).text, text);
    expect(clean(text).removedSegments, 0);
  });
  test('隐式 BYTERANGE 偏移依赖前一段时保留整个清单', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good'])
        .replaceAll('#EXTINF:10,', '#EXTINF:10,\n#EXT-X-BYTERANGE:100');
    expect(clean(text).text, text);
    expect(clean(text).removedSegments, 0);
  });

  test('SAMPLE-AES 隐式 IV 同样不能删分片', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good']).replaceFirst(
      '#EXTINF:10,',
      '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key"\n#EXTINF:10,',
    );
    expect(clean(text).text, text);
  });
  test('SAMPLE-AES-CTR 隐式 IV 也不能删分片', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good']).replaceFirst(
      '#EXTINF:10,',
      '#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI="skd://key"\n#EXTINF:10,',
    );
    expect(clean(text).text, text);
  });
  test('KEY 显式给 IV 时允许清洗（不能因保守把功能全关掉）', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good']).replaceFirst(
      '#EXTINF:10,',
      '#EXT-X-KEY:METHOD=AES-128,URI="k",IV=0x01\n#EXTINF:10,',
    );
    expect(clean(text).removedSegments, 1);
  });
  test('EXT-X-DEFINE 必须保留，否则后续 URI 模板无法解析', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good'])
        .replaceFirst(
          '#EXTM3U\n',
          '#EXTM3U\n#EXT-X-DEFINE:NAME="token",VALUE="123"\n',
        )
        .replaceFirst('https://cdn.good/0.ts', 'https://cdn.good/{\$token}.ts');
    final result = clean(text);
    expect(result.removedSegments, 1);
    expect(result.text, contains('#EXT-X-DEFINE:NAME="token",VALUE="123"'));
    expect(result.text, contains('{\$token}.ts'));
  });
  test('广告前的 DISCONTINUITY 不能一起删，否则相邻正片编码切换无标记', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good']).replaceFirst(
      '#EXTINF:10,\nhttps://ads.example/1.ts',
      '#EXT-X-DISCONTINUITY\n#EXTINF:10,\nhttps://ads.example/1.ts',
    );
    final result = clean(text);
    expect(result.removedSegments, 1);
    expect(result.text, contains('#EXT-X-DISCONTINUITY'));
  });
  test('I-FRAMES-ONLY / GAP 等持续生效标签保留', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good'])
        .replaceFirst('#EXTM3U\n', '#EXTM3U\n#EXT-X-I-FRAMES-ONLY\n')
        .replaceFirst(
          '#EXTINF:10,\nhttps://ads.example/1.ts',
          '#EXTINF:10,\n#EXT-X-GAP\nhttps://ads.example/1.ts',
        );
    final result = clean(text);
    expect(result.removedSegments, 1);
    expect(result.text, contains('#EXT-X-I-FRAMES-ONLY'));
    expect(result.text, contains('#EXT-X-GAP'));
  });
  test('广告分片自带 EXT-X-MAP 时放弃清洗', () {
    final text = manifest(['cdn.good', 'ads.example', 'cdn.good']).replaceFirst(
      '#EXTINF:10,\nhttps://ads.example/1.ts',
      '#EXT-X-MAP:URI="ad-init.mp4"\n#EXTINF:10,\nhttps://ads.example/1.ts',
    );
    final result = clean(text);
    expect(result.text, text);
    expect(result.removedSegments, 0);
  });
  test('带 UTF-8 BOM 的清单仍可清洗，且回写保留 BOM', () {
    final text = '\uFEFF${manifest(['cdn.good', 'ads.example', 'cdn.good'])}';
    final result = clean(text);
    expect(result.removedSegments, 1);
    expect(result.text.startsWith('\uFEFF'), isTrue);
  });

  test('没有匹配时字节语义原样保留', () {
    final text = manifest(['cdn.good']).replaceAll('\n', '\r\n');
    expect(clean(text).text, text);
  });
}
