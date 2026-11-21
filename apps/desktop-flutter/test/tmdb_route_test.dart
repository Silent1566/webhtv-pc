/// TMDB 内置线路（`docs/phase4/design/03` §5.6）。
///
/// 覆盖：内置预设经 `sanitize()` 后的形态、线路匹配、用户手打地址归一、
/// 线路探测地址（官方 / 路径式反代 / wsrv 查询式代理）、后景跟随图片线路。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_route.dart';

void main() {
  group('内置线路经 sanitize() 后的形态', () {
    test('API 线路一律落到以 /3 结尾的基址（自动是语义值，不拼地址）', () {
      for (final option in tmdbApiRoutes.where((o) => o.value != tmdbAutoRoute)) {
        expect(
          TmdbConfig(apiBase: option.value).sanitize().apiBase,
          '${option.value}/3',
          reason: '预设 ${option.label} 必须是可直接使用的 API 基址',
        );
      }
    });

    test('图片线路一律落到 /t/p/w342，且后景是同线路的 w1280（自动除外）', () {
      for (final option in tmdbImageRoutes.where(
        (o) => o.value != tmdbAutoRoute,
      )) {
        final config = TmdbConfig().withImageRoute(option.value);
        expect(
          config.imageBase,
          endsWith('/t/p/w342'),
          reason: '预设 ${option.label} 的海报基址',
        );
        expect(
          config.backdropBase,
          endsWith('/t/p/w1280'),
          reason: '预设 ${option.label} 的后景必须同线路',
        );
        expect(
          tmdbImageRouteKey(config.backdropBase),
          tmdbImageRouteKey(config.imageBase),
          reason: '后景与海报必须落在同一个主机（反代/代理都是普通地址拼接）',
        );
      }
    });

    test('反代线路保留用户给的目标地址，不额外拆分成新域名', () {
      final config = TmdbConfig().withImageRoute(
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org',
      );
      expect(
        config.imageBase,
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342',
      );
      expect(
        config.backdropBase,
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w1280',
      );
    });

    test('wsrv.nl 的目标地址放在 url 参数里，尺寸段接在目标地址之后', () {
      final config = TmdbConfig().withImageRoute(
        'https://wsrv.nl/?url=https://image.tmdb.org',
      );
      expect(
        config.imageBase,
        'https://wsrv.nl/?url=https://image.tmdb.org/t/p/w342',
      );
      expect(
        config.backdropBase,
        'https://wsrv.nl/?url=https://image.tmdb.org/t/p/w1280',
      );
    });
  });

  group('线路匹配', () {
    test('官方与别名域名都算官方线路', () {
      expect(
        tmdbApiRouteOf('https://api.tmdb.org/3')?.value,
        'https://api.tmdb.org',
      );
      expect(
        tmdbApiRouteOf('https://api.themoviedb.org/3')?.value,
        'https://api.themoviedb.org',
      );
    });

    test('尺寸与 /t/p 尾巴不影响图片线路匹配', () {
      for (final base in const [
        'https://images.tmdb.org',
        'https://images.tmdb.org/t/p',
        'https://images.tmdb.org/t/p/w342',
        'https://images.tmdb.org/t/p/w780',
      ]) {
        expect(
          tmdbImageRouteOf(base)?.value,
          'https://images.tmdb.org',
          reason: base,
        );
      }
    });

    test('反代与 wsrv 各自命中自己的预设', () {
      expect(
        tmdbImageRouteOf(
          'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342',
        )?.label,
        contains('jsnzkpg4.pages.dev'),
      );
      expect(
        tmdbImageRouteOf('https://wsrv.nl/?url=https://image.tmdb.org/t/p/w342')
            ?.label,
        contains('wsrv.nl'),
      );
    });

    test('自定义地址不命中任何预设', () {
      expect(tmdbApiRouteOf('https://my.mirror/3'), isNull);
      expect(tmdbImageRouteOf('https://my.mirror/t/p/w342'), isNull);
      expect(tmdbImageRouteOf(''), isNull);
      expect(tmdbApiRouteOf(''), isNull);
    });

    test('http 与 https 是两条线路，不做等价归一', () {
      expect(tmdbImageRouteOf('http://images.tmdb.org/t/p/w342'), isNull);
    });
  });

  group('用户手打地址（参考安卓的归一语义）', () {
    test('http 官方域名照原样保留协议并补 /3、/t/p/w342', () {
      expect(
        TmdbConfig(apiBase: 'http://api.tmdb.org').sanitize().apiBase,
        'http://api.tmdb.org/3',
      );
      expect(
        TmdbConfig().withImageRoute('http://images.tmdb.org/t/p').imageBase,
        'http://images.tmdb.org/t/p/w342',
      );
    });

    test('反代地址带不带末尾斜杠、带不带尺寸都归一到同一形态', () {
      for (final input in const [
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/',
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p',
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342',
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org/',
      ]) {
        expect(
          TmdbConfig().withImageRoute(input).imageBase,
          'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342',
          reason: input,
        );
      }
    });

    test('不带协议的图片主机也能补全（与 apiBase 同一套 looksLikeHost 语义）', () {
      expect(
        TmdbConfig().withImageRoute('images.tmdb.org').imageBase,
        'https://images.tmdb.org/t/p/w342',
      );
    });
  });

  group('后景跟随图片线路（规则 15）', () {
    test('图片线路换成反代后，官方默认后景一并跟随', () {
      final config = const TmdbConfig(
        imageBase: 'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342',
        backdropBase: 'https://images.tmdb.org/t/p/w1280',
      ).sanitize();
      expect(
        config.backdropBase,
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w1280',
      );
    });

    test('图片线路是官方时后景保持原样（规则 14 的自选尺寸不被改）', () {
      final config = const TmdbConfig(
        imageBase: 'https://images.tmdb.org/t/p/w342',
        backdropBase: 'https://images.tmdb.org/t/p/original',
      ).sanitize();
      expect(config.backdropBase, 'https://images.tmdb.org/t/p/original');
    });

    test('用户显式指定的自建后景不被跟随覆盖', () {
      final config = const TmdbConfig(
        imageBase: 'https://images.tmdb.org/t/p/w342',
        backdropBase: 'https://my.mirror/t/p/w780',
      ).sanitize();
      expect(config.backdropBase, 'https://my.mirror/t/p/w780');
    });

    test('切回官方线路时后景回到官方 w1280', () {
      final proxied = TmdbConfig().withImageRoute(
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org',
      );
      final back = proxied.withImageRoute('https://images.tmdb.org');
      expect(back.imageBase, 'https://images.tmdb.org/t/p/w342');
      expect(back.backdropBase, 'https://images.tmdb.org/t/p/w1280');
    });
  });

  group('线路探测地址', () {
    test('官方图床', () {
      expect(
        tmdbImageProbeUrl('https://images.tmdb.org/t/p/w342'),
        'https://images.tmdb.org$tmdbImageProbePath',
      );
    });

    test('路径式反代', () {
      expect(
        tmdbImageProbeUrl(
          'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342',
        ),
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org$tmdbImageProbePath',
      );
    });

    test('wsrv 查询式代理', () {
      expect(
        tmdbImageProbeUrl('https://wsrv.nl/?url=https://image.tmdb.org/t/p/w342'),
        'https://wsrv.nl/?url=https://image.tmdb.org$tmdbImageProbePath',
      );
    });

    test('空地址不拼出半截 URL', () {
      expect(tmdbImageProbeUrl(''), '');
    });
  });

  group('探测结论句', () {
    test('成功时报出状态码、体积与耗时', () {
      const probe = TmdbImageProbe(
        url: 'https://images.tmdb.org/t/p/w342/x.jpg',
        statusCode: 200,
        bytes: 38425,
        elapsed: Duration(milliseconds: 1234),
      );
      final summary = tmdbImageProbeSummary(probe);
      expect(summary, contains('images.tmdb.org'));
      expect(summary, contains('HTTP 200'));
      expect(summary, contains('37.5 KB'));
      expect(summary, contains('1.23s'));
    });

    test('拿不到响应时说明原因', () {
      const probe = TmdbImageProbe(
        url: 'https://wsrv.nl/?url=https://image.tmdb.org/t/p/w342/x.jpg',
        statusCode: 0,
        bytes: 0,
        elapsed: Duration(milliseconds: 2000),
        error: 'TMDB 请求超时',
      );
      final summary = tmdbImageProbeSummary(probe);
      expect(summary, contains('wsrv.nl'));
      expect(summary, contains('不可用'));
      expect(summary, contains('TMDB 请求超时'));
    });

    test('线路为空时不编造主机名', () {
      const probe = TmdbImageProbe(
        url: '',
        statusCode: 0,
        bytes: 0,
        elapsed: Duration.zero,
        error: '图片线路为空',
      );
      expect(tmdbImageProbeSummary(probe), startsWith('图片线路 不可用'));
    });
  });

  group('自动线路（auto）', () {
    test('配置里的 auto 原样保留，不被当成主机名拼接', () {
      final api = const TmdbConfig(apiBase: 'auto').sanitize();
      expect(api.apiBase, 'auto');
      expect(api.apiHost, 'auto');

      final image = const TmdbConfig(imageBase: 'auto').sanitize();
      expect(image.imageBase, 'auto');
      expect(image.backdropBase, 'auto');
      expect(image.imageHost, 'auto');
    });

    test('withImageRoute(auto) 让海报与后景一起进自动', () {
      final config = const TmdbConfig().withImageRoute('auto');
      expect(config.imageBase, 'auto');
      expect(config.backdropBase, 'auto');
      expect(config.withImageRoute('https://images.tmdb.org').imageBase,
          'https://images.tmdb.org/t/p/w342');
    });

    test('自动值能往返 JSON', () {
      final back = TmdbConfig.fromMap(
        const TmdbConfig(apiBase: 'auto', imageBase: 'auto').toJson(),
      );
      expect(back.apiBase, 'auto');
      expect(back.imageBase, 'auto');
    });

    test('两个下拉里自动都是第一项', () {
      expect(tmdbApiRoutes.first.value, 'auto');
      expect(tmdbImageRoutes.first.value, 'auto');
      expect(tmdbApiRouteOf('auto')?.value, 'auto');
      expect(tmdbImageRouteOf('auto')?.value, 'auto');
      expect(tmdbApiRoutes.first.label, contains('自动'));
      expect(tmdbImageRoutes.first.label, contains('自动'));
    });

    test('候选都能归一成可直接使用的基址', () {
      for (final route in tmdbApiAutoCandidates) {
        expect(tmdbApiBaseOf(route), endsWith('/3'), reason: route);
      }
      for (final route in tmdbImageAutoCandidates) {
        expect(tmdbImageBaseOf(route, 'w342'), endsWith('/t/p/w342'), reason: route);
      }
      expect(tmdbAutoRoute, 'auto');
    });

    test('官方线路的标签里写明域名（用户要能确认自己选的是谁）', () {
      final labels = {...tmdbApiRoutes, ...tmdbImageRoutes}.map((o) => o.label).toList();
      for (final domain in const [
        'api.tmdb.org',
        'api.themoviedb.org',
        'images.tmdb.org',
        'image.tmdb.org',
        'jsnzkpg4.pages.dev',
        'wsrv.nl',
      ]) {
        expect(labels.any((label) => label.contains(domain)), isTrue, reason: domain);
      }
    });

    test('从图片 URL 反查候选线路', () {
      expect(
        tmdbImageRouteOfUrl(
          'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342/x.jpg',
          tmdbImageAutoCandidates,
        ),
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org',
      );
      expect(
        tmdbImageRouteOfUrl(
          'https://wsrv.nl/?url=https://image.tmdb.org/t/p/w342/x.jpg',
          tmdbImageAutoCandidates,
        ),
        'https://wsrv.nl/?url=https://image.tmdb.org',
      );
      expect(
        tmdbImageRouteOfUrl('https://other.test/x.jpg', tmdbImageAutoCandidates),
        isNull,
      );
    });

    test('自动线路不可直接探测（没有具体地址）', () {
      expect(tmdbImageProbeUrl('auto'), '');
    });
  });
}
