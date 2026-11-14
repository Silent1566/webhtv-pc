import 'dart:convert';

import 'track_transport.dart';

/// 一条检索结果；`url` 必须能直接交给仓库导入，`loginRequired` 表示需要用户登录。
class KaraokeSearchResult {
  const KaraokeSearchResult({
    required this.source,
    required this.title,
    required this.artist,
    required this.note,
    required this.url,
    this.loginRequired = false,
  });
  final String source, title, artist, note, url;
  final bool loginRequired;
}

/// 源提供者：只做真实传输 + 解析，不落盘、不缓存、不直接触网于 UI。
abstract class KaraokeTrackProvider {
  String get name;
  Future<List<KaraokeSearchResult>> search(
    String keyword,
    KaraokeTransport transport,
  );
}

String normalizeSearchText(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[^\p{L}\p{N}]+', unicode: true),
  '',
);

String stripExtension(String name) {
  var value = name.trim();
  final query = value.indexOf('?');
  if (query >= 0) value = value.substring(0, query);
  final dot = value.lastIndexOf('.');
  if (dot > 0 && value.length - dot <= 16) value = value.substring(0, dot);
  return value.trim();
}

String parseSongFromLabel(String value) {
  final index = value.indexOf(' - ');
  return index > 0 && index + 3 < value.length
      ? value.substring(index + 3).trim()
      : value.trim();
}

String parseArtistFromLabel(String value) {
  final index = value.indexOf(' - ');
  return index > 0 ? value.substring(0, index).trim() : '';
}

String decodeEntities(String value) => value
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('\u00a0', ' ')
    .trim();

Uri absoluteUri(String base, String path) {
  if (path.isEmpty) return Uri.parse(base);
  if (path.startsWith('http://') || path.startsWith('https://'))
    return Uri.parse(path);
  if (path.startsWith('//')) return Uri.parse('https:$path');
  return Uri.parse(base).resolve(path.startsWith('/') ? path : '/$path');
}

/// GitHub 上的 UltraStar 仓库：tree API 列文件，raw 地址作为导入源。
class KaraokeGithubProvider implements KaraokeTrackProvider {
  const KaraokeGithubProvider({
    this.sources = const [
      ('GitHub USDX', 'razzertronic', 'usdx-songs', 'master', 'Unlicense'),
      (
        'GitHub UltraStar',
        'Vasil-Pahomov',
        'UltraStarSongs',
        'master',
        'GPL-3.0',
      ),
    ],
  });
  final List<(String, String, String, String, String)> sources;

  @override
  String get name => 'GitHub';

  @override
  Future<List<KaraokeSearchResult>> search(
    String keyword,
    KaraokeTransport transport,
  ) async {
    final results = <KaraokeSearchResult>[];
    final normalized = normalizeSearchText(keyword);
    if (normalized.length < 2) return results;
    for (final source in sources) {
      if (results.length >= 24) return results;
      final (label, owner, repo, branch, license) = source;
      final treeUri = Uri.parse(
        'https://api.github.com/repos/$owner/$repo/git/trees/$branch?recursive=1',
      );
      final response = await transport.get(treeUri);
      response.checkedText();
      for (final path in parseGithubTree(response.checkedText())) {
        if (results.length >= 24) return results;
        if (!path.toLowerCase().endsWith('.txt')) continue;
        if (!matchesKeyword(path, keyword)) continue;
        final song = parseSongFromLabel(labelFromPath(path));
        final url =
            'https://raw.githubusercontent.com/$owner/$repo/$branch/${path.split('/').map(Uri.encodeComponent).join('/')}';
        results.add(
          KaraokeSearchResult(
            source: label,
            title: song,
            artist: parseArtistFromLabel(labelFromPath(path)),
            note: 'UltraStar .txt · $license',
            url: url,
          ),
        );
      }
    }
    return results;
  }

  static List<String> parseGithubTree(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic> || decoded['tree'] is! List)
      throw const KaraokeTrackException('invalid GitHub tree');
    final paths = <String>[];
    for (final row in decoded['tree'] as List) {
      if (row is! Map || row['type'] is! String) {
        throw const KaraokeTrackException('invalid GitHub entry');
      }
      if (row['type'] != 'blob') continue;
      final path = row['path'];
      final size = row['size'];
      if (path is! String)
        throw const KaraokeTrackException('invalid GitHub path');
      if (!path.toLowerCase().endsWith('.txt')) continue;
      if (size is! int || size <= 0 || size > 512 * 1024) {
        throw const KaraokeTrackException('invalid GitHub track size');
      }
      if (path.startsWith('/') ||
          path.split('/').any((part) => part == '..') ||
          path.contains('\\'))
        continue;
      paths.add(path);
    }
    return paths;
  }

  static bool matchesKeyword(String path, String query) {
    final haystack = normalizeSearchText(path);
    final whole = normalizeSearchText(query);
    if (whole.isEmpty) return false;
    if (haystack.contains(whole)) return true;
    final tokens = query
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .map(normalizeSearchText)
        .where((s) => s.length >= 2)
        .toList();
    return tokens.isNotEmpty && tokens.every(haystack.contains);
  }

  static String labelFromPath(String path) {
    final value = stripExtension(path);
    final slash = value.lastIndexOf('/');
    final file = slash >= 0 ? value.substring(slash + 1) : value;
    if (slash > 0 &&
        const ['s', 'sm', 'sp', 'song'].contains(normalizeSearchText(file))) {
      return value.substring(value.lastIndexOf('/', slash - 1) + 1, slash);
    }
    return file;
  }
}

/// USDB：details 页给 BPM/GAP，notes 页给 giveinfo0 音符表，拼成 UltraStar 文本。
class KaraokeUsdbProvider implements KaraokeTrackProvider {
  const KaraokeUsdbProvider();
  static final RegExp _row = RegExp(
    r'<tr\s+class="list_tr[12][^"]*"[^>]*>\s*([\s\S]*?)\s*</tr>',
    caseSensitive: false,
  );
  static final RegExp _detailId = RegExp(r'show_detail\((\d+)\)');
  static final RegExp _cell = RegExp(
    r'<td\s+[^>]*>\s*(?:<a[^>]*>)?([\s\S]*?)(?:</a>)?\s*</td>',
    caseSensitive: false,
  );
  static final RegExp _usdbId = RegExp(
    r'(?:usdb\.animux\.de[\s\S]*?[?&]id=|\busdb\s*[:#]?\s*|^)(\d{3,6})(?:\D|$)',
    caseSensitive: false,
  );
  static final RegExp _usdbNote = RegExp(
    r"giveinfo0\('([^']*)','(-?\d+)','(-?\d+)','(-?\d+)','([^']*)','([^']*)'\)",
  );

  @override
  String get name => 'USDB';

  @override
  Future<List<KaraokeSearchResult>> search(
    String keyword,
    KaraokeTransport transport,
  ) async {
    final id = parseUsdbId(keyword);
    if (id.isNotEmpty) {
      final uri = Uri.parse('https://usdb.animux.de/?link=detail&id=$id');
      final response = await transport.get(uri);
      response.checkedText();
      final title = parseTitle(response.checkedText());
      return [
        KaraokeSearchResult(
          source: 'USDB',
          title: parseSongFromLabel(title),
          artist: parseArtistFromLabel(title),
          note:
              'BPM ${detailField(response.checkedText(), 'BPM')} · GAP ${detailField(response.checkedText(), 'GAP')}',
          url: uri.toString(),
        ),
      ];
    }
    if (keyword.trim().length < 2) return const [];
    final results = <KaraokeSearchResult>[];
    for (final artistSearch in [false, true]) {
      if (results.isNotEmpty) break;
      final response = await transport.post(
        Uri.parse('https://usdb.animux.de/?link=list'),
        {
          'order': 'lastchange',
          'ud': 'desc',
          artistSearch ? 'interpret' : 'title': keyword.trim(),
          'limit': '20',
          'start': '0',
        },
      );
      response.checkedText();
      for (final row in _row.allMatches(response.checkedText())) {
        if (results.length >= 10) break;
        final result = parseRow(row.group(1)!);
        if (result != null) results.add(result);
      }
    }
    for (final file in ['rss_new_top10.php', 'rss_downloads_top10.php']) {
      final response = await transport.get(
        Uri.parse('https://usdb.animux.de/rss/$file'),
      );
      final body = response.checkedText();
      var added = 0;
      for (final item in RegExp(
        r'<item>(.*?)</item>',
        caseSensitive: false,
        dotAll: true,
      ).allMatches(body)) {
        if (added >= 5) break;
        final block = item.group(1)!;
        final title = decodeEntities(
          RegExp(
                r'<title>(.*?)</title>',
                caseSensitive: false,
                dotAll: true,
              ).firstMatch(block)?.group(1) ??
              '',
        );
        final id = RegExp(
          r'<guid>(\d+)</guid>',
          caseSensitive: false,
        ).firstMatch(block)?.group(1);
        if (id == null ||
            !normalizeSearchText(title).contains(normalizeSearchText(keyword)))
          continue;
        final url = 'https://usdb.animux.de/?link=detail&id=$id';
        if (results.any((r) => r.url == url)) continue;
        results.add(
          KaraokeSearchResult(
            source: 'USDB RSS',
            title: parseSongFromLabel(title),
            artist: parseArtistFromLabel(title),
            note: 'USDB #$id',
            url: url,
          ),
        );
        added++;
      }
    }
    return results;
  }

  static KaraokeSearchResult? parseRow(String html) {
    final id = _detailId.firstMatch(html)?.group(1);
    if (id == null || id.isEmpty) return null;
    final cells = [
      for (final cell in _cell.allMatches(html)) decodeEntities(cell.group(1)!),
    ];
    if (cells.length < 2) return null;
    return KaraokeSearchResult(
      source: 'USDB',
      title: cells[1],
      artist: cells[0],
      note: 'USDB #$id',
      url: 'https://usdb.animux.de/?link=detail&id=$id',
    );
  }

  static String detailField(String html, String field) {
    final match = RegExp(
      '<tr\\s+class="list_tr[12]"\\s*>\\s*<td>\\s*${RegExp.escape(field)}\\s*</td>\\s*<td>(.*?)</td>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    return match == null ? '' : decodeEntities(match.group(1)!);
  }

  static String parseTitle(String html) {
    final title = RegExp(
      r'<title>\s*USDB\s*-\s*(.*?)\s*</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html)?.group(1);
    if (title != null && title.isNotEmpty) return decodeEntities(title);
    return decodeEntities(
      RegExp(
            r'<th[^>]*>\s*<span[^>]*>\s*<b>(.*?)</b>',
            caseSensitive: false,
            dotAll: true,
          ).firstMatch(html)?.group(1) ??
          '',
    );
  }

  static String parseUsdbId(String text) {
    final match = _usdbId.firstMatch(text.trim());
    return match == null ? '' : match.group(1)!;
  }

  /// details + notes 两页 → UltraStar 文本；缺 BPM/GAP 或无音符即失败，不产出半成品。
  static String buildTrackText(String detailHtml, String notesHtml) {
    final bpm = detailField(detailHtml, 'BPM');
    final gap = detailField(detailHtml, 'GAP');
    if (bpm.isEmpty || gap.isEmpty) throw StateError('missing USDB timing');
    final title = parseTitle(detailHtml);
    final buffer = StringBuffer()
      ..writeln('#TITLE:${parseSongFromLabel(title)}')
      ..writeln('#ARTIST:${parseArtistFromLabel(title)}')
      ..writeln('#BPM:$bpm')
      ..writeln('#GAP:$gap');
    var count = 0;
    for (final match in _usdbNote.allMatches(notesHtml)) {
      final lyric = decodeEntities(match.group(6)!)
          .replaceAll(RegExp(r'[\r\n]+'), ' ')
          .trim();
      buffer.writeln(
        '${_prefix(match.group(1)!)} ${match.group(2)} ${match.group(3)} ${match.group(4)} $lyric',
      );
      count++;
    }
    if (count == 0) throw StateError('no USDB notes');
    buffer.writeln('E');
    return buffer.toString();
  }

  static String _prefix(String type) => switch (type.toLowerCase()) {
    'golden' => '*',
    'freestyle' => 'F',
    'rap' => 'R',
    _ => ':',
  };
}

/// UltraStar-ES：列表页取 txt 下载直链与歌手/曲名。
class KaraokeUltrastarEsProvider implements KaraokeTrackProvider {
  const KaraokeUltrastarEsProvider();
  static final RegExp _item = RegExp(
    r'<li\s+title="See all complete information of ([^"]+)"([\s\S]*?)(?=\n\s*<li\s+title="See all complete information of |\n\s*</ul>)',
    caseSensitive: false,
  );
  static final RegExp _txt = RegExp(
    r'href="([^"]*/canciones/descargar/txt/[^"]+)"',
    caseSensitive: false,
  );
  static final RegExp _artist = RegExp(
    r'<a\s+href="/[^"]*/canciones\?artista=[^"]*"[^>]*>(.*?)</a>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _title = RegExp(
    r'<a>(.*?)</a>',
    caseSensitive: false,
    dotAll: true,
  );

  @override
  String get name => 'UltraStar-ES';

  @override
  Future<List<KaraokeSearchResult>> search(
    String keyword,
    KaraokeTransport transport,
  ) async {
    if (keyword.trim().length < 2) return const [];
    final uri = Uri.parse(
      'https://ultrastar-es.org/en/canciones?busqueda=${Uri.encodeQueryComponent(keyword.trim())}',
    );
    final response = await transport.get(uri);
    response.checkedText();
    return parseList(response.checkedText());
  }

  static List<KaraokeSearchResult> parseList(String html) {
    final results = <KaraokeSearchResult>[];
    for (final item in _item.allMatches(html)) {
      if (results.length >= 12) break;
      final fallback = decodeEntities(item.group(1)!);
      final block = item.group(2)!;
      final path = _txt.firstMatch(block)?.group(1);
      if (path == null || path.isEmpty) continue;
      final last = _title.allMatches(block).isEmpty
          ? null
          : _title.allMatches(block).last.group(1);
      final artist = decodeEntities(_artist.firstMatch(block)?.group(1) ?? '');
      final title = last == null ? '' : decodeEntities(last);
      results.add(
        KaraokeSearchResult(
          source: 'UltraStar-ES',
          title: title.isEmpty ? parseSongFromLabel(fallback) : title,
          artist: artist.isEmpty ? parseArtistFromLabel(fallback) : artist,
          note: '可能需要登录下载',
          url: absoluteUri('https://ultrastar-es.org', path).toString(),
          loginRequired: true,
        ),
      );
    }
    return results;
  }
}
