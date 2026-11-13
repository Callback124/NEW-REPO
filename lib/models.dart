class ProviderError implements Exception {
  ProviderError(this.message);
  final String message;
  @override
  String toString() => message;
}

bool isHttp(String? u) =>
    u != null && (u.startsWith('http://') || u.startsWith('https://'));

class Source {
  const Source({required this.name, this.url, this.link, this.note});

  final String name;
  final String? url;
  final String? link;
  final String? note;

  /// Builds a source and drops anything that is not an http(s) link.
  factory Source.clean({
    required String name,
    String? url,
    String? link,
    String? note,
  }) =>
      Source(
        name: name.isEmpty ? 'Source' : name,
        url: isHttp(url) ? url : null,
        link: isHttp(link) ? link : null,
        note: note ?? ((url != null && !isHttp(url)) ? 'Invalid link' : null),
      );

  bool get playable => url != null;
}

class Episode {
  const Episode({
    required this.id,
    this.season = 1,
    this.episode = 0,
    required this.title,
    this.sources = const [],
  });

  final String id;
  final int season;
  final int episode;
  final String title;
  final List<Source> sources;

  String get label => 'S$season E${episode == 0 ? '?' : episode}';

  Map<String, dynamic> toJson() =>
      {'id': id, 'season': season, 'episode': episode, 'title': title};

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
        id: j['id'].toString(),
        season: (j['season'] as num?)?.toInt() ?? 1,
        episode: (j['episode'] as num?)?.toInt() ?? 0,
        title: (j['title'] ?? '').toString(),
      );
}

class Item {
  const Item({
    required this.pid,
    required this.id,
    this.type = 'movie',
    required this.title,
    this.poster,
    this.year,
    this.plot,
    this.bg,
    this.rating,
    this.genres = const [],
    this.episodes = const [],
    this.sources = const [],
  });

  final String pid;
  final String id;
  final String type;
  final String title;
  final String? poster;
  final String? year;
  final String? plot;
  final String? bg;
  final String? rating;
  final List<String> genres;
  final List<Episode> episodes;
  final List<Source> sources;

  String get key => '$pid|$id';

  Item copyWith({
    String? title,
    String? poster,
    String? year,
    String? plot,
    String? bg,
    String? rating,
    List<String>? genres,
    List<Episode>? episodes,
    List<Source>? sources,
  }) =>
      Item(
        pid: pid,
        id: id,
        type: type,
        title: title ?? this.title,
        poster: poster ?? this.poster,
        year: year ?? this.year,
        plot: plot ?? this.plot,
        bg: bg ?? this.bg,
        rating: rating ?? this.rating,
        genres: genres ?? this.genres,
        episodes: episodes ?? this.episodes,
        sources: sources ?? this.sources,
      );

  Map<String, dynamic> toJson() => {
        'pid': pid,
        'id': id,
        'type': type,
        'title': title,
        'poster': poster,
        'year': year,
        'plot': (plot ?? '').length > 400 ? plot!.substring(0, 400) : plot,
      };

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        pid: j['pid'].toString(),
        id: j['id'].toString(),
        type: (j['type'] ?? 'movie').toString(),
        title: (j['title'] ?? '').toString(),
        poster: j['poster']?.toString(),
        year: j['year']?.toString(),
        plot: j['plot']?.toString(),
      );
}

String progressKey(Item it, Episode? ep) => '${it.pid}|${it.id}|${ep?.id ?? ''}';

class Progress {
  const Progress({
    required this.t,
    required this.d,
    required this.ts,
    required this.item,
    this.ep,
  });

  final double t;
  final double d;
  final int ts;
  final Item item;
  final Episode? ep;

  double get frac => d > 0 ? t / d : 0;

  Map<String, dynamic> toJson() =>
      {'t': t, 'd': d, 'ts': ts, 'item': item.toJson(), 'ep': ep?.toJson()};

  factory Progress.fromJson(Map<String, dynamic> j) => Progress(
        t: (j['t'] as num).toDouble(),
        d: (j['d'] as num).toDouble(),
        ts: (j['ts'] as num).toInt(),
        item: Item.fromJson(Map<String, dynamic>.from(j['item'] as Map)),
        ep: j['ep'] == null
            ? null
            : Episode.fromJson(Map<String, dynamic>.from(j['ep'] as Map)),
      );
}

class Shelf {
  const Shelf(this.title, this.items);
  final String title;
  final List<Item> items;
}

class ProviderDef {
  const ProviderDef({
    required this.id,
    required this.kind,
    required this.name,
    this.enabled = true,
    this.builtin = false,
    this.url,
    this.data,
    this.manifest,
  });

  final String id;
  final String kind; // archive | stremio | json
  final String name;
  final bool enabled;
  final bool builtin;
  final String? url;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? manifest;

  factory ProviderDef.archive() => const ProviderDef(
      id: 'archive', kind: 'archive', name: 'Internet Archive', builtin: true);

  ProviderDef copyWith({bool? enabled}) => ProviderDef(
        id: id,
        kind: kind,
        name: name,
        enabled: enabled ?? this.enabled,
        builtin: builtin,
        url: url,
        data: data,
        manifest: manifest,
      );

  String get kindLabel => switch (kind) {
        'archive' => 'Built-in',
        'stremio' => 'Stremio addon',
        'json' => 'JSON catalog',
        _ => kind,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'name': name,
        'enabled': enabled,
        'builtin': builtin,
        'url': url,
        'data': data,
        'manifest': manifest,
      };

  factory ProviderDef.fromJson(Map<String, dynamic> j) => ProviderDef(
        id: j['id'].toString(),
        kind: j['kind'].toString(),
        name: (j['name'] ?? 'Provider').toString(),
        enabled: j['enabled'] as bool? ?? true,
        builtin: j['builtin'] as bool? ?? false,
        url: j['url']?.toString(),
        data: j['data'] == null ? null : Map<String, dynamic>.from(j['data'] as Map),
        manifest:
            j['manifest'] == null ? null : Map<String, dynamic>.from(j['manifest'] as Map),
      );
}
