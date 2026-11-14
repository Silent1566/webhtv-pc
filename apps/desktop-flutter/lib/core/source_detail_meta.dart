import 'protocol.dart';
import 'tmdb_detail_model.dart';
import 'tmdb_media.dart';

/// Builds display-only metadata from a source detail Vod when TMDB is absent.
TmdbDetailData sourceDetailMeta(Vod vod) {
  final typeGenres = _split(vod.extra['type_name']);
  final genres = typeGenres.isEmpty
      ? _split(vod.extra['vod_class'])
      : typeGenres;
  final directorNames = _split(vod.vodDirector, cap: 20);
  final actors = _split(vod.vodActor, cap: 20);
  final directorPeople = <TmdbPerson>[
    for (var index = 0; index < directorNames.length; index++)
      TmdbPerson(
        personId: -1001 - index,
        name: directorNames[index],
        subtitle: '导演',
      ),
  ];
  final cast = <TmdbPerson>[
    for (var index = 0; index < actors.length; index++)
      TmdbPerson(personId: -1 - index, name: actors[index], subtitle: '演员'),
  ];
  final poster = vod.vodPic;
  return TmdbDetailData(
    title: vod.vodName,
    overview: vod.vodContent,
    posterUrl: poster,
    backdropUrls: [if ((poster ?? '').trim().isNotEmpty) poster!],
    cast: cast,
    creatorTeam: directorPeople,
    directors: directorNames,
    genres: genres.length > 3 ? genres.sublist(0, 3) : genres,
    countries: _split(vod.vodArea),
    languages: _split(vod.extra['vod_lang']),
    rating: 0,
    releaseDate: (vod.vodYear ?? '').trim(),
  );
}

List<String> _split(Object? value, {int cap = 0}) {
  if (value is! String) return const [];
  final result = <String>[];
  for (final part in value.split(RegExp(r'[,，/、|]'))) {
    final text = part.trim();
    if (text.isEmpty || result.contains(text)) continue;
    result.add(text);
    if (cap > 0 && result.length >= cap) break;
  }
  return result;
}
