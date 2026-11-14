import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'models.dart';
import 'player_page.dart';
import 'providers.dart';
import 'store.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final ps = app.scope();
        return CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: true,
              title: Text(
                app.enabled.any((p) => p.id == app.active)
                    ? app.enabled.firstWhere((p) => p.id == app.active).name
                    : app.scopeName,
                style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -.3),
              ),
              actions: [
                IconButton(
                  onPressed: () => _pickScope(context),
                  icon: const Icon(Icons.dns_outlined),
                  tooltip: 'Change provider',
                ),
                const SizedBox(width: 8),
              ],
            ),
            const SliverToBoxAdapter(child: _ContinueWatching()),
            if (ps.isEmpty)
              SliverToBoxAdapter(
                child: EmptyState(
                  title: 'No providers are turned on',
                  text: 'Turn one on, or add a new provider in Settings.',
                ),
              )
            else
              SliverList.builder(
                itemCount: ps.length,
                itemBuilder: (context, i) => _ProviderSection(
                  key: ValueKey(ps[i].id),
                  provider: ps[i],
                  showName: ps.length > 1,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  void _pickScope(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in app.enabled)
              RadioListTile<String>(
                value: p.id,
                groupValue: app.active,
                title: Text(p.name),
                subtitle: Text(p.kindLabel),
                onChanged: (v) {
                  app.setActive(p.id);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _ProviderSection extends StatefulWidget {
  const _ProviderSection({super.key, required this.provider, required this.showName});
  final ProviderDef provider;
  final bool showName;

  @override
  State<_ProviderSection> createState() => _ProviderSectionState();
}

class _ProviderSectionState extends State<_ProviderSection> {
  late Future<List<Shelf>> _f;

  @override
  void initState() {
    super.initState();
    _f = adapterFor(widget.provider).home(widget.provider);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showName) ProviderHeader(p.name),
        FutureBuilder<List<Shelf>>(
          future: _f,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Column(children: [ShelfSkeleton(), ShelfSkeleton()]);
            }
            if (snap.hasError) {
              return ErrorNote(
                name: p.name,
                error: snap.error!,
                onRetry: () =>
                    setState(() => _f = adapterFor(p).home(p)),
              );
            }
            final shelves = snap.data ?? const [];
            if (shelves.isEmpty) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Text('${p.name} has no home catalogs. Try Search.'),
              );
            }
            return p.kind == 'storytv'\n                ? _StoryTvGrid(items: shelves.expand((s) => s.items).toList())\n                : Column(children: [for (final s in shelves) ShelfRow(shelf: s)]);
          },
        ),
      ],
    );
  }
}

class _ContinueWatching extends StatelessWidget {
  const _ContinueWatching();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: app.progressRev,
      builder: (context, _, __) {
        final rs = app.resumables;
        if (rs.isEmpty) return const SizedBox.shrink();
        final w = cardWidth(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(
                  children: [
                    Expanded(child: Text('Continue watching',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700))),
                    TextButton(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Clear continue watching?'),
                            content: const Text('All continue watching progress will be deleted.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete all')),
                            ],
                          ),
                        );
                        if (ok == true) app.clearProgress();
                      },
                      child: const Text('Clear all'),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: w * 1.5 + 54,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: rs.length,
                  itemExtent: w + 12,
                  itemBuilder: (context, i) {
                    final pr = rs[i].value;
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: GestureDetector(
                        onLongPress: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete from continue watching?'),
                              content: Text('Remove "${pr.item.title}" from Continue watching?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                              ],
                            ),
                          );
                          if (ok == true) app.removeProgress(pr.item, pr.ep);
                        },
                        child: PosterCard(
                          item: pr.item,
                          progress: pr.frac,
                          subtitle: pr.ep != null
                              ? pr.ep!.label
                              : '${((pr.d - pr.t) / 60).ceil().clamp(1, 9999)} min left',
                          onTap: () => resumeProgress(context, pr),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> resumeProgress(BuildContext context, Progress pr) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
      const SnackBar(content: Text('Loading…'), duration: Duration(seconds: 1)));
  try {
    final full = await detailOf(pr.item);
    Episode? ep;
    if (pr.ep != null) {
      for (final e in full.episodes) {
        if (e.id == pr.ep!.id) ep = e;
      }
    }
    nav.push(MaterialPageRoute(
        builder: (_) => PlayerPage(item: full, ep: ep, list: full.episodes)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.toString())));
  }
}

class _StoryTvGrid extends StatelessWidget {
  const _StoryTvGrid({required this.items});
  final List<Item> items;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    child: GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 205, childAspectRatio: .50,
        mainAxisSpacing: 14, crossAxisSpacing: 12,
      ),
      itemBuilder: (context, i) {
        final item = items[i];
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => openDetail(context, item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                      if (isHttp(item.poster))
                        CachedNetworkImage(
                          imageUrl: item.poster!,
                          fit: BoxFit.cover,
                          memCacheWidth: 360,
                          memCacheHeight: 640,
                          maxWidthDiskCache: 540,
                          maxHeightDiskCache: 960,
                          fadeInDuration: Duration.zero,
                          fadeOutDuration: Duration.zero,
                          placeholder: (_, __) => const Center(child: CircularProgressIndicator(strokeWidth: 1.5)),
                          errorWidget: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      Positioned(
                        left: 7, bottom: 7,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                            child: Text(item.corner ?? 'Mini Drama',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        );
      },
    ),
  );
}
