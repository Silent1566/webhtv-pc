class ViewingMetadata {
  const ViewingMetadata({
    this.genres = const [],
    this.areas = const [],
    this.actors = const [],
    this.directors = const [],
    this.mediaType = '',
  });

  final List<String> genres, areas, actors, directors;
  final String mediaType;
}
