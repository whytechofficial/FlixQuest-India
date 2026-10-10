import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'common.dart';

/// MX Player Direct — streams movies and series from MX Player's web API.
///
/// Flow:
/// 1. Search: POST /v1/web/search/resultv2?query={title} → content IDs.
/// 2. Detail: GET /v1/web/detail/video?type={movie|episode}&id={id} → stream URLs.
/// 3. Resolve the HLS URL (priority: hls.high → thirdParty → mxplay).
///
/// Notes:
/// - No login required; a random UUID is sent as the user ID.
/// - Stream URLs are geo-fenced to India — the `stream` object comes back
///   empty outside India. Search and metadata work globally.
/// - DRM-protected titles are skipped with a clear error.
/// - Subtitles ride inside the HLS manifest.
class MxPlayerDirect {
  static const _apiBase = 'https://api.mxplayer.in/v1/web';
  static const _timeout = Duration(seconds: 30);

  static final _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Content-Type': 'application/json',
    'Referer': 'https://www.mxplayer.in/',
    'Origin': 'https://www.mxplayer.in',
  };

  /// Anonymous user ID — MX Player accepts any random UUID.
  static String _newUserId() {
    final r = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }

  static String _searchParams(String userId) =>
      'device-density=2&platform=com.mxplay.desktop'
      '&content-languages=hi,en,ta,te,ml,kn'
      '&kids-mode-enabled=false&userid=$userId';

  /// Order-independent title scorer (same approach as Castle).
  static double _titleScore(String candidate, String target) {
    final c = candidate.toLowerCase().trim();
    final t = target.toLowerCase().trim();
    if (c.isEmpty || t.isEmpty) return 0;
    if (c == t) return 100;
    // Strip common suffixes like " (2022)" or " - movie".
    String norm(String s) => s
        .replaceAll(RegExp(r'\s*\(\d{4}\)\s*$'), '')
        .replaceAll(RegExp(r'\s*-\s*movie\s*$'), '')
        .trim();
    if (norm(c) == norm(t)) return 95;
    if (c.startsWith(t) || t.startsWith(c)) return 80;
    if (c.contains(t) || t.contains(c)) return 60;
    final cTokens = c.split(RegExp(r'\s+')).toSet();
    final tTokens = t.split(RegExp(r'\s+')).toSet();
    final overlap = cTokens.intersection(tTokens).length;
    if (overlap == 0) return 0;
    return 40 * (overlap / max(tTokens.length, 1));
  }

  /// Searches MX Player for [title], returning the best matching item of
  /// [wantedType] ('movie' or 'tvshow'), or null.
  static Future<Map<String, dynamic>?> _search(
    String title,
    String wantedType,
  ) async {
    final userId = _newUserId();
    final uri = Uri.parse(
      '$_apiBase/search/resultv2?query=${Uri.encodeComponent(title)}&${_searchParams(userId)}',
    );
    try {
      final res = await http
          .post(uri, headers: _headers, body: '{}')
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final obj = jsonDecode(res.body);
      if (obj is! Map<String, dynamic>) return null;

      Map<String, dynamic>? best;
      double bestScore = 0;
      final sections = obj['sections'];
      if (sections is List) {
        for (final section in sections) {
          if (section is! Map<String, dynamic>) continue;
          final items = section['items'];
          if (items is! List) continue;
          for (final item in items) {
            if (item is! Map<String, dynamic>) continue;
            if (item['type']?.toString() != wantedType) continue;
            final itemTitle = item['title']?.toString() ?? '';
            final score = _titleScore(itemTitle, title);
            if (score > bestScore) {
              bestScore = score;
              best = item;
            }
          }
        }
      }
      // Require a reasonably confident match.
      return bestScore >= 40 ? best : null;
    } catch (_) {
      return null;
    }
  }

  /// Fetches the detail object (with stream URLs) for a content ID.
  /// The API returns the detail fields at the top level (no `data` wrapper).
  static Future<Map<String, dynamic>?> _detail(
    String type,
    String id,
  ) async {
    final userId = _newUserId();
    final uri = Uri.parse(
      '$_apiBase/detail/video?type=$type&id=$id&${_searchParams(userId)}',
    );
    try {
      final res = await http.get(uri, headers: _headers).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final obj = jsonDecode(res.body);
      if (obj is! Map<String, dynamic>) return null;
      // Sanity check: a valid detail has an id and title.
      if (obj['id']?.toString().isEmpty != false) return null;
      return obj;
    } catch (_) {
      return null;
    }
  }

  /// Resolves the best HLS URL from a detail `stream` object.
  static String? _resolveHls(Map<String, dynamic> stream) {
    const cdnBase = 'https://d3sgzbosmwirao.cloudfront.net/';
    String norm(String? u) {
      if (u == null || u.isEmpty) return '';
      return u.startsWith('http') ? u : '$cdnBase${u.replaceFirst(RegExp(r'^/+'), '')}';
    }

    final hls = stream['hls'];
    if (hls is Map<String, dynamic>) {
      for (final key in ['high', 'base', 'main']) {
        final u = norm(hls[key]?.toString());
        if (u.isNotEmpty) return u;
      }
    }
    final third = stream['thirdParty'];
    if (third is Map<String, dynamic>) {
      final u = norm(third['hlsUrl']?.toString());
      if (u.isNotEmpty) return u;
    }
    final mxplay = stream['mxplay'];
    if (mxplay is Map<String, dynamic>) {
      final hls2 = mxplay['hls'];
      if (hls2 is Map<String, dynamic>) {
        for (final key in ['high', 'base', 'main']) {
          final u = norm(hls2[key]?.toString());
          if (u.isNotEmpty) return u;
        }
      }
    }
    return null;
  }

  static ProviderLoadResult _streamResult(
    Map<String, dynamic>? data,
    String label,
  ) {
    if (data == null) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: title not found',
      );
    }
    final stream = data['stream'];
    if (stream is! Map<String, dynamic> || stream.isEmpty) {
      return const ProviderLoadResult(
        errorMessage:
            'MX Player: no streams — this title may be region-locked or unavailable',
      );
    }
    if (stream['drmProtect'] == true) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: this title is DRM-protected',
      );
    }
    final hlsUrl = _resolveHls(stream);
    if (hlsUrl == null || hlsUrl.isEmpty) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: no playable stream found',
      );
    }
    return ProviderLoadResult(
      success: true,
      videoLinks: [
        RegularVideoLinks(
          url: hlsUrl,
          quality: label,
          isM3U8: true,
        ),
      ],
    );
  }

  static Future<ProviderLoadResult> loadMovie({
    required int tmdbId,
    String? title,
  }) async {
    if (title == null || title.isEmpty) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: no title to search for',
      );
    }
    final item = await _search(title, 'movie');
    if (item == null) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: no matching movie found',
      );
    }
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: no matching movie found',
      );
    }
    final data = await _detail('movie', id);
    return _streamResult(data, item['title']?.toString() ?? 'MX Player');
  }

  /// Finds the episode ID for a TV show, then resolves its stream.
  static Future<ProviderLoadResult> loadTvEpisode({
    required int tmdbId,
    required int season,
    required int episode,
    String? title,
  }) async {
    if (title == null || title.isEmpty) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: no title to search for',
      );
    }
    final item = await _search(title, 'tvshow');
    if (item == null) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: no matching series found',
      );
    }
    final showId = item['id']?.toString() ?? '';
    if (showId.isEmpty) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: no matching series found',
      );
    }
    final epId = await _findEpisodeId(showId, season, episode);
    if (epId == null) {
      return const ProviderLoadResult(
        errorMessage: 'MX Player: episode not found',
      );
    }
    final data = await _detail('episode', epId);
    return _streamResult(
      data,
      '${item['title']?.toString() ?? 'MX Player'} S${season}E$episode',
    );
  }

  /// Resolves a show → season → episode ID via the detail API.
  static Future<String?> _findEpisodeId(
    String showId,
    int season,
    int episode,
  ) async {
    // The show detail contains seasons; each season lists episodes.
    // We walk the `tabs` API pagination (10 items/page via `next` token).
    final userId = _newUserId();
    try {
      final showUri = Uri.parse(
        '$_apiBase/detail/video?type=tvshow&id=$showId&${_searchParams(userId)}',
      );
      final showRes = await http
          .get(showUri, headers: _headers)
          .timeout(_timeout);
      if (showRes.statusCode != 200) return null;
      final showData = jsonDecode(showRes.body);
      if (showData is! Map<String, dynamic>) return null;

      // Find the season tab matching the requested season number.
      final tabs = showData['tabs'];
      String? seasonApi;
      if (tabs is List) {
        for (final tab in tabs) {
          if (tab is! Map<String, dynamic>) continue;
          final tabTitle = tab['title']?.toString().toLowerCase() ?? '';
          final seq = tab['sequence'];
          final matches = (seq is num && seq.toInt() == season) ||
              tabTitle.contains('season $season');
          if (matches) {
            seasonApi = tab['api']?.toString();
            break;
          }
        }
        seasonApi ??= (tabs.isNotEmpty && tabs.first is Map<String, dynamic>)
            ? (tabs.first as Map<String, dynamic>)['api']?.toString()
            : null;
      }
      if (seasonApi == null || seasonApi.isEmpty) return null;

      // Paginate episodes until we find the right sequence number.
      String? next;
      do {
        var api = seasonApi;
        if (!api.startsWith('http')) {
          api = '$_apiBase/${api.replaceFirst(RegExp(r'^/+'), '')}';
        }
        final sep = api.contains('?') ? '&' : '?';
        final pageUri = Uri.parse(
          next == null
              ? '$api$sep${_searchParams(userId)}'
              : '$api${sep}next=${Uri.encodeComponent(next)}&${_searchParams(userId)}',
        );
        final pageRes = await http
            .get(pageUri, headers: _headers)
            .timeout(_timeout);
        if (pageRes.statusCode != 200) return null;
        final pageObj = jsonDecode(pageRes.body);
        if (pageObj is! Map<String, dynamic>) return null;
        final items = pageObj['items'];
        if (items is List) {
          for (final it in items) {
            if (it is! Map<String, dynamic>) continue;
            final seq = it['sequence'];
            if (seq is num && seq.toInt() == episode) {
              final id = it['id']?.toString();
              if (id != null && id.isNotEmpty) return id;
            }
          }
        }
        final n = pageObj['next'];
        next = n is String && n.isNotEmpty ? n : null;
      } while (next != null);
    } catch (_) {}
    return null;
  }
}
