import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../core/backup_manifest.dart';

/// 读取和展开的独立预算；默认值保持 v1 备份的压缩体上限。
class BackupReadLimits {
  const BackupReadLimits({
    this.compressedBytes = 512 * 1024 * 1024,
    this.entries = 64,
    this.entryBytes = 512 * 1024 * 1024,
    this.expandedBytes = 1024 * 1024 * 1024,
    this.manifestBytes = 1024 * 1024,
  }) : assert(compressedBytes >= 0),
       assert(entries >= 0),
       assert(entryBytes >= 0),
       assert(expandedBytes >= 0),
       assert(manifestBytes >= 0);

  final int compressedBytes;
  final int entries;
  final int entryBytes;
  final int expandedBytes;
  final int manifestBytes;
}

/// 先验证整个 ZIP 的元数据，再通过受限输出展开；从不调用 ZipDecoder。
class BackupArchiveReader {
  const BackupArchiveReader({this.limits = const BackupReadLimits()});

  final BackupReadLimits limits;

  Future<Map<String, Uint8List>> read(File file) async {
    final handle = await file.open();
    final bytes = BytesBuilder(copy: false);
    try {
      if (await handle.length() > limits.compressedBytes) {
        throw const FormatException('备份压缩体超过读取限额');
      }
      while (true) {
        final chunk = await handle.read(
          math.min(64 * 1024, limits.compressedBytes - bytes.length + 1),
        );
        if (chunk.isEmpty) break;
        if (chunk.length > limits.compressedBytes - bytes.length) {
          throw const FormatException('备份压缩体增长超过读取限额');
        }
        bytes.add(chunk);
      }
    } finally {
      await handle.close();
    }
    return _decode(bytes.takeBytes());
  }

  Map<String, Uint8List> _decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    void requireRange(int offset, int length, [int? end]) {
      if (offset < 0 || length < 0 || offset > (end ?? bytes.length) - length) {
        throw const FormatException('ZIP 元数据或载荷越界');
      }
    }

    int u16(int offset) => data.getUint16(offset, Endian.little);
    int u32(int offset) => data.getUint32(offset, Endian.little);
    int eocd = -1;
    for (
      var i = bytes.length - 22;
      i >= math.max(0, bytes.length - 65557);
      i--
    ) {
      if (u32(i) == 0x06054b50 && i + 22 + u16(i + 20) == bytes.length) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('不是有效的 ZIP 中央目录');
    final count = u16(eocd + 10);
    if (u16(eocd + 4) != 0 || u16(eocd + 6) != 0 || u16(eocd + 8) != count) {
      throw const FormatException('ZIP 分卷不支持');
    }
    if (count > limits.entries) throw const FormatException('ZIP 条目数超过限额');
    final central = u32(eocd + 16);
    final centralSize = u32(eocd + 12);
    requireRange(central, centralSize, eocd);
    if (central + centralSize != eocd) {
      throw const FormatException('ZIP 中央目录大小不一致或 ZIP64 不支持');
    }

    final records = <_ZipPayload>[];
    final seen = <String>{};
    var cursor = central;
    var declaredTotal = 0;
    while (cursor < eocd) {
      if (records.length >= limits.entries) {
        throw const FormatException('ZIP 条目数超过限额');
      }
      requireRange(cursor, 46, eocd);
      if (u32(cursor) != 0x02014b50) {
        throw const FormatException('ZIP 中央目录条目无效');
      }
      final recordSize =
          46 + u16(cursor + 28) + u16(cursor + 30) + u16(cursor + 32);
      requireRange(cursor, recordSize, eocd);
      final header = ZipFileHeader()
        ..read(
          InputMemoryStream(
            Uint8List.sublistView(bytes, cursor + 4, cursor + recordSize),
          ),
        );
      final name = header.filename;
      final directory = name.endsWith('/');
      final path = directory ? name.substring(0, name.length - 1) : name;
      if (!isSafeBackupPath(path)) throw FormatException('ZIP 包含不安全路径：$name');
      if (!seen.add(path.toLowerCase())) {
        throw FormatException('ZIP 包含重复路径：$name');
      }
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      if ((type != 0 && type != 0x8000 && type != 0x4000) ||
          header.externalFileAttributes & 0x400 != 0 ||
          (type == 0x4000 && !directory) ||
          (type == 0x8000 && directory)) {
        throw FormatException('ZIP 链接或特殊文件被拒绝：$name');
      }
      if (header.generalPurposeBitFlag & ~0x080e != 0 ||
          ![0, 8].contains(header.compressionMethod)) {
        throw FormatException('ZIP 加密/压缩方式不支持：$name');
      }
      if (header.diskNumberStart != 0 ||
          u32(cursor + 20) == 0xffffffff ||
          u32(cursor + 24) == 0xffffffff ||
          u32(cursor + 42) == 0xffffffff) {
        throw const FormatException('ZIP 分卷/ZIP64 不支持');
      }
      final size = header.uncompressedSize;
      if (size > limits.entryBytes) throw FormatException('ZIP 单项展开超过限额：$name');
      if (name == backupManifestFile && size > limits.manifestBytes) {
        throw const FormatException('manifest.json 展开超过限额');
      }
      declaredTotal += size;
      if (declaredTotal > limits.expandedBytes) {
        throw const FormatException('ZIP 累计展开超过限额');
      }
      if (directory && size != 0) throw FormatException('ZIP 目录载荷无效：$name');
      final local = header.localHeaderOffset;
      requireRange(local, 30, central);
      if (u32(local) != 0x04034b50) {
        throw const FormatException('ZIP 本地头无效');
      }
      final localNameSize = u16(local + 26);
      final start = local + 30 + localNameSize + u16(local + 28);
      requireRange(local, start - local, central);
      var sameName = localNameSize == u16(cursor + 28);
      for (var i = 0; sameName && i < localNameSize; i++) {
        sameName = bytes[local + 30 + i] == bytes[cursor + 46 + i];
      }
      if (!sameName ||
          u16(local + 4) != header.versionNeededToExtract ||
          u16(local + 6) != header.generalPurposeBitFlag ||
          u16(local + 8) != header.compressionMethod ||
          u16(local + 10) != header.lastModifiedFileTime ||
          u16(local + 12) != header.lastModifiedFileDate) {
        throw FormatException('ZIP 本地/中央目录不一致：$name');
      }
      final descriptor = header.generalPurposeBitFlag & 8 != 0;
      final localCrc = u32(local + 14);
      final localCompressed = u32(local + 18);
      final localSize = u32(local + 22);
      bool agrees(int actual, int expected) =>
          actual == expected || descriptor && actual == 0;
      if (!agrees(localCrc, header.crc32) ||
          !agrees(localCompressed, header.compressedSize) ||
          !agrees(localSize, size)) {
        throw FormatException('ZIP 本地/中央目录大小或 CRC 不一致：$name');
      }
      requireRange(start, header.compressedSize, central);
      var end = start + header.compressedSize;
      if (descriptor) {
        requireRange(end, 12, central);
        if (u32(end) == 0x08074b50) end += 4;
        requireRange(end, 12, central);
        if (u32(end) != header.crc32 ||
            u32(end + 4) != header.compressedSize ||
            u32(end + 8) != size) {
          throw FormatException('ZIP 数据描述符不一致：$name');
        }
        end += 12;
      }
      for (final prior in records) {
        if (local < prior.end && end > prior.local) {
          throw const FormatException('ZIP 本地条目重叠');
        }
      }
      records.add(_ZipPayload(header, local, start, end, directory));
      cursor += recordSize;
    }
    if (records.length != count) throw const FormatException('ZIP 条目数与中央目录不一致');

    var expanded = 0;
    final files = <String, Uint8List>{};
    for (final record in records) {
      final header = record.header;
      final name = header.filename;
      final cap = math.min(
        header.uncompressedSize,
        math.min(
          limits.entryBytes,
          name == backupManifestFile ? limits.manifestBytes : limits.entryBytes,
        ),
      );
      final output = _BoundedOutput(cap, (count) {
        if (count > limits.expandedBytes - expanded) {
          throw const FormatException('ZIP 实际展开超过累计限额');
        }
        expanded += count;
      });
      final input = InputMemoryStream(
        Uint8List.sublistView(
          bytes,
          record.start,
          record.start + header.compressedSize,
        ),
      );
      if (header.compressionMethod == 0) {
        output.writeStream(input);
      } else {
        // Force archive's incremental Dart inflater; native decodeBytes allocates first.
        Inflate.stream(input, output: output);
      }
      final content = output.getBytes();
      if (content.length != header.uncompressedSize ||
          getCrc32(content) != header.crc32) {
        throw FormatException('ZIP 文件大小/CRC 校验失败：$name');
      }
      if (!record.directory) files[name] = content;
    }
    return files;
  }
}

class _ZipPayload {
  const _ZipPayload(
    this.header,
    this.local,
    this.start,
    this.end,
    this.directory,
  );
  final ZipFileHeader header;
  final int local;
  final int start;
  final int end;
  final bool directory;
}

/// All output paths reserve budget before allocation, including optimized LZ77 copies.
class _BoundedOutput extends OutputStream {
  _BoundedOutput(this.cap, this.reserveTotal)
    : _buffer = Uint8List(math.min(cap, 32 * 1024)),
      super(byteOrder: ByteOrder.littleEndian);

  final int cap;
  final void Function(int) reserveTotal;
  Uint8List _buffer;
  int _length = 0;
  @override
  int get length => _length;

  void _reserve(int count) {
    if (count < 0 || count > cap - _length) {
      throw const FormatException('ZIP 实际展开超过声明大小/单项限额');
    }
    reserveTotal(count);
    final needed = _length + count;
    if (needed > _buffer.length) {
      final grown = Uint8List(
        math.min(cap, math.max(needed, _buffer.length * 2)),
      )..setRange(0, _length, _buffer);
      _buffer = grown;
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _buffer[_length++] = value;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    _buffer.setRange(_length, _length + count, bytes);
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    final count = stream.length;
    _buffer.setRange(_length, _length + count, stream.toUint8List());
    _length += count;
  }

  @override
  void writeBackReference(int distance, int count) {
    if (distance < 1 || distance > _length) {
      throw const FormatException('ZIP 回引用无效');
    }
    _reserve(count);
    for (var i = 0; i < count; i++) {
      _buffer[_length] = _buffer[_length - distance];
      _length++;
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => Uint8List.sublistView(
    _buffer,
    start < 0 ? _length + start : start,
    end == null
        ? _length
        : end < 0
        ? _length + end
        : end,
  );
  @override
  Uint8List getBytes() => subset(0);
  @override
  void clear() => throw UnsupportedError('备份展开输出不可重置');
  @override
  void flush() {}
}
