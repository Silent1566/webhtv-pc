import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/home_hero_art.dart';

class HomeHeroStartupCandidate {
  const HomeHeroStartupCandidate({
    required this.key,
    required this.sourceUrl,
    required this.title,
    required this.bytes,
    this.subtitle = '',
    this.overview = '',
    this.tags = const [],
  });

  final String key, sourceUrl, title, subtitle, overview;
  final Uint8List bytes;
  final List<String> tags;
}

class CachedHomeHero {
  const CachedHomeHero({
    required this.key,
    required this.sourceUrl,
    required this.filePath,
    required this.title,
    required this.width,
    required this.height,
    this.subtitle = '',
    this.overview = '',
    this.tags = const [],
  });

  final String key, sourceUrl, filePath, title, subtitle, overview;
  final int width, height;
  final List<String> tags;
}

/// Offline-only startup snapshots, isolated under `<directory>/home-hero-startup-v1`.
class HomeHeroStartupCache {
  HomeHeroStartupCache({required Directory directory})
    : _directory = Directory(
        p.join(p.absolute(directory.path), 'home-hero-startup-v1'),
      ) {
    _writer = _writers.putIfAbsent(p.normalize(_directory.path), _Writer.new);
  }

  final Directory _directory;
  late final _Writer _writer;
  static final _writers = <String, _Writer>{};
  static const _maxIndexBytes = 64 * 1024;
  static const _maxImageBytes = 6 * 1024 * 1024;
  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _imagePattern = RegExp(r'^[a-f0-9]{64}\.(png|jpg)$');
  static final _temporaryPattern = RegExp(
    r'^(index\.json|[a-f0-9]{64}\.(png|jpg))\.\d+\.tmp$',
  );

  /// Reads at most 64 KiB of metadata and three images of at most 6 MiB each.
  /// Image decoding belongs exclusively to save, never the startup read path.
  List<CachedHomeHero> read(String scope) {
    try {
      if (!_validScope(scope) || !_safeDirectory(create: false)) return [];
      final bytes = _readBounded(
        File(p.join(_directory.path, 'index.json')),
        _maxIndexBytes,
      );
      if (bytes == null) return [];
      final raw = jsonDecode(utf8.decode(bytes));
      final scopeHash = _hash(utf8.encode(scope));
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['scope'] != scopeHash ||
          raw['entries'] is! List) {
        return [];
      }
      final result = <CachedHomeHero>[];
      for (final value in (raw['entries'] as List).take(3)) {
        try {
          final item = _readEntry(value, scopeHash);
          if (item != null) result.add(item);
        } on Object {
          // A bad entry must not hide its valid siblings.
        }
      }
      return result;
    } on Object {
      return [];
    }
  }

  Future<void> save(String scope, Iterable<HomeHeroStartupCandidate> entries) {
    final generation = ++_writer.generation;
    return _enqueue(() async {
      if (generation != _writer.generation || !_validScope(scope)) return;
      final scopeHash = _hash(utf8.encode(scope));
      final prepared = <_Prepared>[];
      final keys = <String>{};
      try {
        for (final candidate in entries) {
          if (generation != _writer.generation || prepared.length == 3) break;
          if (!_validKey(candidate.key) || keys.contains(candidate.key)) {
            continue;
          }
          final url = _publicUrl(candidate.sourceUrl);
          if (url == null ||
              candidate.bytes.isEmpty ||
              candidate.bytes.length > _maxImageBytes) {
            continue;
          }
          final bytes = Uint8List.fromList(candidate.bytes);
          final format = _format(bytes);
          if (format == null) continue;
          final evidence = await _decode(bytes);
          if (evidence == null || !evidence.isEligible) continue;
          final digest = _hash(bytes);
          final file = _fileName(
            scopeHash,
            candidate.key,
            url,
            digest,
            evidence.width,
            evidence.height,
            format,
          );
          prepared.add(
            _Prepared(bytes, {
              'key': candidate.key,
              'sourceUrl': url,
              'title': _clip(candidate.title, 256),
              'subtitle': _clip(candidate.subtitle, 128),
              'overview': _clip(candidate.overview, 2000),
              'tags': candidate.tags
                  .take(3)
                  .map((tag) => _clip(tag, 64))
                  .toList(),
              'file': file,
              'sha256': digest,
              'size': bytes.length,
              'width': evidence.width,
              'height': evidence.height,
            }),
          );
          keys.add(candidate.key);
        }
        if (prepared.isEmpty || generation != _writer.generation) return;
        final index = utf8.encode(
          jsonEncode({
            'version': 1,
            'scope': scopeHash,
            'entries': prepared.map((item) => item.record).toList(),
          }),
        );
        if (index.length > _maxIndexBytes || !_safeDirectory(create: true)) {
          return;
        }
        // Synchronous commit prevents reads or clear from interleaving index publication
        // and orphan cleanup within this isolate. The old index stays until rename.
        for (final item in prepared) {
          _replace(item.record['file']! as String, item.bytes);
        }
        _replace('index.json', index);
        _prune(prepared.map((item) => item.record['file']! as String).toSet());
      } on Object {
        // An empty/failed refresh retains the last published index.
        _pruneFromIndex();
      }
    });
  }

  Future<void> clear() {
    ++_writer.generation;
    return _enqueue(() async {
      try {
        if (!_safeDirectory(create: false)) return;
        final index = File(p.join(_directory.path, 'index.json'));
        if (FileSystemEntity.typeSync(index.path, followLinks: false) ==
            FileSystemEntityType.file) {
          index.deleteSync();
        }
        _prune({});
      } on Object {
        // Cache I/O is best effort, including clear.
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final future = _writer.tail.then((_) => action());
    _writer.tail = future.catchError((Object _) {});
    return _writer.tail;
  }

  CachedHomeHero? _readEntry(Object? value, String scopeHash) {
    if (value is! Map) return null;
    final key = value['key'];
    final url = value['sourceUrl'];
    final file = value['file'];
    final digest = value['sha256'];
    final size = value['size'];
    final width = value['width'];
    final height = value['height'];
    final title = value['title'];
    final subtitle = value['subtitle'];
    final overview = value['overview'];
    final tags = value['tags'];
    if (key is! String ||
        !_validKey(key) ||
        url is! String ||
        _publicUrl(url) != url ||
        file is! String ||
        !_imagePattern.hasMatch(file) ||
        p.basename(file) != file ||
        digest is! String ||
        !_digestPattern.hasMatch(digest) ||
        size is! int ||
        size <= 0 ||
        size > _maxImageBytes ||
        width is! int ||
        height is! int ||
        !HomeHeroArtEvidence(width: width, height: height).isEligible ||
        title is! String ||
        title.length > 256 ||
        subtitle is! String ||
        subtitle.length > 128 ||
        overview is! String ||
        overview.length > 2000 ||
        tags is! List ||
        tags.length > 3 ||
        tags.any((tag) => tag is! String || tag.length > 64)) {
      return null;
    }
    final format = p.extension(file).substring(1);
    if (file != _fileName(scopeHash, key, url, digest, width, height, format)) {
      return null;
    }
    final path = p.join(_directory.path, file);
    final bytes = _readBounded(File(path), _maxImageBytes);
    if (bytes == null ||
        bytes.length != size ||
        _hash(bytes) != digest ||
        _format(bytes) != format) {
      return null;
    }
    final actual = _encodedDimensions(bytes);
    if (actual == null ||
        actual.width != width ||
        actual.height != height ||
        !actual.isEligible) {
      return null;
    }
    return CachedHomeHero(
      key: key,
      sourceUrl: url,
      filePath: path,
      title: title,
      subtitle: subtitle,
      overview: overview,
      tags: List<String>.unmodifiable(tags.cast<String>()),
      width: width,
      height: height,
    );
  }

  bool _safeDirectory({required bool create}) {
    var path = p.normalize(p.absolute(_directory.path));
    while (true) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        return false;
      }
      final parent = p.dirname(path);
      if (parent == path) break;
      path = parent;
    }
    if (create) _directory.createSync(recursive: true);
    return FileSystemEntity.typeSync(_directory.path, followLinks: false) ==
        FileSystemEntityType.directory;
  }

  static Uint8List? _readBounded(File file, int limit) {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final handle = file.openSync();
    try {
      final length = handle.lengthSync();
      if (length <= 0 || length > limit) return null;
      final bytes = handle.readSync(length);
      if (bytes.length != length || handle.lengthSync() != length) return null;
      return bytes;
    } finally {
      handle.closeSync();
    }
  }

  void _replace(String name, List<int> bytes) {
    final target = File(p.join(_directory.path, name));
    final type = FileSystemEntity.typeSync(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FileSystemException('Unsafe cache target');
    }
    final temporary = File(
      p.join(_directory.path, '$name.${++_writer.serial}.tmp'),
    );
    try {
      temporary.createSync(exclusive: true);
      temporary.writeAsBytesSync(bytes, flush: true);
      temporary.renameSync(target.path);
    } finally {
      if (FileSystemEntity.typeSync(temporary.path, followLinks: false) ==
          FileSystemEntityType.file) {
        temporary.deleteSync();
      }
    }
  }

  void _pruneFromIndex() {
    try {
      if (!_safeDirectory(create: false)) return;
      final bytes = _readBounded(
        File(p.join(_directory.path, 'index.json')),
        _maxIndexBytes,
      );
      if (bytes == null) {
        _prune({});
        return;
      }
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map || raw['entries'] is! List) return;
      _prune({
        for (final item in (raw['entries'] as List).take(3))
          if (item is Map &&
              item['file'] is String &&
              _imagePattern.hasMatch(item['file'] as String))
            item['file'] as String,
      });
    } on Object {
      // Never let cleanup mask the original failed refresh.
    }
  }

  void _prune(Set<String> keep) {
    for (final entity in _directory.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if ((_imagePattern.hasMatch(name) && !keep.contains(name)) ||
          _temporaryPattern.hasMatch(name)) {
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.file) {
          try {
            File(entity.path).deleteSync();
          } on Object {
            /* Best effort. */
          }
        }
      }
    }
  }

  static bool _validScope(String scope) =>
      scope.isNotEmpty &&
      scope.length <= 256 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(scope) &&
      !scope.contains('..');

  static bool _validKey(String key) =>
      key.isNotEmpty &&
      key.length <= 256 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(key);

  static String? _publicUrl(String source) {
    if (source.length > 4096 || RegExp(r'[\x00-\x20\x7f]').hasMatch(source)) {
      return null;
    }
    final uri = Uri.tryParse(source);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    for (final key in uri.queryParametersAll.keys) {
      final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
      if (RegExp(
            r'auth|token|secret|password|passwd|credential|signature|session|cookie|apikey|accesskey|privatekey',
          ).hasMatch(normalized) ||
          ['key', 'sig', 'jwt', 'policy', 'code'].contains(normalized)) {
        return null;
      }
    }
    return uri.removeFragment().toString();
  }

  static String _clip(String value, int limit) {
    if (value.length <= limit) return value;
    var end = limit;
    if (value.codeUnitAt(end - 1) >= 0xd800 &&
        value.codeUnitAt(end - 1) <= 0xdbff) {
      end--;
    }
    return value.substring(0, end);
  }

  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  static String _fileName(
    String scope,
    String key,
    String url,
    String digest,
    int width,
    int height,
    String format,
  ) =>
      '${_hash(utf8.encode(jsonEncode([scope, key, url, digest, width, height])))}.$format';

  static String? _format(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71 &&
        bytes[4] == 13 &&
        bytes[5] == 10 &&
        bytes[6] == 26 &&
        bytes[7] == 10) {
      return 'png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      return 'jpg';
    }
    return null;
  }

  static HomeHeroArtEvidence? _encodedDimensions(Uint8List bytes) {
    final format = _format(bytes);
    if (format == 'png') {
      if (bytes.length < 33 ||
          bytes[8] != 0 ||
          bytes[9] != 0 ||
          bytes[10] != 0 ||
          bytes[11] != 13 ||
          bytes[12] != 73 ||
          bytes[13] != 72 ||
          bytes[14] != 68 ||
          bytes[15] != 82) {
        return null;
      }
      final data = ByteData.sublistView(bytes);
      return HomeHeroArtEvidence(
        width: data.getUint32(16),
        height: data.getUint32(20),
      );
    }
    if (format != 'jpg') return null;
    var offset = 2;
    while (offset + 1 < bytes.length) {
      if (bytes[offset++] != 0xff) return null;
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) return null;
      final marker = bytes[offset++];
      if (marker == 0xda || marker == 0xd9) return null;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) return null;
      final length = (bytes[offset] << 8) | bytes[offset + 1];
      if (length < 2 || offset + length > bytes.length) return null;
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          ![0xc4, 0xc8, 0xcc].contains(marker)) {
        if (length < 8) return null;
        return HomeHeroArtEvidence(
          width: (bytes[offset + 5] << 8) | bytes[offset + 6],
          height: (bytes[offset + 3] << 8) | bytes[offset + 4],
        );
      }
      offset += length;
    }
    return null;
  }

  static Future<HomeHeroArtEvidence?> _decode(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      image = (await codec.getNextFrame()).image;
      return HomeHeroArtEvidence(width: image.width, height: image.height);
    } on Object {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}

class _Writer {
  Future<void> tail = Future.value();
  int generation = 0;
  int serial = 0;
}

class _Prepared {
  const _Prepared(this.bytes, this.record);
  final Uint8List bytes;
  final Map<String, Object> record;
}
