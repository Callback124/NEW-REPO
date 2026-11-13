import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'download_page.dart';
import 'player_page.dart';
import 'providers.dart';
import 'store.dart';
import 'widgets.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.item});
  final Item item;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late Future<Item> _f = detailOf(_sourceItem);
  int? _season;
  int _rangeStart = 0;
  late Item _sourceItem = widget.item;

  void _selectDub(DubOption dub) {
    setState(() {
      _sourceItem = _sourceItem.copyWith(id: dub.subjectId, detailPath: dub.detailPath);
      _season = null;
      _rangeStart = 0;
      _f = detailOf(_sourceItem);
    });
  }

  /// The episode to continue from: the most recently watched one, or the next if it was finished.
  Episode? _lastEp(Item d) {
    if (d.episodes.isEmpty) return null;
    final pre = '${d.key}|';
    MapEntry<String, Progress>? best;
    for (final e in app.progress.entries) {
      if (e.key.startsWith(pre) && (best == null || e.value.ts > best.value.ts)) best = e;
    }
    if (best == null) return null;
    final id = best.key.substring(pre.length);
    final idx = d.episodes.indexWhere((x) => x.id == id);
    if (idx < 0) return null;
    if (best.value.frac > .95) {
      return idx + 1 < d.episodes.length ? d.episodes[idx + 1] : d.episodes[idx];
    }
    return d.episodes[idx];
  }

  String _playLabel(Item d) {
    final ep = d.episodes.isEmpty ? null : (_lastEp(d) ?? d.episodes.first);
    final pr = app.progress[progressKey(d, ep)];
    final resume = pr != null && pr.t > 5 && pr.frac < .95;
    return '${resume ? 'Resume' : 'Play'}${ep != null ? ' ${ep.label}' : ''}';
  }

  Future<void> _play(Item d, Episode? ep) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerPage(item: d, ep: ep, list: d.episodes)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      body: FutureBuilder<Item>(
        future: _f,
        builder: (context, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          final d = snap.data ?? widget.item;
          final err = snap.error;
          final eps = d.episodes;
          final seasons = (eps.map((e) => e.season).toSet().toList()..sort());
          if (eps.isNotEmpty) _season ??= (_lastEp(d) ?? eps.first).season;
          final list = eps.where((e) => e.season == _season).toList();
          final rangeCount = (list.length + 99) ~/ 100;
          if (_rangeStart >= rangeCount * 100) _rangeStart = 0;
          final visibleEpisodes = list.skip(_rangeStart).take(100).toList();
          final tags = [
            d.type == 'movie' ? 'Movie' : (d.type == 'series' ? 'Series' : d.type),
            d.year,
            if (d.rating != null) '★ ${d.rating}',
            app.providerById(d.pid)?.name,
            ...d.genres,
          ].where((t) => t != null && t.isNotEmpty).cast<String>().toList();

          return ListenableBuilder(
            listenable: app,
            builder: (context, _) => CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 220,
                  flexibleSpace: FlexibleSpaceBar(
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (isHttp(d.bg ?? d.poster))
                          CachedNetworkImage(
                            imageUrl: (d.bg ?? d.poster)!,
                            fit: BoxFit.cover,
                            memCacheWidth: 800,
                            errorWidget: (_, __, ___) => const SizedBox.shrink(),
                          ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.black38, cs.surface],
                              stops: const [.3, 1],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        SizedBox(width: 110, child: Poster(url: d.poster, title: d.title)),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.title,
                                  style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                              const SizedBox(height: 8),
                              Wrap(spacing: 6, runSpacing: 6, children: [
                                for (final t in tags)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                    decoration: BoxDecoration(
                                        color: cs.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(999)),
                                    child: Text(t,
                                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                                  ),
                              ]),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (d.dubs.length > 1)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: SizedBox(
                        height: 42,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final dub in d.dubs)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  showCheckmark: false,
                                  label: Text(dub.language + (dub.original ? ' · Original' : '')),
                                  selected: dub.subjectId == d.id && dub.detailPath == d.detailPath,
                                  onSelected: (_) => _selectDub(dub),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (loading) const SliverToBoxAdapter(child: LinearProgressIndicator()),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Wrap(spacing: 10, runSpacing: 10, children: [
                      FilledButton(
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: loading || err != null
                            ? null
                            : () => _play(
                                d, eps.isEmpty ? null : (_lastEp(d) ?? eps.first)),
                        child: Text(loading ? 'Loading…' : 'Watch'),
                      ),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () => app.toggleLibrary(d),
                        child: const Text('Library'),
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: loading || err != null
                            ? null
                            : () => Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => DownloadPage(item: d),
                                )),
                        icon: const Icon(Icons.download_outlined, size: 18),
                        label: const Text('Download'),
                      ),
                    ]),
                  ),
                ),
                if (err != null)
                  SliverToBoxAdapter(
                    child: EmptyState(
                      title: 'Could not load this title',
                      text: err.toString(),
                      action: OutlinedButton(
                        onPressed: () => setState(() => _f = detailOf(_sourceItem)),
                        child: const Text('Try again'),
                      ),
                    ),
                  ),
                if ((d.plot ?? '').isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(d.plot!, style: const TextStyle(height: 1.5)),
                    ),
                  ),
                if (seasons.length > 1)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        children: [
                          for (final s in seasons)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                showCheckmark: false,
                                label: Text(s == 0 ? 'Specials' : 'Season $s'),
                                selected: s == _season,
                                onSelected: (_) => setState(() {
                                  _season = s;
                                  _rangeStart = 0;
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (rangeCount > 1)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        children: [
                          for (var r = 0; r < rangeCount; r++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                showCheckmark: false,
                                label: Text(
                                  '${(r * 100 + 1).toString().padLeft(3, '0')}-${((r + 1) * 100 < list.length ? (r + 1) * 100 : list.length).toString().padLeft(3, '0')}',
                                ),
                                selected: _rangeStart == r * 100,
                                onSelected: (_) => setState(() => _rangeStart = r * 100),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  sliver: SliverGrid.builder(
                    itemCount: visibleEpisodes.length,
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 76,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemBuilder: (context, i) {
                      final e = visibleEpisodes[i];
                      final seasonLabel = 'S${e.season.toString().padLeft(2, '0')}';
                      final episodeNumber = e.episode == 0 ? i + 1 : e.episode;
                      final episodeLabel = 'E${episodeNumber.toString().padLeft(2, '0')}';
                      return Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _play(d, e),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(seasonLabel,
                                style: TextStyle(
                                  color: cs.primary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                )),
                              const SizedBox(height: 3),
                              Text(episodeLabel,
                                style: TextStyle(
                                  color: cs.onSurface,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                )),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            ),
          );
        },
      ),
    );
  }
}
