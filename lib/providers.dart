import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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
      'stremio' => StremioAdapter(),
      'json' => JsonAdapter(),
      _ => ArchiveAdapter(),
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

/* ---------- Internet Archive (built in) ---------- */

class ArchiveAdapter extends Adapter {
  static const List<List<String>> _shelves = [
    ['Feature films', 'feature_films'],
    ['Animation & cartoons', 'animationandcartoons'],
    ['Classic TV', 'classic_tv'],
    ['Silent films', 'silent_films'],
  ];

  Future<List<Item>> _query(ProviderDef p, String? coll, String? q) async {
    var qs = 'mediatype:(movies)';
    if (coll != null) qs += ' AND collection:($coll)';
    if (q != null) {
      final c = q
          .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (c.isNotEmpty) qs += ' AND ($c)';
    }
    final u = Uri.https('archive.org', '/advancedsearch.php', {
      'q': qs,
      'fl[]': ['identifier', 'title', 'year', 'description'],
      'rows': '24',
      'sort[]': 'downloads desc',
      'output': 'json',
    });
    final j = await cachedJson(u.toString());
    final docs = ((j['response']?['docs']) as List?) ?? [];
    return docs.whereType<Map>().map((d) {
      final id = d['identifier'].toString();
      final title = strip(d['title']);
      final plot = strip(d['description']);
      return Item(
        pid: p.id,
        id: id,
        title: title.isEmpty ? id : title,
        year: d['year']?.toString(),
        plot: plot.length > 500 ? plot.substring(0, 500) : plot,
        poster: 'https://archive.org/services/img/$id',
      );
    }).toList();
  }

  @override
  Future<List<Shelf>> home(ProviderDef p) => shelvesFrom([
        for (final s in _shelves)
          MapEntry<String, Future<List<Item>>>(s[0], _query(p, s[1], null)),
      ]);

  @override
  Future<List<Item>> search(ProviderDef p, String q) => _query(p, null, q);

  @override
  Future<Item> detail(ProviderDef p, Item item) async {
    final m = await cachedJson(
        'https://archive.org/metadata/${Uri.encodeComponent(item.id)}');
    final files = (m['files'] as List?) ?? [];
    final ext = RegExp(r'\.(mp4|m4v|webm|ogv|mkv)$', caseSensitive: false);
    final groups = <String, List<Map>>{};
    for (final f in files.whereType<Map>()) {
      final name = (f['name'] ?? '').toString();
      if (!ext.hasMatch(name)) continue;
      final key = f['source'] == 'derivative'
          ? (f['original'] ?? name).toString()
          : name;
      groups.putIfAbsent(key, () => []).add(f);
    }

    String dl(String n) =>
        'https://archive.org/download/${Uri.encodeComponent(item.id)}/${n.split('/').map(Uri.encodeComponent).join('/')}';

    List<Source> mk(List<Map> arr) {
      int size(Map f) => int.tryParse('${f['size']}') ?? 0;
      final sorted = [...arr]..sort((a, b) => size(b).compareTo(size(a)));
      return [
        for (final f in sorted)
          Source.clean(
            name: [
              (f['format'] ?? f['name'].toString().split('.').last.toUpperCase())
                  .toString(),
              if (size(f) > 0) '${(size(f) / 1048576).round()} MB',
            ].join(' · '),
            url: dl(f['name'].toString()),
          ),
      ];
    }

    final md = (m['metadata'] as Map?) ?? {};
    final plot = strip(md['description']);
    final date = md['date']?.toString();
    final year = md['year']?.toString() ??
        (date != null && date.length >= 4 ? date.substring(0, 4) : null);
    final subject = md['subject'];
    final genres = (subject is List ? subject : (subject == null ? [] : [subject]))
        .map((e) => e.toString())
        .take(3)
        .toList();

    final keys = groups.keys.toList()..sort((a, b) => _natKey(a).compareTo(_natKey(b)));
    final base = item.copyWith(
      plot: plot.isEmpty ? null : plot,
      year: year,
      genres: genres,
    );
    if (keys.length > 1) {
      return base.copyWith(episodes: [
        for (var i = 0; i < keys.length && i < 300; i++)
          Episode(
            id: keys[i],
            season: 1,
            episode: i + 1,
            title: keys[i].replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' '),
            sources: mk(groups[keys[i]]!),
          ),
      ]);
    }
    return base.copyWith(
        sources: keys.isEmpty ? const [] : mk(groups[keys.first]!));
  }

  @override
  Future<List<Source>> sources(ProviderDef p, Item item, Episode? ep) async =>
      ep != null ? ep.sources : item.sources;
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
    if (d is List) d = {'items': d};
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
  if (data is List) data = {'items': data};
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
      "poster": "https://archive.org/services/img/BigBuckBunny_124",
      "plot": "A giant rabbit takes revenge on three bullying rodents.",
      "sources": [{ "name": "720p", "url": "https://archive.org/download/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4" }]
    },
    {
      "id": "sintel", "type": "movie", "title": "Sintel", "year": 2010,
      "poster": "https://archive.org/services/img/Sintel",
      "plot": "A young woman searches for a baby dragon she once befriended.",
      "sources": [{ "name": "MP4", "url": "https://archive.org/download/Sintel/sintel-2048-surround.mp4" }]
    }
  ]
}''';
