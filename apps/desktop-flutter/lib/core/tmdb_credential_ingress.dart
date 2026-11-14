/// Root subscription TMDB credential ingress.
///
/// The root field is deliberately separate from [TmdbConfig] alias parsing:
/// configuration documents carry it once as an optional subscription-level
/// credential, while settings carry only user-owned aliases. Removing it before
/// the document is decoded prevents it from reaching raw configs, records,
/// exports, diagnostics, or format-error text.
library;

import 'dart:convert';

const String tmdbRootCredentialField = 'tmdb_api_key';
const int tmdbCredentialMinLength = 16;
const int tmdbCredentialMaxLength = 256;

class TmdbCredentialIngress {
  const TmdbCredentialIngress({
    required this.sanitizedJson,
    required this.candidateKey,
  });

  final String sanitizedJson;
  final String candidateKey;

  /// Returns a JSON text with the root credential removed and, only when the
  /// field occurs exactly once and is a valid visible ASCII string, its key.
  static TmdbCredentialIngress extractRootAndStrip(String rawJson) {
    if (rawJson.isEmpty) {
      return TmdbCredentialIngress(sanitizedJson: rawJson, candidateKey: '');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException {
      return TmdbCredentialIngress(
        sanitizedJson: _containsRootCredentialField(rawJson) ? '{}' : rawJson,
        candidateKey: '',
      );
    }
    if (decoded is! Map) {
      return TmdbCredentialIngress(sanitizedJson: rawJson, candidateKey: '');
    }
    final map = decoded.cast<String, Object?>();
    if (!map.containsKey(tmdbRootCredentialField)) {
      return TmdbCredentialIngress(sanitizedJson: rawJson, candidateKey: '');
    }
    final value = map.remove(tmdbRootCredentialField);
    final count = _rootFieldOccurrences(rawJson);
    final candidate = count == 1 && value is String
        ? normalizeApiKey(value)
        : '';
    return TmdbCredentialIngress(
      sanitizedJson: jsonEncode(map),
      candidateKey: candidate,
    );
  }

  /// Strips the root field from a decoded configuration object.
  static Map<String, Object?> stripRootField(Map<Object?, Object?> value) {
    final map = value.cast<String, Object?>();
    if (!map.containsKey(tmdbRootCredentialField)) return map;
    final sanitized = Map<String, Object?>.of(map);
    sanitized.remove(tmdbRootCredentialField);
    return sanitized;
  }

  /// Presence check for malformed documents only: scan every string token so a
  /// credential field cannot hide behind Unicode escapes. Nested occurrences are
  /// treated conservatively as credential-bearing too.
  static bool _containsRootCredentialField(String raw) {
    if (raw.contains('"$tmdbRootCredentialField"')) return true;
    var index = 0;
    while (index < raw.length) {
      if (raw.codeUnitAt(index) != 0x22) {
        index++;
        continue;
      }
      final start = index;
      index++;
      var escaped = false;
      var closed = false;
      while (index < raw.length) {
        final current = raw.codeUnitAt(index);
        if (escaped) {
          escaped = false;
        } else if (current == 0x5c) {
          escaped = true;
        } else if (current == 0x22) {
          index++;
          closed = true;
          break;
        }
        index++;
      }
      if (!closed) return false;
      try {
        if (jsonDecode(raw.substring(start, index)) ==
            tmdbRootCredentialField) {
          return true;
        }
      } on FormatException {
        // Keep scanning other tokens; a later one may be the credential field.
      }
    }
    return false;
  }

  static String normalizeApiKey(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.length < tmdbCredentialMinLength ||
        normalized.length > tmdbCredentialMaxLength) {
      return '';
    }
    for (final unit in normalized.codeUnits) {
      if (unit < 0x21 || unit > 0x7e) return '';
    }
    return normalized;
  }

  /// Counts decoded top-level field names without trusting duplicate handling by
  /// the JSON decoder. Returns -1 when structural scanning fails.
  static int _rootFieldOccurrences(String raw) {
    var index = 0;
    var depth = 0;
    var expectRootKey = false;
    var count = 0;
    while (index < raw.length) {
      final unit = raw.codeUnitAt(index);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d) {
        index++;
        continue;
      }
      if (unit == 0x7b) {
        depth++;
        if (depth == 1) expectRootKey = true;
        index++;
        continue;
      }
      if (unit == 0x7d) {
        depth--;
        index++;
        continue;
      }
      if (unit == 0x5b) {
        depth++;
        index++;
        continue;
      }
      if (unit == 0x5d) {
        depth--;
        index++;
        continue;
      }
      if (unit == 0x2c && depth == 1) {
        expectRootKey = true;
        index++;
        continue;
      }
      if (unit != 0x22) {
        index++;
        continue;
      }
      final start = index;
      index++;
      var escaped = false;
      while (index < raw.length) {
        final current = raw.codeUnitAt(index);
        if (escaped) {
          escaped = false;
        } else if (current == 0x5c) {
          escaped = true;
        } else if (current == 0x22) {
          index++;
          break;
        }
        index++;
      }
      if (expectRootKey && depth == 1) {
        try {
          final name = jsonDecode(raw.substring(start, index));
          if (name == tmdbRootCredentialField) count++;
        } on FormatException {
          return -1;
        }
        expectRootKey = false;
      }
    }
    return depth == 0 ? count : -1;
  }
}
