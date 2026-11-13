import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'models.dart';
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
  late Item _sourceItem = widget.item;

  void _selectDub(DubOption dub) {
    setState(() {
      _sourceItem = _sourceItem.copyWith(id: dub.subjectId, detailPath: dub.detailPath);
      _season = null;
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
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final dub in d.dubs)
                            ChoiceChip(
                              label: Text(dub.language + (dub.original ? ' · Original' : '')),
                              selected: dub.detailPath == d.detailPath,
                              onSelected: (_) => _selectDub(dub),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (loading) const SliverToBoxAdapter(child: LinearProgressIndicator()),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Wrap(spacing: 10, runSpacing: 10, children: [
                      FilledButton.icon(
                        onPressed: loading || err != null
                            ? null
                            : () => _play(
                                d, eps.isEmpty ? null : (_lastEp(d) ?? eps.first)),
                        icon: const Icon(Icons.play_arrow),
                        label: Text(loading ? 'Loading…' : _playLabel(d)),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => app.toggleLibrary(d),
                        icon: Icon(app.inLibrary(d) ? Icons.check : Icons.add),
                        label: Text(app.inLibrary(d) ? 'In library' : 'Library'),
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
                        onPressed: () => setState(() => _f = detailOf(widget.item)),
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
                                label: Text(s == 0 ? 'Specials' : 'Season $s'),
                                selected: s == _season,
                                onSelected: (_) => setState(() => _season = s),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                SliverList.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final e = list[i];
                    final pr = app.progress[progressKey(d, e)];
                    return ListTile(
                      leading: SizedBox(
                          width: 32,
                          child: Center(
                              child: Text('${e.episode == 0 ? i + 1 : e.episode}',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)))),
                      title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: pr != null && pr.frac > .01
                          ? Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: LinearProgressIndicator(value: pr.frac, minHeight: 3))
                          : null,
                      trailing: const Icon(Icons.play_arrow, size: 20),
                      onTap: () => _play(d, e),
                    );
                  },
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
