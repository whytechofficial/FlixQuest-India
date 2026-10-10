import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'common.dart';

/// NetMirror direct provider.
///
/// Uses NetMirror's REST API keyed by TMDB id:
///   GET {base}/api/embed-tmdb/{tmdbId}                 (movies)
///   GET {base}/api/embed-tmdb/{tmdbId}?type=tv&s=S&e=E (episodes)
///
/// Returns signed MP4 streams (360/480/1080) plus subtitle captions.
/// The API base domain rotates, so we probe a list of known bases and
/// cache the working one. Stream CDNs 403 without the videodownloader
/// Referer, so every stream carries it.
class NetMirror {
  static const _bases = <String>[
    'https://net79.cc',
    'https://net27.cc',
  ];

  static const _headers = <String, String>{
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
    'Accept': 'application/json',
  };

  /// Referer the stream CDN requires, otherwise it answers 403.
  static const _streamReferer = 'https://videodownloader.site/';

  static const _timeout = Duration(seconds: 30);

  /// NetMirror wraps subtitle files in `/api/proxy/video?url=<cdn-url>`, but
  /// the proxy is aggressively rate-limited (429s). The inner CDN URL carries
  /// its own signed policy, so we unwrap it and use the CDN directly.
  static String _unwrapSubtitleUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.path.contains('/api/proxy/video')) {
        final inner = uri.queryParameters['url'];
        if (inner != null && inner.isNotEmpty) return inner;
      }
    } catch (_) {}
    return url;
  }
  static Future<String?> _downloadSubtitle(String url) async {
    try {
      final res = await http
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent': _headers['User-Agent']!,
              'Referer': _streamReferer,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.body.isEmpty) return null;
      // Reject HTML error pages masquerading as subtitles.
      final head = res.body.length > 200 ? res.body.substring(0, 200) : res.body;
      final trimmed = head.trimLeft().toLowerCase();
      if (trimmed.startsWith('<html') || trimmed.startsWith('<!doctype')) {
        return null;
      }
      return res.body;
    } catch (_) {
      return null;
    }
  }

  static String? _cachedBase;

  /// Tries each known API base in order, caching the first that answers.
  /// A base counts as working if it returns HTTP 200 with a JSON body —
  /// even `{"ok": false}` proves the host is serving the API.
  static Future<String?> _resolveBase() async {
    if (_cachedBase != null) return _cachedBase;
    for (final base in _bases) {
      try {
        final res = await http
            .get(Uri.parse('$base/api/embed-tmdb/857598'), headers: _headers)
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final obj = jsonDecode(res.body);
          if (obj is Map<String, dynamic> && obj['ok'] == true) {
            _cachedBase = base;
            return base;
          }
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>?> _fetch(String url) async {
    try {
      final res =
          await http.get(Uri.parse(url), headers: _headers).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final obj = jsonDecode(res.body);
      if (obj is! Map<String, dynamic>) return null;
      if (obj['ok'] != true) return null;
      return obj;
    } catch (_) {
      return null;
    }
  }

  static Future<ProviderLoadResult> _toResult(
    Map<String, dynamic>? data,
    String base,
  ) async {
    if (data == null) {
      return const ProviderLoadResult(
        errorMessage: 'NetMirror: no streams found for this title',
      );
    }

    final links = <RegularVideoLinks>[];
    final seen = <String>{};
    final streams = data['streams'];
    if (streams is List) {
      // Highest quality first.
      final sorted = streams.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) =>
            (b['resolution'] as num? ?? 0).compareTo(a['resolution'] as num? ?? 0));
      for (final s in sorted) {
        final url = s['url']?.toString() ?? '';
        if (url.isEmpty) continue;
        final res = s['resolution']?.toString() ?? '';
        final label = res.isNotEmpty ? '${res}p' : 'NetMirror';
        if (!seen.add(label)) continue;
        links.add(
          RegularVideoLinks(
            url: url,
            quality: label,
            isM3U8: url.contains('m3u8'),
            headers: {
              'Referer': _streamReferer,
              'User-Agent': _headers['User-Agent']!,
            },
          ),
        );
      }
    }
    // Fallbacks from top-level fields.
    for (final entry in [
      ('mp4', data['mp4']?.toString() ?? ''),
      ('fallbackHls', data['fallbackHls']?.toString() ?? ''),
    ]) {
      var url = entry.$2;
      if (url.isEmpty) continue;
      if (url.startsWith('/')) url = '$base$url';
      final label = entry.$1 == 'mp4' ? (data['resolution']?.toString().isNotEmpty == true
          ? "${data['resolution']}p"
          : 'NetMirror') : 'HLS';
      if (!seen.add(label)) continue;
      links.add(
        RegularVideoLinks(
          url: url,
          quality: label,
          isM3U8: url.contains('m3u8'),
          headers: {
            'Referer': _streamReferer,
            'User-Agent': _headers['User-Agent']!,
          },
        ),
      );
    }

    if (links.isEmpty) {
      return const ProviderLoadResult(
        errorMessage: 'NetMirror: no playable streams found',
      );
    }

    final subtitles = <RegularSubtitleLinks>[];
    final captions = data['captions'];
    if (captions is List) {
      // Pre-download subtitle text so the player never has to fetch through
      // the proxy itself; downloads run in parallel.
      final pending = <Future<RegularSubtitleLinks?>>[];
      for (final c in captions) {
        if (c is! Map<String, dynamic>) continue;
        var url = c['url']?.toString() ?? '';
        if (url.isEmpty) continue;
        if (url.startsWith('/')) url = '$base$url';
        // Bypass NetMirror's rate-limited subtitle proxy; the inner CDN URL
        // carries its own signed policy and serves the file directly.
        url = _unwrapSubtitleUrl(url);
        final name = c['name']?.toString().trim() ?? '';
        final lang = c['lang']?.toString().trim() ?? '';
        final language =
            name.isNotEmpty ? name : (lang.isNotEmpty ? lang : 'Unknown');
        pending.add(
          _downloadSubtitle(url).then(
            (content) => RegularSubtitleLinks(
              url: url,
              language: language,
              headers: {
                'Referer': _streamReferer,
                'User-Agent': _headers['User-Agent']!,
              },
              content: content,
            ),
          ),
        );
      }
      for (final s in await Future.wait(pending)) {
        if (s != null) subtitles.add(s);
      }
    }

    return ProviderLoadResult(
      success: true,
      videoLinks: links,
      subtitleLinks: subtitles,
    );
  }

  static Future<ProviderLoadResult> loadMovie({
    required int tmdbId,
  }) async {
    final base = await _resolveBase();
    if (base == null) {
      return const ProviderLoadResult(
        errorMessage:
            'NetMirror: cannot reach NetMirror servers — the network may be blocking them',
      );
    }
    final data = await _fetch('$base/api/embed-tmdb/$tmdbId');
    return await _toResult(data, base);
  }

  static Future<ProviderLoadResult> loadEpisode({
    required int tmdbId,
    required int seasonNumber,
    required int episodeNumber,
  }) async {
    final base = await _resolveBase();
    if (base == null) {
      return const ProviderLoadResult(
        errorMessage:
            'NetMirror: cannot reach NetMirror servers — the network may be blocking them',
      );
    }
    final data = await _fetch(
      '$base/api/embed-tmdb/$tmdbId?type=tv&s=$seasonNumber&e=$episodeNumber',
    );
    return await _toResult(data, base);
  }
}
