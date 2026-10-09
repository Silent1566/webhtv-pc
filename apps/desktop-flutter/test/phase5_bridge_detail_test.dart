/// Phase 5 · 桥接站点详情：`vod_tag: folder` 展开与 query 编码契约。
///
/// 两个**真实缺陷**（5559 真机实测，用户反馈"桥接过来的站点无法获取详情"）：
///
/// 1. **query 编码**：`Uri.replace(queryParameters:)` 把 `:` 编成 `%3A`，而网关
///    （NanoHTTPD）只解码路径、**不**解码 query 转义。实测同一站点同一 id：
///    - 冒号原样 → 插件收到 `atvp_detail:131925` → 返回 3 条；
///    - `%3A` → 插件收到 `atvp_detail%3A131925` → 返回空。
/// 2. **folder 语义**：网盘聚合站的分类只返回 `vod_tag: "folder"` 壳，必须用
///    `t=<vod_id>` 展开（插件第 1646 行会剥 `atvp_detail:` 前缀）；走 `ids=`
///    详情接口只会拿到空壳（`vod_name`/`vod_play_url` 均空）。
///    实测 170 个站点里 **93 个**共用 `spring.jar`，都走这条路径。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';

Site _site() => Site(
  key: 'bridge_site',
  name: '网盘聚合站',
  type: SiteType.jsonApiBase64Ext,
  api: 'http://127.0.0.1:19978/vod/api?key=bridge_site',
);

void main() {
  group('query 编码契约（TVBox 生态）', () {
    test('冒号不被百分号编码（网关不解码 query 转义）', () {
      final builder = HttpApiRequestBuilder(site: _site());
      final call = builder.build(
        HttpApiAction.detail,
        vodId: 'atvp_detail:131925',
      );
      expect(call.uri.query, contains('ids=atvp_detail:131925'));
      expect(
        call.uri.query,
        isNot(contains('%3A')),
        reason: '编码 %3A 会让插件收到字面量，startswith("atvp_detail:") 判断失败',
      );
    });

    test('逗号不被编码（ids 多值分隔符，VodApi.ids() 按逗号切分）', () {
      final builder = HttpApiRequestBuilder(site: _site());
      final call = builder.build(
        HttpApiAction.detail,
        vodId: 'atvp_detail:1,atvp_detail:2',
      );
      expect(call.uri.query, contains('ids=atvp_detail:1,atvp_detail:2'));
      expect(call.uri.query, isNot(contains('%2C')));
    });

    test('其他需要转义的字符仍正常编码（不因保留冒号而放宽）', () {
      final builder = HttpApiRequestBuilder(site: _site());
      final call = builder.build(
        HttpApiAction.search,
        keyword: 'a b&c=d',
      );
      final query = call.uri.query;
      expect(query, contains('wd=a'));
      // 空格与 & 必须被转义，否则会破坏 query 结构。
      expect(query, isNot(contains('a b&c=d')));
    });

    test('站点 api 自带的 query 参数被保留（不重建 URI）', () {
      final builder = HttpApiRequestBuilder(site: _site());
      final call = builder.build(
        HttpApiAction.category,
        typeId: '2',
        page: 1,
      );
      expect(call.uri.query, contains('key=bridge_site'));
      expect(call.uri.query, contains('t=2'));
      expect(call.uri.query, contains('pg=1'));
    });

    test('folder 展开走 t= 参数且冒号原样', () {
      final builder = HttpApiRequestBuilder(site: _site());
      final call = builder.build(
        HttpApiAction.category,
        typeId: 'atvp_detail:131925',
        page: 1,
      );
      expect(call.uri.query, contains('t=atvp_detail:131925'));
      expect(call.uri.query, isNot(contains('%3A')));
    });

    test('播放入口的 play= 分享链不被破坏（含 : 与 /）', () {
      final builder = HttpApiRequestBuilder(site: _site());
      final call = builder.buildBase64ExtPlayRequest(
        'https://pan.baidu.com/s/10VoZ5K',
        flag: '百度#玩偶哥哥',
      );
      expect(call.uri.query, contains('play=https:'));
      expect(call.uri.query, isNot(contains('play=https%3A')));
    });
  });

  group('vod_tag 解析（TVBox 约定）', () {
    test('folder 条目被识别为目录', () {
      final vod = Vod.fromJson({
        'vod_id': 'atvp_detail:131925',
        'vod_name': '爱在山海间',
        'vod_tag': 'folder',
      });
      expect(vod, isNotNull);
      expect(vod!.vodTag, 'folder');
      expect(vod.isFolder, isTrue);
    });

    test('file 条目不是目录（可直接播）', () {
      final vod = Vod.fromJson({
        'vod_id': 'https://pan.baidu.com/s/abc',
        'vod_name': '百度#玩偶哥哥',
        'vod_tag': 'file',
      });
      expect(vod!.vodTag, 'file');
      expect(vod.isFolder, isFalse);
    });

    test('无 vod_tag 的普通条目不是目录（不误判）', () {
      final vod = Vod.fromJson({
        'vod_id': 'demo-1',
        'vod_name': '普通影片',
        'vod_play_from': '线路一',
        'vod_play_url': '第1集\$http://h/1.m3u8',
      });
      expect(vod!.vodTag, isNull);
      expect(vod.isFolder, isFalse);
    });

    test('vod_tag 从 extra 提升为正式字段（不再混在未知字段里）', () {
      final vod = Vod.fromJson({
        'vod_id': 'v1',
        'vod_name': 'n',
        'vod_tag': 'folder',
      });
      expect(vod!.vodTag, 'folder');
      expect(
        vod.extra.containsKey('vod_tag'),
        isFalse,
        reason: '已建模的字段不应再留在 extra',
      );
    });

    test('camelCase 别名 vodTag 兼容', () {
      final vod = Vod.fromJson({
        'vodId': 'v1',
        'vodName': 'n',
        'vodTag': 'folder',
      });
      expect(vod!.isFolder, isTrue);
    });
  });
}
