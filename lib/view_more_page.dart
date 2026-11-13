import 'package:flutter/material.dart';

import 'models.dart';
import 'providers.dart';
import 'store.dart';
import 'widgets.dart';

class MovieBoxViewMorePage extends StatefulWidget {
  const MovieBoxViewMorePage({super.key, required this.shelf});
  final Shelf shelf;

  @override
  State<MovieBoxViewMorePage> createState() => _MovieBoxViewMorePageState();
}

class _MovieBoxViewMorePageState extends State<MovieBoxViewMorePage> {
  final List<Item> _items = [];
  bool _loading = true;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final item = widget.shelf.items.isEmpty ? null : widget.shelf.items.first;
    final provider = item == null ? null : app.providerById(item.pid);
    final id = widget.shelf.genreTopId;
    if (provider == null || id == null || id.isEmpty) {
      setState(() { _loading = false; _hasMore = false; _error = 'This row has no View More identifier.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await MovieBoxAdapter().viewMore(provider, id, page: _page);
      if (!mounted) return;
      setState(() {
        _items.addAll(rows);
        _hasMore = rows.length >= 20;
        _page++;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.shelf.title)),
      body: _items.isEmpty && _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(top: 8),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                if (_items.isNotEmpty)
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 150,
                      childAspectRatio: 0.48,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 12,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, index) => PosterCard(
                      item: _items[index],
                      onTap: () => openDetail(context, _items[index]),
                    ),
                  ),
                if (_loading) const Padding(
                  padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
                if (!_loading && _hasMore)
                  Center(child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: FilledButton(onPressed: _load, child: const Text('Load more')),
                  )),
                if (!_loading && !_hasMore && _items.isNotEmpty)
                  const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('You’re all caught up'))),
                if (_error != null && _items.isEmpty)
                  Center(child: TextButton(onPressed: _load, child: const Text('Try again'))),
              ],
            ),
    );
  }
}
