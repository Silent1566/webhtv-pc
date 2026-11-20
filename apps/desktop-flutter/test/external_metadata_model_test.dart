import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/external_detail_meta.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/person_work_filters.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';

MetaCandidate candidate(int id, String title, {String original = '', int year = 2024}) => MetaCandidate(
  identity: MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, id)!,
  title: title, originalTitle: original, year: year,
);

void main() {
  test('missing external fields use source data while title follows configured default priority', () {
    final value = ExternalDetailMeta.douban(
      identity: MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, 1)!,
      subject: {'title':'外部标题'},
    )!;
    final merged = value.forSource(Vod(vodId:'video', vodName:'来源标题', vodContent:'来源简介',
      vodPic:'https://img.example/source.jpg', vodActor:'来源演员', vodDirector:'来源导演',
      vodYear:'2024', vodArea:'中国大陆', extra:{'vod_lang':'汉语普通话','type_name':'剧情'}));
    expect(merged.title, '外部标题');
    expect(merged.overview, '来源简介');
    expect(merged.posterUrl, 'https://img.example/source.jpg');
    expect(merged.cast.single.name, '来源演员');
    expect(merged.directors, ['来源导演']);
    expect(merged.languages, ['汉语普通话']);
  });
  test('确定性跨源映射凭据：IMDb 编号从两家各自的载荷里取到', () {
    final bangumi = ExternalDetailMeta.bangumi(
      identity: MetaIdentity.of(MetaSourceKind.bangumi, TmdbMediaType.tv, 187187)!,
      subject: {'name_cn': '怪奇物语', 'infobox': [
        {'key': 'imdb_id', 'value': 'tt4574334'},
        {'key': '导演', 'value': 'Shawn Levy'}]},
    )!;
    expect(bangumi.imdbId, 'tt4574334');

    final douban = ExternalDetailMeta.douban(
      identity: MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, 1)!,
      subject: {'title': '怪奇物语', 'imdb': 'tt4574334'},
    )!;
    expect(douban.imdbId, 'tt4574334');

    // 形状不对就不认：不能把随便一串字符当 IMDb 编号去做确定性映射。
    final bogus = ExternalDetailMeta.bangumi(
      identity: MetaIdentity.of(MetaSourceKind.bangumi, TmdbMediaType.tv, 2)!,
      subject: {'name_cn': '无编号', 'infobox': [{'key': 'imdb_id', 'value': 'n/a'}]},
    )!;
    expect(bogus.imdbId, isEmpty);
  });

  test('another season is rejected even when original title and year match', () {
    expect(MetaMatchRules.choose([candidate(1, '怪奇物语 第一季', original: 'Stranger Things')],
      query: const MetaQuery(title: '怪奇物语 第二季', aliases: ['Stranger Things'], year: 2024)), isNull);
  });
  test('the same identity appearing twice is not an ambiguous match', () {
    expect(MetaMatchRules.choose([candidate(1, '繁花'), candidate(1, '繁花')],
      query: const MetaQuery(title: '繁花', year: 2024))?.identity.id, 1);
  });
  test('search strips quality noise rather than sending a release filename', () {
    expect(const MetaQuery(title: '繁花 1080p').queries.first, '繁花');
  });
  test('a director is not cast just because their occupations include actor', () {
    final value = ExternalDetailMeta.douban(
      identity: MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, 26359270)!,
      subject: {'title': '怪奇物语', 'intro': '介绍', 'rating': {'value': 9.1},
        'pubdate': ['2016-07-15(美国)'], 'durations': ['50分钟'],
        'cover': {'url': 'https://img.example/poster.jpg'}},
      credits: [
        {'id': '1289935', 'name': '肖恩·利维', 'character': '导演 Director',
         'roles': ['导演', '制片人', '演员', '编剧'], 'avatar': {'large': 'https://img.example/director.jpg'}},
        {'id': '1051526', 'name': '范伟', 'character': '演员 Actor (饰 王响)',
         'roles': ['演员', '配音'], 'avatar': {'large': 'https://img.example/actor.jpg'}},
      ],
    )!;
    expect(value.data.cast.map((p) => p.name), ['范伟']);
    expect(value.data.crew.single.name, '肖恩·利维');
    expect(value.data.cast.single.subtitle, '王响');
    expect(value.data.crew.single.subtitle, '导演');
    expect(value.data.releaseDate, '2016-07-15');
    expect(value.data.ratingLabel, '豆瓣 9.1');
  });
  test('nested movie covers and filmography posters remain visible', () {
    final value = ExternalDetailMeta.douban(
      identity: MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.movie, 1)!,
      subject: {'title':'电影', 'cover': {'large': {'url':'https://img.example/movie.jpg'}}},
    )!;
    expect(value.data.posterUrl, 'https://img.example/movie.jpg');
    final person = ExternalPersonMeta.douban(
      ref: const MetaPersonRef(kind:MetaSourceKind.douban, id:1051526),
      celebrity: {'title':'范伟', 'cover':{'large':{'url':'https://img.example/person.jpg'}},
        'extra':{'info':[['性别','男'], ['出生日期','1962年9月2日'], ['出生地','中国,辽宁,沈阳']]}},
      works: [
        {'roles':['演员 (饰 王响)'], 'work':{'id':'35588177','title':'漫长的季节','type':'tv','year':'2023',
          'rating':{'value':9.4},'pic':{'normal':'https://img.example/work.jpg'}}},
        {'roles':['演员'], 'work':{'id':'2997297','title':'马大帅','type':'tv','year':'2004'}},
      ],
    )!;
    expect(person.department, contains('1962年9月2日'));
    expect(person.castWorks.first.item.posterUrl, 'https://img.example/work.jpg');
    expect(person.castWorks.first.character, '王响');
    expect(person.castWorks.every((w) => w.item.identity == null), isTrue);
    expect(PersonWorkFilters.from(person.castWorks, person.crewWorks).all.length, 2);
  });
  test('unknown Bangumi eps does not hide total episodes or infobox cast', () {
    final value = ExternalDetailMeta.bangumi(
      identity: MetaIdentity.of(MetaSourceKind.bangumi, TmdbMediaType.tv, 431299)!,
      subject: {'name_cn':'漫长的季节', 'name':'The Long Season', 'eps':0, 'total_episodes':12,
        'infobox': [{'key':'主演','value':'范伟 / 秦昊'}, {'key':'导演','value':'辛爽'},
                    {'key':'每集长','value':'50分钟'}]},
    )!;
    expect(value.data.episodeCount, 12);
    expect(value.data.cast.map((p)=>p.name), ['范伟','秦昊']);
  });
}
