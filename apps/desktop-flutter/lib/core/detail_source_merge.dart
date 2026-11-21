import 'protocol.dart';

/// Detail playback and identity remain authoritative; listing fills display gaps.
String? _fillDisplay(String? current, String? fallback) {
  if ((current ?? '').trim().isNotEmpty) return current;
  return (fallback ?? '').trim().isNotEmpty ? fallback : current;
}

Vod mergeSourceDetailDisplay({
  required Vod detail,
  required Vod listing,
  String? nameOverride,
  String? idOverride,
}) {
  final fill = _fillDisplay;
  final override = (nameOverride ?? '').trim();
  final id = (idOverride ?? '').trim();

  return Vod(
    // 推送的身份必须用**推送时的 id**：站源详情常把 https:// 去掉返回一个
    // 不同的 id，身份一变，TMDB 归属门就会判成"换片"并清空已匹配的数据。
    vodId: id.isEmpty ? detail.vodId : id,
    // 片名优先用调用方指定的（推送的手填剧名），详情返回的名字只在没指定时生效。
    vodName: override.isEmpty ? detail.vodName : override,
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
