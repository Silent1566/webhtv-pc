/// Pure DASH rewrite contract: namespace, escaping, templates and DRM stay intact.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/dash_playlist.dart';
import 'package:xml/xml.dart';

void main() {
  const base = 'http://guest.local:5000/path/manifest.mpd';

  test('relative base and absolute templates remain player-expandable', () {
    const body =
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">'
        '<BaseURL>dash/</BaseURL>'
        r'<Period><SegmentTemplate media="seg-$Number$.m4s" '
        r'initialization="init-$RepresentationID$.mp4"/>'
        r'<SegmentTemplate media="http://guest.local:5000/abs/seg-$Number$.m4s?token=$Number$"/>'
        '</Period></MPD>';
    final rewritten = DashPlaylistRewriter.rewrite(
      body,
      baseUri: Uri.parse(base),
      childUrl: (target) => 'CHILD($target)',
      directoryUrl: (target) => 'DIR($target)/',
    );
    final document = XmlDocument.parse(rewritten);
    expect(document.rootElement.namespaceUri, 'urn:mpeg:dash:schema:mpd:2011');
    expect(
      document.findAllElements('BaseURL').single.innerText,
      r'DIR(http://guest.local:5000/path/dash/)/',
    );
    final templates = document
        .findAllElements('SegmentTemplate')
        .map((element) => element.getAttribute('media')!)
        .toList();
    expect(
      templates.first,
      r'DIR(http://guest.local:5000/path/dash/)/seg-$Number$.m4s',
    );
    expect(
      templates.last,
      r'DIR(http://guest.local:5000/abs/)/seg-$Number$.m4s?token=$Number$',
    );
  });

  test('XML escaping and DRM payload are preserved', () {
    const body =
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" '
        'xmlns:cenc="urn:mpeg:cenc:2013">'
        '<Period><SegmentURL media="seg.m4s?a=1&amp;b=2"/>'
        '<ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011">'
        '<cenc:pssh>ABC&amp;DEF</cenc:pssh></ContentProtection>'
        '</Period></MPD>';
    final rewritten = DashPlaylistRewriter.rewrite(
      body,
      baseUri: Uri.parse(base),
      childUrl: (target) => 'CHILD($target)',
      directoryUrl: (target) => 'DIR($target)/',
    );
    final document = XmlDocument.parse(rewritten);
    expect(
      document.findAllElements('SegmentURL').single.getAttribute('media'),
      'CHILD(http://guest.local:5000/path/seg.m4s?a=1&b=2)',
    );
    expect(
      document
          .findAllElements('ContentProtection')
          .single
          .getAttribute('schemeIdUri'),
      'urn:mpeg:dash:mp4protection:2011',
    );
    expect(
      document.descendants
          .whereType<XmlElement>()
          .singleWhere((element) => element.name.local == 'pssh')
          .innerText,
      'ABC&DEF',
    );
  });

  test('sibling BaseURL alternatives share the parent scope', () {
    const body =
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">'
        '<BaseURL serviceLocation="a">a/</BaseURL>'
        '<BaseURL serviceLocation="b">b/</BaseURL>'
        r'<Period><SegmentTemplate media="seg-$Number$.m4s"/></Period>'
        '</MPD>';
    final rewritten = DashPlaylistRewriter.rewrite(
      body,
      baseUri: Uri.parse(base),
      childUrl: (target) => 'CHILD($target)',
      directoryUrl: (target) => 'DIR($target)/',
    );
    final document = XmlDocument.parse(rewritten);
    expect(
      document.findAllElements('BaseURL').map((element) => element.innerText),
      <String>[
        'DIR(http://guest.local:5000/path/a/)/',
        'DIR(http://guest.local:5000/path/b/)/',
      ],
    );
    expect(
      document.findAllElements('SegmentTemplate').single.getAttribute('media'),
      r'seg-$Number$.m4s',
      reason: 'ambiguous alternatives must not select one arbitrary base',
    );
  });

  test('file BaseURL resolves relative children against its directory', () {
    const body =
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">'
        '<Period><AdaptationSet><Representation id="v">'
        '<BaseURL>video.mp4</BaseURL>'
        '<SegmentBase><Initialization sourceURL="init.mp4"/></SegmentBase>'
        r'<SegmentTemplate media="seg-$Number$.m4s"/>'
        '</Representation></AdaptationSet></Period></MPD>';
    final rewritten = DashPlaylistRewriter.rewrite(
      body,
      baseUri: Uri.parse(base),
      childUrl: (target) => 'CHILD($target)',
      directoryUrl: (target) => 'DIR($target)/',
    );
    final document = XmlDocument.parse(rewritten);
    expect(
      document.findAllElements('BaseURL').single.innerText,
      'DIR(http://guest.local:5000/path/video.mp4)/',
    );
    expect(
      document
          .findAllElements('Initialization')
          .single
          .getAttribute('sourceURL'),
      'CHILD(http://guest.local:5000/path/init.mp4)',
    );
    expect(
      document.findAllElements('SegmentTemplate').single.getAttribute('media'),
      r'DIR(http://guest.local:5000/path/)/seg-$Number$.m4s',
    );
  });

  test('null callbacks leave external URIs untouched', () {
    const body =
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">'
        '<BaseURL>https://cdn.example/external/</BaseURL>'
        '<SegmentURL media="https://cdn.example/external/seg.m4s"/>'
        '</MPD>';
    final rewritten = DashPlaylistRewriter.rewrite(
      body,
      baseUri: Uri.parse(base),
      childUrl: (_) => null,
      directoryUrl: (_) => null,
    );
    expect(rewritten, body);
  });
}
