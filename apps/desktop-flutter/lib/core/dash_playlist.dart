/// DASH MPD URI rewriting for the tokenized streaming proxy.
///
/// This is pure logic: it never opens a connection and never chooses an
/// authorization. Callbacks return null when a target must stay untouched.
library;

import 'package:xml/xml.dart';

abstract final class DashPlaylistRewriter {
  static bool looksLikeManifest(String? contentType, String url) {
    final type = (contentType ?? '').toLowerCase();
    if (type.contains('dash+xml')) return true;
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.mpd');
  }

  /// Rewrites URI-bearing MPD elements against [baseUri].
  ///
  /// [directoryUrl] returns a tokenized URL ending with '/', leaving template
  /// placeholders outside that URL so the player can expand them. [childUrl]
  /// returns a tokenized complete-resource URL.
  static String rewrite(
    String body, {
    required Uri baseUri,
    required String? Function(Uri target) childUrl,
    required String? Function(Uri directory) directoryUrl,
  }) {
    final document = XmlDocument.parse(body);
    var changed = false;

    String map(String value, {Uri? base, bool directoryPreferred = false}) {
      final parsed = Uri.tryParse(value.trim());
      if (base == null && (parsed == null || !parsed.hasScheme)) return value;
      final next = _mapReference(
        value,
        baseUri: base ?? baseUri,
        childUrl: childUrl,
        directoryUrl: directoryUrl,
        directoryPreferred: directoryPreferred,
      );
      if (next != value) changed = true;
      return next;
    }

    void rewriteAttributes(XmlElement element, Uri? base) {
      if (element.name.local != 'SegmentTemplate' &&
          element.name.local != 'SegmentURL' &&
          element.name.local != 'Initialization') {
        return;
      }
      for (final name in const [
        'media',
        'initialization',
        'index',
        'sourceURL',
      ]) {
        final value = element.getAttribute(name);
        if (value != null) {
          element.setAttribute(name, map(value, base: base));
        }
      }
    }

    // BaseURL children are alternatives at the same parent scope, not a
    // sequential nesting chain. One alternative gives a resolvable child
    // scope; multiple alternatives are ambiguous, so relative references are
    // left intact for the player to resolve against its chosen BaseURL.
    void visit(XmlElement element, Uri? scope) {
      final baseUrls = element.childElements
          .where((child) => child.name.local == 'BaseURL')
          .toList();
      Uri? inherited;
      if (baseUrls.isEmpty) {
        inherited = scope;
      } else {
        final logicals = <Uri>[];
        for (final child in baseUrls) {
          final raw = child.innerText;
          final logical = scope == null
              ? _absoluteHttp(raw)
              : _resolve(raw.trim(), scope);
          child.innerText = map(raw, base: scope, directoryPreferred: true);
          if (logical != null && !raw.contains(r'$')) {
            logicals.add(logical);
          }
        }
        inherited = logicals.length == 1 ? logicals.single : null;
      }
      for (final child in element.childElements) {
        if (child.name.local == 'BaseURL') continue;
        rewriteAttributes(child, inherited);
        visit(child, inherited);
      }
    }

    visit(document.rootElement, baseUri);
    return changed ? document.toXmlString() : body;
  }

  static String _mapReference(
    String value, {
    required Uri baseUri,
    required String? Function(Uri target) childUrl,
    required String? Function(Uri directory) directoryUrl,
    required bool directoryPreferred,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.startsWith('data:')) return value;
    final resolved = _resolve(trimmed, baseUri);
    if (resolved == null) return value;

    final text = resolved.toString();
    final marker = text.indexOf(r'$');
    if (marker >= 0) {
      final slash = text.lastIndexOf('/', marker);
      final authorityEnd = text.indexOf('://');
      if (slash > authorityEnd + 2) {
        final prefix = text.substring(0, slash + 1);
        final suffix = text.substring(slash + 1);
        final mapped = directoryUrl(Uri.parse(prefix));
        if (mapped == null) return value;
        return mapped.endsWith('/') ? '$mapped$suffix' : '$mapped/$suffix';
      }
    }

    if (directoryPreferred) {
      return directoryUrl(resolved) ?? value;
    }
    return childUrl(resolved) ?? value;
  }

  static Uri? _absoluteHttp(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme) return null;
    return uri.isScheme('http') || uri.isScheme('https') ? uri : null;
  }

  static Uri? _resolve(String value, Uri baseUri) {
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.hasScheme) {
      if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
      return uri;
    }
    final resolved = baseUri.resolveUri(uri);
    return resolved.isScheme('http') || resolved.isScheme('https')
        ? resolved
        : null;
  }
}
