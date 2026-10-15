import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One entry from a ZIP central directory.
class ZipEntry {
  ZipEntry({
    required this.name,
    required this.method,
    required this.flags,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  /// Name as stored in the archive, with `\` normalized to `/`.
  final String name;
  final int method;
  final int flags;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;

  bool get isDirectory => name.endsWith('/');
  bool get isEncrypted => (flags & 0x1) != 0;
  String get baseName {
    final i = name.lastIndexOf('/');
    return i < 0 ? name : name.substring(i + 1);
  }

  String get lowerName => name.toLowerCase();
}

/// Reads only the ZIP central directory, then streams individual entries on demand.
///
/// Unlike decoding the whole archive in memory, this touches a few KB to list a multi-GB XAPK
/// and copies a single entry with constant memory. Supports stored and deflated entries and ZIP64.
class ZipIndex {
  ZipIndex._(this.file, this.length, this.entries);

  final File file;
  final int length;
  final List<ZipEntry> entries;

  static const _sigEocd = 0x06054b50;
  static const _sigZip64Locator = 0x07064b50;
  static const _sigZip64Eocd = 0x06064b50;
  static const _sigCentral = 0x02014b50;
  static const _sigLocal = 0x04034b50;

  /// Returns null when [path] is not a ZIP this reader understands (callers then fall back).
  static Future<ZipIndex?> tryOpen(String path) async {
    try {
      return await open(path);
    } catch (_) {
      return null;
    }
  }

  static Future<ZipIndex> open(String path) async {
    final file = File(path);
    final raf = await file.open();
    try {
      final len = await raf.length();
      if (len < 22) throw const FormatException('Too small to be a ZIP');
      final tailLen = len < 65557 ? len : 65557;
      await raf.setPosition(len - tailLen);
      final tail = await raf.read(tailLen);
      final td = ByteData.sublistView(tail);

      var eocd = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (td.getUint32(i, Endian.little) != _sigEocd) continue;
        final commentLen = td.getUint16(i + 20, Endian.little);
        if (i + 22 + commentLen == tail.length) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) throw const FormatException('No end-of-central-directory record');

      var count = td.getUint16(eocd + 10, Endian.little);
      var cdSize = td.getUint32(eocd + 12, Endian.little);
      var cdOffset = td.getUint32(eocd + 16, Endian.little);

      if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
        final locPos = len - tailLen + eocd - 20;
        if (locPos < 0) throw const FormatException('Missing ZIP64 locator');
        await raf.setPosition(locPos);
        final loc = ByteData.sublistView(await raf.read(20));
        if (loc.getUint32(0, Endian.little) != _sigZip64Locator) {
          throw const FormatException('Missing ZIP64 locator');
        }
        final z64Pos = loc.getUint64(8, Endian.little);
        await raf.setPosition(z64Pos);
        final z = ByteData.sublistView(await raf.read(56));
        if (z.getUint32(0, Endian.little) != _sigZip64Eocd) {
          throw const FormatException('Bad ZIP64 end record');
        }
        count = z.getUint64(32, Endian.little);
        cdSize = z.getUint64(40, Endian.little);
        cdOffset = z.getUint64(48, Endian.little);
      }
      if (cdOffset + cdSize > len) throw const FormatException('Central directory out of range');

      await raf.setPosition(cdOffset);
      final cd = await raf.read(cdSize);
      final d = ByteData.sublistView(cd);
      final entries = <ZipEntry>[];
      var pos = 0;
      for (var n = 0; n < count; n++) {
        if (pos + 46 > cd.length || d.getUint32(pos, Endian.little) != _sigCentral) {
          throw const FormatException('Corrupt central directory');
        }
        final flags = d.getUint16(pos + 8, Endian.little);
        final method = d.getUint16(pos + 10, Endian.little);
        var csize = d.getUint32(pos + 20, Endian.little);
        var usize = d.getUint32(pos + 24, Endian.little);
        final nameLen = d.getUint16(pos + 28, Endian.little);
        final extraLen = d.getUint16(pos + 30, Endian.little);
        final commentLen = d.getUint16(pos + 32, Endian.little);
        var offset = d.getUint32(pos + 42, Endian.little);
        final nameBytes = cd.sublist(pos + 46, pos + 46 + nameLen);
        final name = (flags & 0x800) != 0
            ? utf8.decode(nameBytes, allowMalformed: true)
            : latin1.decode(nameBytes);

        // ZIP64 extended information: only the fields that overflowed are present, in order.
        var ex = pos + 46 + nameLen;
        final exEnd = ex + extraLen;
        while (ex + 4 <= exEnd) {
          final id = d.getUint16(ex, Endian.little);
          final size = d.getUint16(ex + 2, Endian.little);
          if (id == 0x0001) {
            var q = ex + 4;
            if (usize == 0xFFFFFFFF && q + 8 <= ex + 4 + size) {
              usize = d.getUint64(q, Endian.little);
              q += 8;
            }
            if (csize == 0xFFFFFFFF && q + 8 <= ex + 4 + size) {
              csize = d.getUint64(q, Endian.little);
              q += 8;
            }
            if (offset == 0xFFFFFFFF && q + 8 <= ex + 4 + size) {
              offset = d.getUint64(q, Endian.little);
            }
          }
          ex += 4 + size;
        }

        entries.add(ZipEntry(
          name: name.replaceAll('\\', '/'),
          method: method,
          flags: flags,
          compressedSize: csize,
          uncompressedSize: usize,
          localHeaderOffset: offset,
        ));
        pos += 46 + nameLen + extraLen + commentLen;
      }
      return ZipIndex._(file, len, entries);
    } finally {
      await raf.close();
    }
  }

  ZipEntry? find(bool Function(ZipEntry e) test) {
    for (final e in entries) {
      if (test(e)) return e;
    }
    return null;
  }

  Future<int> _dataStart(ZipEntry e) async {
    final raf = await file.open();
    try {
      await raf.setPosition(e.localHeaderOffset);
      final h = ByteData.sublistView(await raf.read(30));
      if (h.lengthInBytes < 30 || h.getUint32(0, Endian.little) != _sigLocal) {
        throw FormatException('Bad local header for ${e.name}');
      }
      final nameLen = h.getUint16(26, Endian.little);
      final extraLen = h.getUint16(28, Endian.little);
      final start = e.localHeaderOffset + 30 + nameLen + extraLen;
      if (start + e.compressedSize > length) throw FormatException('Entry ${e.name} out of range');
      return start;
    } finally {
      await raf.close();
    }
  }

  /// Streams the uncompressed bytes of [e].
  Future<Stream<List<int>>> openEntry(ZipEntry e) async {
    if (e.isEncrypted) throw FormatException('Encrypted entry ${e.name}');
    final start = await _dataStart(e);
    final raw = file.openRead(start, start + e.compressedSize);
    switch (e.method) {
      case 0:
        return raw;
      case 8:
        return raw.transform(ZLibDecoder(raw: true));
      default:
        throw FormatException('Unsupported compression ${e.method} for ${e.name}');
    }
  }

  /// Reads a (small) entry fully into memory.
  Future<Uint8List> readBytes(ZipEntry e) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in await openEntry(e)) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  /// Copies [e] to [destPath]. [onBytes] receives the number of compressed bytes consumed so far
  /// increments, so callers can sum progress across entries against [ZipEntry.compressedSize].
  Future<void> extractTo(ZipEntry e, String destPath, {void Function(int delta)? onBytes}) async {
    if (e.isEncrypted) throw FormatException('Encrypted entry ${e.name}');
    final start = await _dataStart(e);
    Stream<List<int>> raw = file.openRead(start, start + e.compressedSize);
    if (onBytes != null) {
      raw = raw.map((c) {
        onBytes(c.length);
        return c;
      });
    }
    final Stream<List<int>> data = switch (e.method) {
      0 => raw,
      8 => raw.transform(ZLibDecoder(raw: true)),
      _ => throw FormatException('Unsupported compression ${e.method} for ${e.name}'),
    };
    final out = File(destPath);
    await out.parent.create(recursive: true);
    final sink = out.openWrite();
    try {
      await sink.addStream(data);
    } finally {
      await sink.close();
    }
    final written = await out.length();
    if (written != e.uncompressedSize) {
      throw FormatException('Size mismatch extracting ${e.name} ($written != ${e.uncompressedSize})');
    }
  }
}
