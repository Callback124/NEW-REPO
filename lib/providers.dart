import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'store.dart';

/* ---------- networking ---------- */

final Map<String, Future<dynamic>> _memo = {};

Future<dynamic> getJson(String url, {int timeoutSec = 15}) async {
  try {
    final r = await http
        .get(Uri.parse(url), headers: {'Accept': 'application/json'})
        .timeout(Duration(seconds: timeoutSec));
    if (r.statusCode != 200) throw ProviderError('HTTP ${r.statusCode}');
    return jsonDecode(utf8.decode(r.bodyBytes));
  } on ProviderError {
    rethrow;
  } on TimeoutException {
    throw ProviderError('Request timed out');
  } on FormatException {
    throw ProviderError('The server did not return valid JSON');
  } catch (_) {
    throw ProviderError('Could not reach the server');
  }
}

Future<dynamic> cachedJson(String url) => _memo.putIfAbsent(
      url,
      () => getJson(url).catchError((Object e) {
        _memo.remove(url);
        throw e;
      }),
    );

String strip(dynamic v) {
  final s = v is List ? v.join(' ') : (v?.toString() ?? '');
  return s
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _natKey(String s) =>
    s.replaceAllMapped(RegExp(r'\d+'), (m) => m[0]!.padLeft(8, '0'));

class _Safe {
  _Safe(this.items, this.error);
  final List<Item> items;
  final Object? error;
}

Future<_Safe> _safe(Future<List<Item>> f) async {
  try {
    return _Safe(await f, null);
  } catch (e) {
    return _Safe(const [], e);
  }
}

Future<List<Shelf>> shelvesFrom(
    List<MapEntry<String, Future<List<Item>>>> entries) async {
  final res = await Future.wait(entries.map((e) => _safe(e.value)));
  final out = <Shelf>[];
  Object? err;
  for (var i = 0; i < res.length; i++) {
    if (res[i].error != null) {
      err = res[i].error;
    } else if (res[i].items.isNotEmpty) {
      out.add(Shelf(entries[i].key, res[i].items));
    }
  }
  if (out.isEmpty && err != null) {
    throw err is ProviderError ? err : ProviderError(err.toString());
  }
  return out;
}

/* ---------- adapter contract ---------- */

abstract class Adapter {
  Future<List<Shelf>> home(ProviderDef p);
  Future<List<Item>> search(ProviderDef p, String q);
  Future<Item> detail(ProviderDef p, Item item);
  Future<List<Source>> sources(ProviderDef p, Item item, Episode? ep);
}

Adapter adapterFor(ProviderDef p) => switch (p.kind) {
      'moviebox' => MovieBoxAdapter(),
      'stremio' => StremioAdapter(),
      'json' => JsonAdapter(),
      _ => JsonAdapter(),
    };

Future<Item> detailOf(Item item) async {
  final p = app.providerById(item.pid);
  if (p == null) throw ProviderError('This provider was removed.');
  return adapterFor(p).detail(p, item);
}

Future<List<Source>> getSources(Item item, Episode? ep) async {
  final p = app.providerById(item.pid);
  if (p == null) throw ProviderError('This provider was removed.');
  return adapterFor(p).sources(p, item, ep);
}

/* ---------- MovieBox built-in provider ---------- */

class MovieBoxPageResult {
  const MovieBoxPageResult(this.items, this.hasMore);
  final List<Item> items;
  final bool hasMore;
}

class MovieBoxAdapter extends Adapter {
  static const _base = 'https://h5-api.aoneroom.com/wefeed-h5api-bff';
  static const _web = 'https://movieboxph.org';
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36';
  static const _tokenKey = 'moviebox_guest_token';
  static const _tokenTimeKey = 'moviebox_guest_token_time';
  static const _ttlMs = 45 * 60 * 1000;
  static final http.Client _client = http.Client();
  static Future<String>? _tokenFlight;

  Map<String, String> _headers() => {
    'User-Agent': _ua, 'Origin': _web, 'Referer': '$_web/',
    'x-client-info': '{"timezone":"Asia/Calcutta"}',
    'x-request-lang': 'en', 'Accept': 'application/json', 'Connection': 'close',
  };

  String _clientToken() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final reversed = now.toString().split('').reversed.join();
    return now.toString() + ',' + md5.convert(utf8.encode(reversed)).toString();
  }

  Future<String> _getToken({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (force) {
      await prefs.remove(_tokenKey);
      await prefs.remove(_tokenTimeKey);
    } else {
      final saved = prefs.getString(_tokenKey) ?? '';
      final savedAt = prefs.getInt(_tokenTimeKey) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (saved.isNotEmpty && age >= 0 && age < _ttlMs) return saved;
    }
    if (_tokenFlight != null) return _tokenFlight!;
    final future = _fetchToken();
    _tokenFlight = future;
    try { return await future; } finally { _tokenFlight = null; }
  }

  Future<String> _fetchToken() async {
    final prefs = await SharedPreferences.getInstance();
    Object? lastError;
    for (final url in [
      _web + '/wefeed-h5api-bff/home?page=1&perPage=1',
      _base + '/home?page=1&perPage=1',
      _web + '/',
    ]) {
      try {
        final response = await _client.get(Uri.parse(url), headers: _headers())
            .timeout(const Duration(seconds: 20));
        String? token;
        final xUser = response.headers['x-user'];
        if (xUser != null) {
          try { token = (jsonDecode(xUser) as Map)['token']?.toString(); } catch (_) {}
        }
        if (token == null || token.isEmpty) {
          final cookies = response.headers['set-cookie'] ?? '';
          final match = RegExp(r'(?:^|[,;]\s*)token=([^;,\s]+)').firstMatch(cookies);
          token = match?.group(1);
        }
        if ((token == null || token.isEmpty) && response.body.isNotEmpty) {
          token = RegExp(r'"token"\s*:\s*"([^"]+)"')
                  .firstMatch(response.body)?.group(1) ??
              RegExp(r'token=([A-Za-z0-9._-]+)')
                  .firstMatch(response.body)?.group(1);
        }
        if (token != null && token.isNotEmpty) {
          await prefs.setString(_tokenKey, token);
          await prefs.setInt(_tokenTimeKey, DateTime.now().millisecondsSinceEpoch);
          return token;
        }
        lastError = ProviderError('Token bootstrap HTTP ' + response.statusCode.toString() + ': x-user/token cookie missing.');
      } catch (e) { lastError = e; }
    }
    throw ProviderError('MovieBox guest token unavailable. ' + lastError.toString());
  }

  Future<http.Response> _request(String path, {
    String method = 'GET', Map<String, String>? query,
    Map<String, dynamic>? body, bool retry = true, String? referer,
  }) async {
    final uri = Uri.parse(_base + '/' + path).replace(queryParameters: query);
    final token = await _getToken();
    final isSearchEndpoint = path == 'subject/search' && method == 'POST';
    final headers = _headers()
      ..addAll({
        'Authorization': 'Bearer ' + token,
        'Cookie': 'token=' + token + '; moviebox_web_tk=' + token + '; NEXT_LOCALE=en',
      });
    if (referer != null && referer.isNotEmpty) headers['Referer'] = referer;
    // MovieBox rejects x-client-token on POST /subject/search.
    if (!isSearchEndpoint) headers['x-client-token'] = _clientToken();
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (method == 'POST') {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body ?? const {});
    }
    http.Response response;
    try {
      final streamed = await _client.send(request).timeout(const Duration(seconds: 25));
      response = await http.Response.fromStream(streamed);
    } catch (_) {
      if (isSearchEndpoint) rethrow;
      final fallbackUri = Uri.parse(_web + '/wefeed-h5api-bff/' + path)
          .replace(queryParameters: query);
      final fallbackRequest = http.Request(method, fallbackUri)..headers.addAll(headers);
      if (method == 'POST') {
        fallbackRequest.headers['Content-Type'] = 'application/json; charset=utf-8';
        fallbackRequest.body = jsonEncode(body ?? const {});
      }
      final fallbackStream = await _client.send(fallbackRequest).timeout(const Duration(seconds: 25));
      response = await http.Response.fromStream(fallbackStream);
    }
    if (!isSearchEndpoint &&
        (response.statusCode == 400 || response.statusCode == 403 || response.statusCode >= 500)) {
      final fallbackUri = Uri.parse(_web + '/wefeed-h5api-bff/' + path)
          .replace(queryParameters: query);
      final fallbackRequest = http.Request(method, fallbackUri)..headers.addAll(headers);
      if (method == 'POST') {
        fallbackRequest.headers['Content-Type'] = 'application/json; charset=utf-8';
        fallbackRequest.body = jsonEncode(body ?? const {});
      }
      final fallbackStream = await _client.send(fallbackRequest).timeout(const Duration(seconds: 25));
      response = await http.Response.fromStream(fallbackStream);
    }
    final responseText = utf8.decode(response.bodyBytes);
    final invalid = response.statusCode == 401 ||
        responseText.toLowerCase().contains('invalid token') ||
        responseText.toLowerCase().contains('token expired');
    if (invalid && retry) {
      await _getToken(force: true);
      return _request(path, method: method, query: query, body: body, retry: false, referer: referer);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProviderError('MovieBox HTTP ' + response.statusCode.toString() +
          '\n' + method + ' ' + uri.toString() + '\n' +
          (responseText.isEmpty ? 'Empty response body' : responseText));
    }
    dynamic decoded;
    try { decoded = jsonDecode(responseText); }
    catch (_) { throw ProviderError('MovieBox invalid JSON for ' + uri.toString() + '\n' + responseText); }
    if (decoded is Map && decoded['code'] != null &&
        decoded['code'].toString() != '0' &&
        !decoded['message'].toString().toLowerCase().contains('success')) {
      final reason = (decoded['message'] ?? decoded['reason'] ?? decoded['code']).toString();
      if (retry && reason.toLowerCase().contains('token')) {
        await _getToken(force: true);
        return _request(path, method: method, query: query, body: body, retry: false, referer: referer);
      }
      throw ProviderError('MovieBox API error (' + decoded['code'].toString() + '): ' + reason + '\n' + responseText);
    }
    return response;
  }

  Future<dynamic> _json(String path, {String method = 'GET',
      Map<String, String>? query, Map<String, dynamic>? body, String? referer}) async {
    final response = await _request(path, method: method, query: query, body: body, referer: referer);
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  String? _image(dynamic value) {
    if (value is Map) return value['url']?.toString();
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  Item _item(ProviderDef p, Map raw) {
    final subject = raw['subject'] is Map ? raw['subject'] as Map : raw;
    final code = int.tryParse(subject['subjectType']?.toString() ?? '') ?? 1;
    final date = subject['releaseDate']?.toString() ?? '';
    final genre = subject['genre'];
    return Item(
      pid: p.id, id: (subject['subjectId'] ?? raw['subjectId'] ?? '').toString(),
      type: code == 2 ? 'series' : 'movie', subjectType: code,
      title: (subject['title'] ?? raw['title'] ?? 'Untitled').toString(),
      poster: _image(subject['cover']) ?? _image(raw['cover']) ?? _image(raw['image']),
      bg: _image(subject['stills']) ?? _image(subject['cover']) ?? _image(raw['image']),
      year: date.length >= 4 ? date.substring(0, 4) : subject['year']?.toString(),
      rating: (subject['imdbRatingValue'] ?? subject['score'] ?? subject['imdbRating'])?.toString(),
      plot: subject['description']?.toString(),
      genres: (genre is String ? genre.split(',') :
          (subject['genres'] is List ? (subject['genres'] as List).map((e) => e.toString()).toList() : const <String>[]))
          .map((e) => e.trim()).where((e) => e.isNotEmpty).take(4).toList(),
      detailPath: (subject['detailPath'] ?? raw['detailPath'])?.toString(),
      corner: ((subject['corner'] ?? raw['corner'])?.toString().trim().isNotEmpty ?? false)
          ? (subject['corner'] ?? raw['corner']).toString().trim()
          : null,
    );
  }

  @override
  Future<List<Shelf>> home(ProviderDef p) async {
    final json = await _json('home');
    final data = json['data'];
    final ops = data is Map ? (data['operatingList'] as List? ?? const []) : const [];
    final result = <Shelf>[];
    for (final op in ops.whereType<Map>()) {
      final type = (op['type'] ?? op['moduleType'] ?? '').toString().toUpperCase();
      final banner = op['banner'];
      dynamic bannerItems;
      if (banner is Map) {
        bannerItems = banner['items'] ?? banner['subjects'] ?? banner['list'] ?? banner['data'];
      } else if (banner is List) {
        bannerItems = banner;
      }
      // The banner carousel data is deliberately rendered as its own normal shelf.
      if (bannerItems is List && bannerItems.isNotEmpty) {
        final items = bannerItems.whereType<Map>().map((x) => _item(p, x))
            .where((x) => x.id.isNotEmpty).toList();
        if (items.isNotEmpty) {
          final bannerTitle = (banner is Map ? banner['title'] : null) ??
              op['title'] ?? op['name'] ?? 'Featured';
          result.add(Shelf(bannerTitle.toString().trim().isEmpty
              ? 'Featured' : bannerTitle.toString().trim(), items));
        }
      }
      final normalItems = op['subjects'] is List && (op['subjects'] as List).isNotEmpty
          ? op['subjects']
          : op['items'] is List && (op['items'] as List).isNotEmpty
              ? op['items']
              : (type == 'BANNER' ? (op['list'] ?? op['data']) : null);
      if (normalItems is List && normalItems.isNotEmpty) {
        final items = normalItems.whereType<Map>().map((x) => _item(p, x))
            .where((x) => x.id.isNotEmpty).toList();
        if (items.isNotEmpty) {
          final title = (op['title'] ?? op['name'] ??
              (type == 'APPOINTMENT_LIST' ? 'Coming Soon' :
                  type == 'BANNER' ? 'Featured' : 'Movies & Series')).toString().trim();
          result.add(Shelf(title.isEmpty ? 'Movies & Series' : title, items,
              genreTopId: op['genreTopId']?.toString()));
        }
      }
    }
    if (result.isEmpty) throw ProviderError('MovieBox returned no usable home rows.');
    return result;
  }
  @override
  Future<List<Item>> search(ProviderDef p, String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // Official MovieBox search endpoint: POST /subject/search.
    // Do not send x-client-token and do not fall back to the obsolete GET /search.
    final json = await _json('subject/search', method: 'POST',
        body: {'keyword': q, 'page': 1, 'perPage': 20});
    final data = json is Map ? json['data'] : null;
    final raw = data is Map ? (data['items'] ?? data['list'] ?? data['subjectList']) : null;
    final items = raw is List ? raw : const <dynamic>[];
    return items.whereType<Map>().map((x) => _item(p, x)).where((x) => x.id.isNotEmpty).toList();
  }

  Future<List<String>> suggestions(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    dynamic json;
    Object? getError;
    try {
      json = await _json('subject/search-suggest',
          query: {'keyword': q, 'perPage': '10'});
    } catch (e) {
      getError = e;
      json = await _json('subject/search-suggest', method: 'POST',
          body: {'keyword': q, 'perPage': 10});
    }
    final data = json is Map ? json['data'] : null;
    final items = data is Map ? (data['items'] as List? ?? const []) : const [];
    final words = items.whereType<Map>().map((x) => x['word']?.toString() ?? '')
        .where((x) => x.isNotEmpty).toList();
    if (words.isEmpty && getError != null) {
      throw ProviderError('MovieBox suggestions failed: $getError');
    }
    return words;
  }

  Future<MovieBoxPageResult> viewMore(ProviderDef p, String id, {int page = 1, int perPage = 20}) async {
    final json = await _json('ranking-list/content',
        query: {'id': id, 'page': page.toString(), 'perPage': perPage.toString()});
    final data = json['data'];
    final items = data is Map ? (data['subjectList'] as List? ?? const []) : const [];
    final pager = data is Map && data['pager'] is Map ? data['pager'] as Map : const {};
    final hasMore = pager['hasMore'] == true || pager['hasMore'].toString() == 'true';
    return MovieBoxPageResult(
      items.whereType<Map>().map((x) => _item(p, x)).where((x) => x.id.isNotEmpty).toList(),
      hasMore,
    );
  }

  @override
  Future<Item> detail(ProviderDef p, Item item) async {
    if ((item.detailPath ?? '').isEmpty) throw ProviderError('MovieBox title has no detailPath.');
    final json = await _json('detail', query: {
      'detailPath': item.detailPath!, 'subjectId': item.id,
    });
    final data = json['data'];
    final subject = data is Map && data['subject'] is Map ? data['subject'] as Map : const {};
    final resource = data is Map && data['resource'] is Map ? data['resource'] as Map : const {};
    final eps = <Episode>[];
    for (final season in (resource['seasons'] as List? ?? const []).whereType<Map>()) {
      final sn = (season['se'] as num?)?.toInt() ?? 1;
      final maxEp = (season['maxEp'] as num?)?.toInt() ?? 0;
      for (var n = 1; n <= maxEp; n++) {
        eps.add(Episode(id: 's' + sn.toString() + 'e' + n.toString(),
            season: sn, episode: n, title: 'Episode ' + n.toString()));
      }
    }
    return item.copyWith(
      title: subject['title']?.toString(), plot: subject['description']?.toString(),
      poster: _image(subject['cover']) ?? item.poster,
      bg: _image(subject['stills']) ?? item.bg,
      year: (subject['releaseDate']?.toString().length ?? 0) >= 4
          ? subject['releaseDate'].toString().substring(0, 4) : item.year,
      rating: (subject['imdbRatingValue'] ?? subject['score'])?.toString() ?? item.rating,
      episodes: eps,
      dubs: (subject['dubs'] as List? ?? const []).whereType<Map>().map((d) => DubOption(
        subjectId: (d['subjectId'] ?? item.id).toString(),
        language: (d['lanName'] ?? d['lanCode'] ?? 'Original').toString(),
        detailPath: (d['detailPath'] ?? item.detailPath ?? '').toString(),
        original: d['original'] == true,
      )).toList(),
    );
  }

  @override
  Future<List<Source>> sources(ProviderDef p, Item item, Episode? ep) async {
    final series = item.subjectType == 2 || item.type == 'series';
    final se = series ? (ep?.season ?? 1) : 0;
    final number = series ? (ep?.episode ?? 1) : 0;
    const playerHeaders = {
      'User-Agent': 'okhttp/4.12.0',
      'Referer': 'https://movieboxph.org/',
      'Origin': 'https://movieboxph.org',
    };
    Future<List<Source>> fetch(int season, int episode) async {
      final playPath = item.detailPath ?? '';
      final json = await _json('subject/play', query: {
        'subjectId': item.id, 'detailPath': playPath,
        'se': season.toString(), 'ep': episode.toString(),
      }, referer: '$_web/play/$playPath');
      final data = json is Map ? json['data'] : null;
      final out = <Source>[];
      final seen = <String>{};
      void addUrl(dynamic value, {String label = 'Auto', bool streamContext = false}) {
        if (value is Map) {
          for (final key in ['url', 'playUrl', 'link', 'src', 'file', 'masterUrl']) {
            if (value[key] != null) addUrl(value[key], label: label, streamContext: streamContext);
          }
          return;
        }
        if (value is! String || !isHttp(value) || !seen.add(value)) return;
        final lower = value.toLowerCase();
        final cleanUrl = lower.split('?').first;
        final hint = label.toLowerCase();
        final hls = cleanUrl.endsWith('.m3u8') || hint.contains('hls') ||
            hint.contains('mpegurl');
        final dash = cleanUrl.endsWith('.mpd') || hint.contains('dash');
        final mp4 = cleanUrl.endsWith('.mp4') || hint.contains('mp4') ||
            lower.contains('hakunaymatata.com');
        // Stream arrays may contain signed URLs or extension-less CDN paths.
        if (!hls && !dash && !mp4 && !streamContext) return;
        final kind = hls ? 'HLS' : dash ? 'DASH' : 'MP4';
        out.add(Source.clean(name: '$label · $kind',
            url: value, headers: playerHeaders));
      }
      void scan(dynamic node, [String label = 'Auto', int depth = 0, bool streamContext = false]) {
        if (depth > 7) return;
        if (node is List) {
          for (final value in node) { scan(value, label, depth + 1, streamContext); }
        } else if (node is Map) {
          final format = (node['format'] ?? node['mimeType'] ?? node['type'] ?? '').toString();
          final quality = (node['resolution'] ?? node['resolutions'] ??
              node['quality'] ?? format).toString().isEmpty
              ? label
              : (node['resolution'] ?? node['resolutions'] ?? node['quality'] ?? format).toString();
          const urlKeys = ['url', 'playUrl', 'link', 'src', 'file', 'masterUrl', 'downloadUrl'];
          final streamLabel = format.isNotEmpty ? '$quality $format' : quality;
          for (final key in urlKeys) {
            if (node[key] != null) addUrl(node[key], label: streamLabel, streamContext: streamContext);
          }
          for (final entry in node.entries) {
            if (urlKeys.contains(entry.key) || entry.value == null) continue;
            final key = entry.key.toLowerCase();
            final isStreamBranch = streamContext ||
                ['streams', 'hls', 'dash', 'mp4', 'sources', 'source', 'playlist',
                 'playlist', 'playlistinfo', 'playinfo', 'playsource',
                 'playsources', 'videos', 'video', 'qualities', 'urlinfo']
                    .contains(key);
            if (entry.value is Map || entry.value is List) {
              final childLabel = key == 'hls' ? 'HLS' : key == 'dash' ? 'DASH' :
                  key == 'mp4' ? 'MP4' : quality;
              scan(entry.value, childLabel, depth + 1, isStreamBranch);
            }
          }
        }
      }
      scan(data);
      return out;
    }
    Object? firstError;
    var streams = <Source>[];
    try { streams = await fetch(se, number); } catch (e) { firstError = e; }
    if (streams.isEmpty) {
      try { streams = await fetch(se == 0 ? 1 : 0, number == 0 ? 1 : 0); }
      catch (e) { firstError ??= e; }
    }
    if (streams.isEmpty && firstError != null) {
      throw ProviderError('MovieBox playback request failed: $firstError');
    }
    if (streams.isEmpty) {
      throw ProviderError('MovieBox returned no MP4/HLS sources. subjectId=' + item.id +
          ', detailPath=' + (item.detailPath ?? 'missing') + '. The play API returned no recognized .mp4/.m3u8 URL.');
    }
    return streams;
  }
}

/* ---------- Stremio-compatible addons ---------- */

class StremioAdapter extends Adapter {
  String _base(ProviderDef p) => p.url!
      .replaceAll(RegExp(r'/manifest\.json.*$'), '')
      .replaceAll(RegExp(r'/+$'), '');

  List<Map> _catalogs(ProviderDef p) =>
      ((p.manifest?['catalogs'] as List?) ?? []).whereType<Map>().toList();

  Item _toItem(ProviderDef p, Map m, String type) => Item(
        pid: p.id,
        id: m['id'].toString(),
        type: (m['type'] ?? type).toString(),
        title: (m['name'] ?? m['id']).toString(),
        poster: m['poster']?.toString(),
        year: (m['releaseInfo'] ?? m['year'] ?? '').toString(),
        plot: m['description']?.toString(),
      );

  List<Item> _metas(ProviderDef p, dynamic j, String type) =>
      ((j['metas'] as List?) ?? [])
          .whereType<Map>()
          .map((m) => _toItem(p, m, type))
          .toList();

  @override
  Future<List<Shelf>> home(ProviderDef p) {
    final cats = _catalogs(p)
        .where((c) =>
            !((c['extra'] as List?) ?? [])
                .any((e) => e is Map && e['isRequired'] == true) &&
            ((c['extraRequired'] as List?) ?? []).isEmpty)
        .take(8);
    return shelvesFrom([
      for (final c in cats)
        MapEntry<String, Future<List<Item>>>(
          '${c['name'] ?? c['id']} · ${c['type']}',
          cachedJson(
                  '${_base(p)}/catalog/${c['type']}/${Uri.encodeComponent(c['id'].toString())}.json')
              .then((j) => _metas(p, j, c['type'].toString())),
        ),
    ]);
  }

  @override
  Future<List<Item>> search(ProviderDef p, String q) async {
    final cats = _catalogs(p)
        .where((c) =>
            ((c['extra'] as List?) ?? [])
                .any((e) => e is Map && e['name'] == 'search') ||
            ((c['extraSupported'] as List?) ?? []).contains('search'))
        .take(4);
    final lists = await Future.wait(cats.map((c) async {
      try {
        final j = await getJson(
            '${_base(p)}/catalog/${c['type']}/${Uri.encodeComponent(c['id'].toString())}/search=${Uri.encodeComponent(q)}.json');
        return _metas(p, j, c['type'].toString());
      } catch (_) {
        return <Item>[];
      }
    }));
    final seen = <String>{};
    return [
      for (final l in lists)
        for (final it in l)
          if (seen.add(it.id)) it,
    ];
  }

  @override
  Future<Item> detail(ProviderDef p, Item item) async {
    final j = await cachedJson(
        '${_base(p)}/meta/${item.type}/${Uri.encodeComponent(item.id)}.json');
    final m = (j['meta'] as Map?) ?? {};
    var eps = <Episode>[];
    final videos = m['videos'];
    if (videos is List && videos.length > 1 && item.type != 'movie') {
      eps = [
        for (final v in videos.whereType<Map>())
          Episode(
            id: v['id'].toString(),
            season: (v['season'] as num?)?.toInt() ?? 1,
            episode: ((v['episode'] ?? v['number']) as num?)?.toInt() ?? 0,
            title: (v['title'] ?? v['name'] ?? 'Episode ${v['episode'] ?? ''}')
                .toString(),
          ),
      ]..sort((a, b) =>
          a.season != b.season ? a.season.compareTo(b.season) : a.episode.compareTo(b.episode));
    }
    return item.copyWith(
      title: m['name']?.toString(),
      plot: m['description']?.toString(),
      poster: m['poster']?.toString(),
      bg: m['background']?.toString(),
      year: (m['releaseInfo'] ?? m['year'])?.toString(),
      rating: m['imdbRating']?.toString(),
      genres: ((m['genres'] as List?) ?? []).map((e) => e.toString()).take(3).toList(),
      episodes: eps,
    );
  }

  @override
  Future<List<Source>> sources(ProviderDef p, Item item, Episode? ep) async {
    final hasStream = ((p.manifest?['resources'] as List?) ?? [])
        .any((r) => (r is Map ? r['name'] : r) == 'stream');
    if (!hasStream) throw ProviderError('This addon does not provide streams.');
    final vid = ep?.id ?? item.id;
    final j = await getJson(
        '${_base(p)}/stream/${item.type}/${Uri.encodeComponent(vid)}.json');
    return [
      for (final s in ((j['streams'] as List?) ?? []).whereType<Map>())
        _stream(s),
    ];
  }

  Source _stream(Map s) {
    final name = [
      s['name'],
      (s['title'] ?? s['description'] ?? '').toString().split('\n').first,
    ].where((e) => e != null && e.toString().isNotEmpty).join(' · ');
    final n = name.isEmpty ? 'Stream' : name.replaceAll(RegExp(r'\s+'), ' ');
    if (s['url'] != null) return Source.clean(name: n, url: s['url'].toString());
    if (s['externalUrl'] != null) {
      return Source.clean(
          name: n, link: s['externalUrl'].toString(), note: 'Opens in your browser');
    }
    if (s['ytId'] != null) {
      return Source.clean(
          name: n,
          link: 'https://www.youtube.com/watch?v=${s['ytId']}',
          note: 'Opens on YouTube');
    }
    if (s['infoHash'] != null) {
      return Source(name: n, note: 'Torrent stream. Not supported.');
    }
    return Source(name: n, note: 'Unsupported stream type');
  }
}

/* ---------- JSON catalog ---------- */

class JsonAdapter extends Adapter {
  Future<List<Map>> _items(ProviderDef p) async {
    dynamic d = p.data ?? await cachedJson(p.url!);
    if (d is List) d = <String, dynamic>{'items': d};
    return ((d['items'] as List?) ?? []).whereType<Map>().toList();
  }

  String _rid(Map it, int i) => (it['id'] ?? it['title'] ?? it['name'] ?? i).toString();

  Item _toItem(ProviderDef p, Map it, int i) => Item(
        pid: p.id,
        id: _rid(it, i),
        type: (it['type'] ?? (it['episodes'] != null ? 'series' : 'movie')).toString(),
        title: (it['title'] ?? it['name'] ?? 'Untitled').toString(),
        poster: it['poster']?.toString(),
        year: it['year']?.toString(),
        plot: (it['plot'] ?? it['description'])?.toString(),
      );

  List<Source> _srcs(dynamic l) => [
        for (final s in ((l as List?) ?? []).whereType<Map>())
          Source.clean(
            name: [s['name'] ?? 'Source', s['quality']]
                .where((e) => e != null && e.toString().isNotEmpty)
                .join(' · '),
            url: s['url']?.toString(),
          ),
      ];

  @override
  Future<List<Shelf>> home(ProviderDef p) async {
    final items = await _items(p);
    final groups = <String, List<Item>>{};
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final it2 = _toItem(p, it, i);
      final cat = it['category']?.toString() ??
          (it2.type == 'movie' ? 'Movies' : 'Series');
      groups.putIfAbsent(cat, () => []).add(it2);
    }
    return [for (final e in groups.entries) Shelf(e.key, e.value)];
  }

  @override
  Future<List<Item>> search(ProviderDef p, String q) async {
    final items = await _items(p);
    final n = q.toLowerCase();
    return [
      for (var i = 0; i < items.length; i++)
        if (_toItem(p, items[i], i).title.toLowerCase().contains(n))
          _toItem(p, items[i], i),
    ];
  }

  @override
  Future<Item> detail(ProviderDef p, Item item) async {
    final items = await _items(p);
    Map? raw;
    for (var i = 0; i < items.length; i++) {
      if (_rid(items[i], i) == item.id) raw = items[i];
    }
    if (raw == null) throw ProviderError('Title not found in this catalog.');
    final eps = raw['episodes'];
    return item.copyWith(
      bg: raw['background']?.toString(),
      genres: ((raw['genres'] as List?) ?? []).map((e) => e.toString()).take(3).toList(),
      episodes: eps is List && eps.isNotEmpty
          ? [
              for (var k = 0; k < eps.length; k++)
                Episode(
                  id: 's${(eps[k]['season'] ?? 1)}e${(eps[k]['episode'] ?? k + 1)}',
                  season: (eps[k]['season'] as num?)?.toInt() ?? 1,
                  episode: (eps[k]['episode'] as num?)?.toInt() ?? k + 1,
                  title: (eps[k]['title'] ?? 'Episode ${k + 1}').toString(),
                  sources: _srcs(eps[k]['sources']),
                ),
            ]
          : const [],
      sources: _srcs(raw['sources']),
    );
  }

  @override
  Future<List<Source>> sources(ProviderDef p, Item item, Episode? ep) async =>
      ep != null ? ep.sources : item.sources;
}

/* ---------- adding providers ---------- */

class RepoEntry {
  RepoEntry(this.name, this.url, this.description);
  final String name;
  final String url;
  final String description;
}

class DetectResult {
  DetectResult.provider(this.def, this.info)
      : repoName = null,
        repo = const [];
  DetectResult.repository(this.repoName, this.repo)
      : def = null,
        info = null;

  final ProviderDef? def;
  final String? info;
  final String? repoName;
  final List<RepoEntry> repo;
}

String _newId() => 'p_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
String _hostOf(String u) => Uri.tryParse(u)?.host ?? u;

/// Works out what a pasted link or JSON is: a Stremio manifest, a catalog or a repository.
Future<DetectResult> detect(String text) async {
  final t = text.trim();
  dynamic data;
  String? url;
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      data = jsonDecode(t);
    } catch (_) {
      throw ProviderError('That JSON is not valid.');
    }
  } else {
    final u = t.replaceFirst(RegExp(r'^stremio://', caseSensitive: false), 'https://');
    if (!isHttp(u)) throw ProviderError('Enter a full link that starts with https://');
    url = u;
    data = await getJson(u);
  }
  if (data is List) data = <String, dynamic>{'items': data};
  if (data is! Map) throw ProviderError('This format is not recognized.');
  final m = Map<String, dynamic>.from(data);

  if (m['resources'] is List && (m.containsKey('catalogs') || m.containsKey('id'))) {
    if (url == null) {
      throw ProviderError('Paste the addon link (https://…/manifest.json), not its contents.');
    }
    final cats = (m['catalogs'] as List?) ?? [];
    return DetectResult.provider(
      ProviderDef(
        id: _newId(),
        kind: 'stremio',
        name: (m['name'] ?? _hostOf(url)).toString(),
        url: url,
        manifest: {
          'catalogs': cats,
          'resources': m['resources'],
          'types': m['types'] ?? [],
        },
      ),
      '${cats.length} catalogs',
    );
  }
  if (m['providers'] is List) {
    final entries = <RepoEntry>[];
    for (final x in (m['providers'] as List).whereType<Map>()) {
      final u = x['url']?.toString();
      if (u == null || !isHttp(u)) continue;
      entries.add(RepoEntry((x['name'] ?? _hostOf(u)).toString(), u,
          (x['description'] ?? _hostOf(u)).toString()));
    }
    return DetectResult.repository((m['name'] ?? 'Repository').toString(), entries);
  }
  if (m['items'] is List) {
    return DetectResult.provider(
      ProviderDef(
        id: _newId(),
        kind: 'json',
        name: (m['name'] ?? (url != null ? _hostOf(url) : 'My catalog')).toString(),
        url: url,
        data: url == null ? m : null,
      ),
      '${(m['items'] as List).length} titles',
    );
  }
  throw ProviderError(
      'Not recognized. Expected a Stremio manifest, a catalog with "items", or a repository with "providers".');
}

const String sampleCatalog = '''{
  "name": "Blender open movies",
  "items": [
    {
      "id": "bbb", "type": "movie", "title": "Big Buck Bunny", "year": 2008,
      "poster": "https://images.unsplash.com/photo-1489599849927-2ee91d4b7f4e",
      "plot": "A giant rabbit takes revenge on three bullying rodents.",
      "sources": [{ "name": "720p", "url": "https://example.com/video.mp4" }]
    },
    {
      "id": "sintel", "type": "movie", "title": "Sintel", "year": 2010,
      "poster": "https://images.unsplash.com/photo-1440404653325-ab127d49abc1",
      "plot": "A young woman searches for a baby dragon she once befriended.",
      "sources": [{ "name": "MP4", "url": "https://example.com/video.mp4" }]
    }
  ]
}''';
