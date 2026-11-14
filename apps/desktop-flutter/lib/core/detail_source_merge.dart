import 'protocol.dart';

/// Detail playback and identity remain authoritative; listing fills display gaps.
String? _fillDisplay(String? current, String? fallback) {
  if ((current ?? '').trim().isNotEmpty) return current;
  return (fallback ?? '').trim().isNotEmpty ? fallback : current;
}

Vod mergeSourceDetailDisplay({required Vod detail, required Vod listing}) {
  final fill = _fillDisplay;

  return Vod(
    vodId: detail.vodId,
    vodName: detail.vodName,
    vodContent: fill(detail.vodContent, listing.vodContent),
    vodPic: fill(detail.vodPic, listing.vodPic),
    vodRemarks: fill(detail.vodRemarks, listing.vodRemarks),
    vodYear: fill(detail.vodYear, listing.vodYear),
    vodArea: fill(detail.vodArea, listing.vodArea),
    vodDirector: fill(detail.vodDirector, listing.vodDirector),
    vodActor: fill(detail.vodActor, listing.vodActor),
    vodPlayFrom: detail.vodPlayFrom,
    vodPlayUrl: detail.vodPlayUrl,
    vodTag: detail.vodTag,
    extra: detail.extra,
  );
}

/// Folder parents keep identity/play facts; resolved children fill display gaps.
Vod mergeFolderDisplay({required Vod parent, required Iterable<Vod> entries}) {
  var content = parent.vodContent;
  var pic = parent.vodPic;
  var remarks = parent.vodRemarks;
  var year = parent.vodYear;
  var area = parent.vodArea;
  var director = parent.vodDirector;
  var actor = parent.vodActor;
  for (final entry in entries) {
    content = _fillDisplay(content, entry.vodContent);
    pic = _fillDisplay(pic, entry.vodPic);
    remarks = _fillDisplay(remarks, entry.vodRemarks);
    year = _fillDisplay(year, entry.vodYear);
    area = _fillDisplay(area, entry.vodArea);
    director = _fillDisplay(director, entry.vodDirector);
    actor = _fillDisplay(actor, entry.vodActor);
  }
  return Vod(
    vodId: parent.vodId,
    vodName: parent.vodName,
    vodContent: content,
    vodPic: pic,
    vodRemarks: remarks,
    vodYear: year,
    vodArea: area,
    vodDirector: director,
    vodActor: actor,
    vodPlayFrom: parent.vodPlayFrom,
    vodPlayUrl: parent.vodPlayUrl,
    vodTag: parent.vodTag,
    extra: parent.extra,
  );
}
