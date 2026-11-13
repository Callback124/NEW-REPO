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
  static String _savedQuery = '';
  static List<_Group> _savedGroups = const [];
  static List<String> _savedSuggestions = const [];
  static double _savedOffset = 0;
  static bool _savedHasMore = false;
  static int _savedPage = 1;

  final _ctrl = TextEditingController();
  late final ScrollController _scroll;
  Timer? _debounce;
  int _token = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String _query = '';
  List<_Group> _groups = const [];
  List<String> _suggestions = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _ctrl.text = _savedQuery;
    _query = _savedQuery;
    _groups = _savedGroups;
    _suggestions = _savedSuggestions;
    _hasMore = _savedHasMore;
    _page = _savedPage;
    _scroll = ScrollController(initialScrollOffset: _savedOffset);
    _scroll.addListener(_saveSession);
  }

  void _saveSession() {
    _savedQuery = _query;
    _savedGroups = _groups;
    _savedSuggestions = _suggestions;
    _savedHasMore = _hasMore;
    _savedPage = _page;
    if (_scroll.hasClients) _savedOffset = _scroll.offset;
  }

  @override
  void dispose() {
    _saveSession();
    _scroll.removeListener(_saveSession);
    _debounce?.cancel();
    _scroll.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    setState(() {
      _query = '';
      _groups = const [];
      _loading = false;
      _loadingMore = false;
      _hasMore = false;
      _suggestions = const [];
    });
    _saveSession();
    _loadSuggestions(v);
  }

  Future<void> _loadSuggestions(String raw) async {
    final q = raw.trim();
    if (q.length < 2) {
      if (mounted) setState(() => _suggestions = const []);
      return;
    }
    final providers = app.scope().where((p) => p.kind == 'moviebox').toList();
    if (providers.isEmpty) return;
    try {
      final values = await MovieBoxAdapter().suggestions(q);
      if (!mounted || _ctrl.text.trim() != q) return;
      setState(() => _suggestions = values.take(8).toList());
      _saveSession();
    } catch (_) {
      if (mounted) setState(() => _suggestions = const []);
    }
  }

  void _useSuggestion(String value) {
    _ctrl.text = value;
    _ctrl.selection = TextSelection.collapsed(offset: value.length);
    setState(() => _suggestions = const []);
    _saveSession();
    _search(value);
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    final my = ++_token;
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _groups = const [];
        _suggestions = const [];
        _loading = false;
      });
      return;
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _savedOffset = 0;
    setState(() {
      _query = q;
      _loading = true;
      _loadingMore = false;
      _page = 1;
      _hasMore = false;
    });
    final ps = app.scope();
    final groups = await Future.wait(ps.map((p) async {
      try {
        if (p.kind == 'moviebox') {
          final page = await MovieBoxAdapter().searchPage(p, q);
          if (mounted && my == _token) {
            _page = 1;
            _hasMore = page.hasMore;
          }
          return _Group(p, page.items, null);
        }
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
    _saveSession();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || _loadingMore || !_hasMore || _query.isEmpty) return;
    if (_scroll.position.extentAfter < 500) _loadMore();
  }

  Future<void> _loadMore() async {
    final matches = app.scope().where((x) => x.kind == 'moviebox').toList();
    if (matches.isEmpty) return;
    final p = matches.first;
    setState(() => _loadingMore = true);
    try {
      final next = await MovieBoxAdapter().searchPage(p, _query, page: _page + 1);
      if (!mounted) return;
      final idx = _groups.indexWhere((g) => g.provider.id == p.id);
      if (idx >= 0) {
        final updated = [..._groups];
        final old = updated[idx];
        final seen = old.items.map((x) => x.id).toSet();
        updated[idx] = _Group(p, [...old.items, ...next.items.where((x) => !seen.contains(x.id))], null);
        setState(() {
          _groups = updated;
          _page++;
          _hasMore = next.hasMore;
          _loadingMore = false;
        });
        _saveSession();
      } else {
        setState(() => _loadingMore = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMore = false);
      if (mounted) toast(context, 'Could not load more results: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final multi = _groups.length > 1;
    final nothing = !_loading &&
        _query.isNotEmpty &&
        _groups.every((g) => g.error == null && g.items.isEmpty);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) { if (n is ScrollUpdateNotification || n is ScrollMetricsNotification) _onScroll(); return false; },
      child: CustomScrollView(
      key: const PageStorageKey<String>('movie-search-results'),
      controller: _scroll,
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
              filled: true,
              contentPadding: EdgeInsets.zero,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
        ),
        if (_suggestions.isNotEmpty && _query.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final suggestion in _suggestions)
                    ActionChip(
                      avatar: const Icon(Icons.search, size: 16),
                      label: Text(suggestion),
                      onPressed: () => _useSuggestion(suggestion),
                    ),
                ],
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
                  text: 'Type to see suggestions, then press Enter or select a suggestion.'))
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
        if (_loadingMore)
          const SliverToBoxAdapter(child: Padding(
            padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))),
      ],
    ),
    );
  }
}
