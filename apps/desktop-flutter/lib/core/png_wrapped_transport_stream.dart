/// Bounded structural PNG prefix proof; media bytes are never retained here.
library;

class PngWrappedTransportStreamProbe {
  static const int prefixLimit = 16 * 1024;
  static const _signature = [137, 80, 78, 71, 13, 10, 26, 10];
  static const _iend = [73, 69, 78, 68, 174, 66, 96, 130];
  final List<int> _prefix = [];
  int _chunk = 8;
  int? _transportStart;
  int? offset;
  bool done = false;

  void add(int byte) {
    if (done) return;
    _prefix.add(byte);
    final length = _prefix.length;
    if (length <= 8 && byte != _signature[length - 1]) {
      done = true;
      return;
    }
    if (_transportStart case final start?) {
      final relative = length - 1 - start;
      if (relative == 0 || relative == 188 || relative == 376) {
        if (byte != 0x47) {
          done = true;
        } else if (relative == 376) {
          offset = start;
          done = true;
        }
      }
    } else if (length >= _chunk + 8) {
      final size =
          (_prefix[_chunk] << 24) |
          (_prefix[_chunk + 1] << 16) |
          (_prefix[_chunk + 2] << 8) |
          _prefix[_chunk + 3];
      final end = _chunk + size + 12;
      if (end + 377 > prefixLimit || size < 0) {
        done = true;
      } else if (length >= end) {
        final isEnd =
            _prefix[_chunk + 4] == 73 &&
            _prefix[_chunk + 5] == 69 &&
            _prefix[_chunk + 6] == 78 &&
            _prefix[_chunk + 7] == 68;
        if (isEnd) {
          if (size != 0 ||
              List.generate(
                8,
                (i) => _prefix[_chunk + 4 + i],
              ).asMap().entries.any((e) => e.value != _iend[e.key])) {
            done = true;
          } else {
            _transportStart = end;
          }
        } else {
          _chunk = end;
        }
      }
    }
    if (length >= prefixLimit) done = true;
  }
}
