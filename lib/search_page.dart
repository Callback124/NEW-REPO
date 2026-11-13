import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';
import 'providers.dart';
import 'store.dart';
import 'widgets.dart';

class _Group {
  _Group(this.provider, this.items, this.error);
  final ProviderDef provider;
  final List<Item> items;
  final Object? error;
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with AutomaticKeepAliveClientMixin {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  int _token = 0;
  bool _loading = false;
  String _query = '';
  List<_Group> _groups = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(v));
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    final my = ++_token;
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _groups = const [];
        _loading = false;
      });
      return;
    }
    setState(() {
      _query = q;
      _loading = true;
    });
    final ps = app.scope();
    final groups = await Future.wait(ps.map((p) async {
      try {
        return _Group(p, await adapterFor(p).search(p, q), null);
      } catch (e) {
        return _Group(p, const [], e);
      }
    }));
    if (!mounted || my != _token) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final multi = _groups.length > 1;
    final nothing = !_loading &&
        _query.isNotEmpty &&
        _groups.every((g) => g.error == null && g.items.isEmpty);
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          titleSpacing: 16,
          title: TextField(
            controller: _ctrl,
            onChanged: _onChanged,
            onSubmitted: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search movies and shows',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              contentPadding: EdgeInsets.zero,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
        ),
        if (_loading)
          const SliverToBoxAdapter(child: Padding(
              padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()))
        else if (_query.isEmpty)
          const SliverToBoxAdapter(
              child: EmptyState(
                  title: 'Search your providers',
                  text: 'Results are grouped by provider.'))
        else if (nothing)
          SliverToBoxAdapter(
              child: EmptyState(
                  title: 'No results for "$_query"',
                  text: 'Try a different spelling or another provider.'))
        else
          for (final g in _groups) ...[
            if (multi) SliverToBoxAdapter(child: ProviderHeader(g.provider.name)),
            if (g.error != null)
              SliverToBoxAdapter(child: ErrorNote(name: g.provider.name, error: g.error!))
            else if (g.items.isEmpty && multi)
              const SliverToBoxAdapter(
                  child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text('No matches.')))
            else
              PosterGrid(items: g.items),
          ],
      ],
    );
  }
}
