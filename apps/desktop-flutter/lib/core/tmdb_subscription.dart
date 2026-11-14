/// Process-memory TMDB credential scope for the currently selected configuration.
///
/// Mirrors the Android subscription credential ownership: the value is accepted
/// only after a configuration import/refresh commits, belongs to one
/// configuration id + source key + epoch, and dies with a scope change, delete,
/// process restart, or explicit clear. It is never serialized.
library;

import 'tmdb_credential_ingress.dart';

class TmdbSubscriptionCredentials {
  String _apiKey = '';
  int _configId = 0;
  String _sourceKey = '';
  int _epoch = 0;
  bool _hasScope = false;

  int get epoch => _epoch;
  bool get hasScope => _hasScope;
  int get configId => _configId;
  String get sourceKey => _sourceKey;

  /// Starts a scope, clearing the credential whenever its identity changes.
  int beginScope(int configId, String sourceKey) {
    final key = _normalizeSource(sourceKey);
    if (!_hasScope || _configId != configId || _sourceKey != key) {
      _epoch++;
      _apiKey = '';
      _configId = configId;
      _sourceKey = key;
      _hasScope = true;
    }
    return _epoch;
  }

  /// Accepts a candidate only inside the scope that requested it.
  bool accept(
    String candidate,
    int configId,
    String sourceKey,
    int expectedEpoch,
  ) {
    final key = TmdbCredentialIngress.normalizeApiKey(candidate);
    if (key.isEmpty) return false;
    if (!_hasScope ||
        _configId != configId ||
        _sourceKey != _normalizeSource(sourceKey) ||
        _epoch != expectedEpoch) {
      return false;
    }
    if (_apiKey.isNotEmpty && _apiKey != key) _epoch++;
    _apiKey = key;
    return true;
  }

  /// The key visible for exactly this scope, or an empty string.
  String snapshot(int configId, String sourceKey, int expectedEpoch) {
    if (!_hasScope ||
        _configId != configId ||
        _sourceKey != _normalizeSource(sourceKey) ||
        _epoch != expectedEpoch) {
      return '';
    }
    return _apiKey;
  }

  void clear() {
    _epoch++;
    _apiKey = '';
  }

  void discardCredential() {
    if (_apiKey.isEmpty) return;
    _epoch++;
    _apiKey = '';
  }

  static String _normalizeSource(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
