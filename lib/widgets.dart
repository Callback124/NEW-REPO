import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'detail_page.dart';
import 'models.dart';
import 'view_more_page.dart';

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
}

void openDetail(BuildContext context, Item item) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(item: item)));
}

/// Poster with an initial-letter placeholder underneath, so nothing jumps while images load.
class Poster extends StatelessWidget {
  const Poster({super.key, required this.url, required this.title, this.progress, this.corner});

  final String? url;
  final String title;
  final double? progress;
  final String? corner;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: cs.surfaceContainerHighest,
              child: const SizedBox.expand(),
            ),
            if (isHttp(url))
              CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                memCacheWidth: 360,
                fadeInDuration: const Duration(milliseconds: 120),
                placeholder: (_, __) => Center(
                  child: SvgPicture.network(
                    'https://h5-static.aoneroom.com/ssrStatic/mbOfficial/public/_nuxt/image-1.apJjVir2.svg',
                    width: 42,
                    height: 42,
                    placeholderBuilder: (_) => const SizedBox(width: 42, height: 42),
                  ),
                ),
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            if (corner != null && corner!.trim().isNotEmpty)
              Positioned(
                top: 7,
                left: 7,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFEEEEEE).withValues(alpha: 0.70),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    child: Text(
                      corner!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF1976D2),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
            if (progress != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                    value: progress, minHeight: 4, backgroundColor: Colors.black54),
              ),
          ],
        ),
      ),
    );
  }
}

/// Poster + title. Needs a bounded height from its parent (list or grid cell).
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.subtitle,
    this.progress,
  });

  final Item item;
  final VoidCallback onTap;
  final String? subtitle;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Poster(url: item.poster, title: item.title, progress: progress, corner: item.corner),
          const SizedBox(height: 6),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: item.title,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, height: 1.25)),
                if (subtitle != null)
                  TextSpan(text: '\n$subtitle', style: TextStyle(fontSize: 12, color: muted)),
              ]),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

double cardWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 700 ? 150 : 118;

/// One horizontal row of posters. Fixed extents keep scrolling cheap.
class ShelfRow extends StatelessWidget {
  const ShelfRow({super.key, required this.shelf});
  final Shelf shelf;

  @override
  Widget build(BuildContext context) {
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
                Expanded(child: Text(shelf.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                if (shelf.genreTopId != null && shelf.items.isNotEmpty)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MovieBoxViewMorePage(shelf: shelf))),
                    child: const Text('View all'),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: w * 1.5 + 54,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: shelf.items.length,
              itemExtent: w + 12,
              cacheExtent: w * 4,
              itemBuilder: (context, i) {
                final it = shelf.items[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: PosterCard(item: it, onTap: () => openDetail(context, it)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Sliver grid of posters for search results and the library.
class PosterGrid extends StatelessWidget {
  const PosterGrid({super.key, required this.items});
  final List<Item> items;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 150,
          childAspectRatio: 0.48,
          mainAxisSpacing: 14,
          crossAxisSpacing: 12,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) =>
            PosterCard(item: items[i], onTap: () => openDetail(context, items[i])),
      ),
    );
  }
}

class ShelfSkeleton extends StatelessWidget {
  const ShelfSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainerHighest;
    final w = cardWidth(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
                width: 140,
                height: 16,
                decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(6))),
          ),
          SizedBox(
            height: w * 1.5,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: 6,
              itemExtent: w + 12,
              itemBuilder: (_, __) => Padding(
                padding: const EdgeInsets.only(right: 12),
                child: DecoratedBox(
                    decoration:
                        BoxDecoration(color: c, borderRadius: BorderRadius.circular(10))),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.text, this.action});
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                textAlign: TextAlign.center,
                style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class ErrorNote extends StatelessWidget {
  const ErrorNote({super.key, required this.name, required this.error, this.onRetry});
  final String name;
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: Text('$name could not load: $error',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class ProviderHeader extends StatelessWidget {
  const ProviderHeader(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(name.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
