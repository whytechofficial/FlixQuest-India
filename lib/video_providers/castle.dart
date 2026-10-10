import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart';
import 'package:http/http.dart' as http;
import 'common.dart';

/// Castle TV direct provider (api.fstcy.com).
///
/// India-focused streaming API: title search, AES-128-CBC encrypted JSON
/// envelopes, per-episode stream resolution with language tracks and
/// 1080p/720p/480p variants. Follows the public Castle provider reference.
///
/// Unlike VixSrc (which addresses titles by TMDB id), Castle is searched by
/// title, so callers pass the TMDB title through [title]; the best
/// title match is picked before resolving streams.
abstract final class Castle {
  static const String _base = 'https://api.fstcy.com';
  static const String _package = 'com.external.castle';
  static const String _channel = 'IndiaA';
  static const String _apkSignKey =
      'ED0955EB04E67A1D9F3305B95454FED485261475';
  static const String _pepper = 'T!BgJB';
  static const String _userAgent = 'okhttp/4.9.3';

  static const Duration _timeout = Duration(seconds: 20);
  static const List<int> _resolutions = [3, 2, 1];
  static const Map<int, String> _qualityLabels = {
    3: '1080p',
    2: '720p',
    1: '480p',
  };

  static String? _cachedKey;

  static Map<String, String> get _headers => {
        'User-Agent': _userAgent,
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': '$_base/',
      };

  // -----------------------------------------------------------------
  // Crypto + envelope
  // -----------------------------------------------------------------

  static Future<String> _securityKey() async {
    if (_cachedKey != null) return _cachedKey!;
    try {
      final url = Uri.parse(
        '$_base/v0.1/system/getSecurityKey/1'
        '?channel=$_channel&clientType=1&lang=en-US',
      );
      final res = await http.get(url, headers: _headers).timeout(_timeout);
      if (res.statusCode != 200) {
        throw Exception(
          'Castle servers unreachable (HTTP ${res.statusCode}) — '
          'the network may be blocking api.fstcy.com',
        );
      }
      final obj = jsonDecode(res.body);
      if (obj is! Map<String, dynamic>) {
        throw Exception('Castle servers returned an unexpected response');
      }
      final key = obj['data']?.toString() ?? '';
      if (key.isEmpty) {
        throw Exception('Castle servers refused the handshake');
      }
      _cachedKey = key;
      return key;
    } on Exception {
      rethrow;
    } catch (error) {
      throw Exception(
        'cannot reach Castle servers ($error) — '
        'the network may be blocking api.fstcy.com',
      );
    }
  }

  /// AES-128-CBC decrypt of Castle's envelope. The key material is
  /// base64(securityKey) + pepper, first 16 bytes; the IV is the key itself.
  static String? _decrypt(String blobB64, String keyB64) {
    try {
      final keyBytes = base64Decode(keyB64);
      final material = Uint8List.fromList(
        [...keyBytes, ...utf8.encode(_pepper)],
      );
      final aesBytes = material.sublist(0, 16);
      final encrypter = Encrypter(
        AES(Key(aesBytes), mode: AESMode.cbc),
      );
      final blob = base64Decode(blobB64.trim());
      return encrypter.decrypt(Encrypted(blob), iv: IV(aesBytes));
    } catch (_) {
      return null;
    }
  }

  /// Unwraps Castle's response: either a JSON `{code,msg,data}` envelope
  /// holding the encrypted blob, or the raw blob itself. Returns the inner
  /// `data` object on success.
  static Map<String, dynamic>? _unwrap(String raw, String key) {
    var blob = raw.trim();
    try {
      final obj = jsonDecode(raw);
      if (obj is Map<String, dynamic> && obj['data'] is String) {
        blob = obj['data'] as String;
      }
    } catch (_) {
      // raw body is the blob itself
    }
    final plain = _decrypt(blob, key);
    if (plain == null) return null;
    try {
      final obj = jsonDecode(plain);
      if (obj is Map<String, dynamic>) {
        final inner = obj['data'];
        if (inner is Map<String, dynamic>) return inner;
        return obj;
      }
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>?> _apiGet(String url) async {
    final key = await _securityKey();
    try {
      final res = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) {
        throw Exception('Castle request failed (HTTP ${res.statusCode})');
      }
      return _unwrap(res.body, key);
    } catch (error) {
      if (error is Exception) rethrow;
      throw Exception('Castle request failed ($error)');
    }
  }

  static Future<Map<String, dynamic>?> _apiPost(
    String url,
    Map<String, dynamic> body,
  ) async {
    final key = await _securityKey();
    try {
      final res = await http
          .post(
            Uri.parse(url),
            headers: {
              ..._headers,
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        throw Exception('Castle request failed (HTTP ${res.statusCode})');
      }
      return _unwrap(res.body, key);
    } catch (error) {
      if (error is Exception) rethrow;
      throw Exception('Castle request failed ($error)');
    }
  }

  // -----------------------------------------------------------------
  // Catalog: search / detail
  // -----------------------------------------------------------------

  static String _searchUrl(String title) {
    final q = Uri.encodeComponent(title).replaceAll('+', '%20');
    return '$_base/film-api/v1.1.0/movie/searchByKeyword'
        '?channel=$_channel&clientType=1'
        '&keyword=$q&lang=en-US&mode=1&packageName=$_package'
        '&page=1&size=30';
  }

  static String _detailUrl(String castleId) {
    return '$_base/film-api/v1.9.9/movie'
        '?channel=$_channel&clientType=1&lang=en-US'
        '&movieId=$castleId&packageName=$_package';
  }

  static List<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toList();

  /// Scores how well a Castle result title matches the wanted title.
  /// Exact matches win outright; otherwise prefix matches outrank loose
  /// containment, and token overlap breaks ties. This is order-independent,
  /// unlike taking Castle's first/closest row, whose ordering is unstable.
  static double _matchScore(String wantRaw, String candRaw) {
    final want = _tokens(wantRaw).join();
    final cand = _tokens(candRaw).join();
    if (want.isEmpty || cand.isEmpty) return 0;
    if (cand == want) return 100;
    var score = 0.0;
    if (cand.startsWith(want) || want.startsWith(cand)) {
      score += 40;
    } else if (cand.contains(want) || want.contains(cand)) {
      score += 25;
    }
    final wantToks = _tokens(wantRaw).toSet();
    final candToks = _tokens(candRaw).toSet();
    if (wantToks.isNotEmpty && candToks.isNotEmpty) {
      final inter = wantToks.intersection(candToks).length;
      final union = wantToks.union(candToks).length;
      score += 35 * inter / union;
    }
    return score;
  }

  static Map<String, dynamic>? _pickBestMatch(
    List<dynamic> rows,
    String title,
  ) {
    Map<String, dynamic>? best;
    var bestScore = 0.0;
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final name = row['title']?.toString() ?? '';
      if (name.isEmpty) continue;
      final score = _matchScore(title, name);
      if (score > bestScore) {
        bestScore = score;
        best = row;
        if (score >= 100) break; // exact match: can't do better
      }
    }
    return bestScore > 0 ? best : null;
  }

  static Future<Map<String, dynamic>?> _searchTitle(String title) async {
    final data = await _apiGet(_searchUrl(title));
    final rows = data?['rows'];
    if (rows is! List || rows.isEmpty) return null;
    return _pickBestMatch(rows, title);
  }

  static String _castleIdOf(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    if (id.isNotEmpty) return id;
    return row['redirectId']?.toString() ?? '';
  }

  // -----------------------------------------------------------------
  // Stream resolution
  // -----------------------------------------------------------------

  static Map<String, dynamic> _videoBody({
    required String movieId,
    required String episodeId,
    required int resolution,
    String? languageId,
  }) {
    return {
      'mode': '1',
      'appMarket': 'GuanWang',
      'clientType': '1',
      'woolUser': 'false',
      'apkSignKey': _apkSignKey,
      'androidVersion': '13',
      'movieId': movieId,
      'episodeId': episodeId,
      'isNewUser': 'true',
      'resolution': resolution.toString(),
      'packageName': _package,
      if (languageId != null) 'languageId': languageId,
    };
  }

  static String get _videoUrl => '$_base/film-api/v2.0.1/movie/getVideo2'
      '?clientType=1&packageName=$_package&channel=$_channel&lang=en-US';

  static List<RegularSubtitleLinks> _parseSubtitles(Map<String, dynamic> data) {
    final out = <RegularSubtitleLinks>[];
    final subs = data['subtitles'];
    if (subs is! List) return out;
    for (final s in subs) {
      if (s is! Map<String, dynamic>) continue;
      final url = s['url']?.toString() ?? '';
      if (url.isEmpty) continue;
      out.add(
        RegularSubtitleLinks(
          url: url,
          language: (s['abbreviate']?.toString() ?? '').isNotEmpty
              ? s['abbreviate'].toString()
              : (s['title']?.toString().isNotEmpty == true
                  ? s['title'].toString()
                  : 'Unknown'),
        ),
      );
    }
    return out;
  }

  /// Resolves playable streams for one Castle episode. Tries each language
  /// track at 1080p/720p/480p, keeping the best working variant per
  /// language, and collects subtitles once.
  static Future<ProviderLoadResult> _resolveEpisodeStreams({
    required String movieId,
    required String episodeId,
  }) async {
    final detail = await _apiGet(_detailUrl(movieId));
    final episodes = detail?['episodes'];
    if (episodes is! List) {
      return const ProviderLoadResult(
        errorMessage: 'Castle: episode list not found',
      );
    }

    Map<String, dynamic>? episode;
    for (final ep in episodes) {
      if (ep is Map<String, dynamic> &&
          ep['id']?.toString() == episodeId) {
        episode = ep;
        break;
      }
    }
    if (episode == null) {
      return const ProviderLoadResult(
        errorMessage: 'Castle: episode not found',
      );
    }

    // Build the (language, name) plan like the reference implementation:
    // per-language streams only exist when a track carries its own
    // individual video. Otherwise all tracks share one video, so offering
    // a stream per language would be a lie — one shared stream instead.
    final rawTrackList = <Map<String, dynamic>>[];
    final rawTracks = episode['tracks'];
    if (rawTracks is List) {
      for (final t in rawTracks) {
        if (t is Map<String, dynamic>) rawTrackList.add(t);
      }
    }
    var hasIndividual = false;
    for (final t in rawTrackList) {
      if (t['existIndividualVideo'] == true) {
        hasIndividual = true;
        break;
      }
    }
    final tracks = <Map<String, String?>>[];
    String trackName(Map<String, dynamic> t) {
      final n = t['languageName']?.toString() ?? '';
      if (n.isNotEmpty) return n;
      return t['abbreviate']?.toString() ?? '';
    }

    if (hasIndividual) {
      for (final t in rawTrackList) {
        tracks.add({
          'id': t['languageId']?.toString(),
          'name': trackName(t),
        });
      }
    } else if (rawTrackList.isNotEmpty) {
      // Shared video: keep the first track's language id for the request
      // but don't label the stream with a language we can't deliver.
      tracks.add({'id': rawTrackList.first['languageId']?.toString()});
    } else {
      tracks.add({'id': null});
    }

    final streams = <RegularVideoLinks>[];
    var subtitles = <RegularSubtitleLinks>[];
    var subtitlesCollected = false;
    final seen = <String>{};

    for (final track in tracks) {
      final langId = track['id'];
      final langName = track['name'] ?? '';
      for (final res in _resolutions) {
        Map<String, dynamic>? data;
        try {
          data = await _apiPost(
            _videoUrl,
            _videoBody(
              movieId: movieId,
              episodeId: episodeId,
              resolution: res,
              languageId: langId,
            ),
          );
        } catch (_) {
          continue; // flaky attempt; try the next resolution
        }
        if (data == null) continue;
        final videoUrl = (data['videoUrl']?.toString() ?? '').isNotEmpty
            ? data['videoUrl'].toString()
            : data['url']?.toString() ?? '';
        if (videoUrl.isEmpty) continue;

        if (!subtitlesCollected) {
          subtitles = _parseSubtitles(data);
          subtitlesCollected = true;
        }

        final quality = _qualityLabels[res] ?? '${res}p';
        final label =
            langName.isNotEmpty ? '$quality · $langName' : quality;
        if (!seen.add(label)) continue;
        streams.add(
          RegularVideoLinks(
            url: videoUrl,
            quality: label,
            isM3U8: videoUrl.contains('m3u8'),
            headers: {
              'Referer': '$_base/',
              'User-Agent': _userAgent,
            },
          ),
        );
      }
    }

    if (streams.isEmpty) {
      return const ProviderLoadResult(
        errorMessage:
            'Castle: no playable streams for this title (it may not be '
            'on Castle, or this quality/language is blocked)',
      );
    }
    return ProviderLoadResult(
      success: true,
      videoLinks: streams,
      subtitleLinks: subtitles,
    );
  }

  // -----------------------------------------------------------------
  // Public entry points (mirror VixSrc's contract)
  // -----------------------------------------------------------------

  static Future<ProviderLoadResult> loadMovie({
    required int movieId,
    String? title,
  }) async {
    if (title == null || title.trim().isEmpty) {
      return const ProviderLoadResult(
        errorMessage: 'Castle: title is required for search',
      );
    }
    try {
      final match = await _searchTitle(title.trim());
      if (match == null) {
        return ProviderLoadResult(
          errorMessage: 'Castle: no match found for "${title.trim()}"',
        );
      }
      final castleId = _castleIdOf(match);
      if (castleId.isEmpty) {
        return const ProviderLoadResult(
          errorMessage: 'Castle: invalid match',
        );
      }
      final detail = await _apiGet(_detailUrl(castleId));
      final episodes = detail?['episodes'];
      if (episodes is! List || episodes.isEmpty) {
        return const ProviderLoadResult(
          errorMessage: 'Castle: no episodes found',
        );
      }
      final ep = episodes.first;
      if (ep is! Map<String, dynamic>) {
        return const ProviderLoadResult(
          errorMessage: 'Castle: invalid episode',
        );
      }
      final episodeId = ep['id']?.toString() ?? '';
      if (episodeId.isEmpty) {
        return const ProviderLoadResult(
          errorMessage: 'Castle: invalid episode id',
        );
      }
      return _resolveEpisodeStreams(
        movieId: castleId,
        episodeId: episodeId,
      );
    } catch (error) {
      return ProviderLoadResult(errorMessage: 'Castle: $error');
    }
  }

  static Future<ProviderLoadResult> loadEpisode({
    required int tvId,
    required int seasonNumber,
    required int episodeNumber,
    String? title,
  }) async {
    if (title == null || title.trim().isEmpty) {
      return const ProviderLoadResult(
        errorMessage: 'Castle: title is required for search',
      );
    }
    if (seasonNumber <= 0 || episodeNumber <= 0) {
      return const ProviderLoadResult(
        errorMessage: 'Castle: invalid season/episode number',
      );
    }
    try {
      final match = await _searchTitle(title.trim());
      if (match == null) {
        return ProviderLoadResult(
          errorMessage: 'Castle: no match found for "${title.trim()}"',
        );
      }
      var seriesId = _castleIdOf(match);
      if (seriesId.isEmpty) {
        return const ProviderLoadResult(
          errorMessage: 'Castle: invalid match',
        );
      }

      // Seasons on Castle carry their own ids; resolve the target season.
      var detail = await _apiGet(_detailUrl(seriesId));
      final seasons = detail?['seasons'];
      if (seasons is List && seasons.length > 1) {
        for (final s in seasons) {
          if (s is Map<String, dynamic> &&
              (s['number']?.toString() == seasonNumber.toString())) {
            final seasonId = s['movieId']?.toString() ?? '';
            if (seasonId.isNotEmpty) {
              seriesId = seasonId;
              detail = await _apiGet(_detailUrl(seriesId));
              break;
            }
          }
        }
      }

      final episodes = detail?['episodes'];
      if (episodes is! List || episodes.isEmpty) {
        return const ProviderLoadResult(
          errorMessage: 'Castle: no episodes found',
        );
      }
      String episodeId = '';
      for (final ep in episodes) {
        if (ep is Map<String, dynamic> &&
            ep['number']?.toString() == episodeNumber.toString()) {
          episodeId = ep['id']?.toString() ?? '';
          break;
        }
      }
      if (episodeId.isEmpty) {
        return const ProviderLoadResult(
          errorMessage: 'Castle: episode not found',
        );
      }
      return _resolveEpisodeStreams(
        movieId: seriesId,
        episodeId: episodeId,
      );
    } catch (error) {
      return ProviderLoadResult(errorMessage: 'Castle: $error');
    }
  }
}
