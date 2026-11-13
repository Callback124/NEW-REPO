import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'downloads_service.dart';
import 'models.dart';
import 'providers.dart';
import 'store.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key, required this.item});
  final Item item;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadChoice {
  const _DownloadChoice(this.episode, this.source, this.quality, this.size);
  final Episode? episode;
  final Source source;
  final String quality;
  final int size;
}

class _DownloadPageState extends State<DownloadPage> {
  late Item _item = widget.item;
  int? _season;
  int _rangeStart = 0;
  String? _quality;
  bool _loading = true;
  String? _error;
  int _scanned = 0;
  int _scanTotal = 0;
  List<_DownloadChoice> _choices = [];
  final Set<String> _selected = {};
  final Map<String, int> _sizes = {};
  bool _queueing = false;

  bool get _series => _item.episodes.isNotEmpty || _item.type == 'series' || _item.subjectType == 2;
  List<int> get _seasons => (_item.episodes.map((e) => e.season).toSet().toList()..sort());
  List<Episode> get _seasonEpisodes => _item.episodes.where((e) => e.season == _season).toList()
    ..sort((a, b) => a.episode.compareTo(b.episode));
  List<Episode> get _pageEpisodes => _seasonEpisodes.skip(_rangeStart).take(100).toList();
  List<String> get _qualities {
    final values = _choices.map((e) => e.quality).toSet().toList();
    values.sort((a, b) => _qualityRank(b).compareTo(_qualityRank(a)));
    return values;
  }
  List<_DownloadChoice> get _visibleChoices => _choices.where((e) =>
      e.quality == _quality &&
      (!_series || (e.episode != null && e.episode.season == _season &&
        e.episode.episode > _rangeStart && e.episode.episode <= _rangeStart + 100))).toList();

  @override
  void initState() {
    super.initState();
    if (_series && _item.episodes.isNotEmpty) _season = _item.episodes.first.season;
    _scan();
  }

  String _qualityName(Source s) {
    final text = s.name;
    final match = RegExp(r'(2160p|1440p|1080p|720p|540p|480p|360p|4K|2K)', caseSensitive: false).firstMatch(text);
    return match?.group(0)?.toUpperCase() ?? 'Original';
  }

  int _qualityRank(String q) {
    final m = RegExp(r'\d+').firstMatch(q);
    return m == null ? 0 : int.tryParse(m.group(0)!) ?? 0;
  }

  bool _isDirectFile(Source s) {
    final path = Uri.tryParse(s.url ?? '')?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return false;
    return path.endsWith('.mp4') || s.name.toLowerCase().contains('mp4');
  }

  Future<List<Source>> _filesFor(Episode? ep) async {
    final sources = await getSources(_item, ep);
    final seen = <String>{};
    return sources.where((s) => s.playable && _isDirectFile(s) && seen.add(s.url!)).toList();
  }

  Future<void> _scan() async {
    setState(() { _loading = true; _error = null; _scanned = 0; _choices = []; _selected.clear(); _sizes.clear(); });
    try {
      if (!_series) {
        final sources = await _filesFor(null);
        _choices = sources.map((s) => _DownloadChoice(null, s, _qualityName(s), -1)).toList();
        if (_choices.isEmpty) throw Exception('No direct MP4 download source is available for this title.');
      } else {
        final eps = _pageEpisodes;
        _scanTotal = eps.length;
        final found = <_DownloadChoice>[];
        var cursor = 0;
        Future<void> worker() async {
          while (true) {
            final index = cursor++;
            if (index >= eps.length) return;
            final ep = eps[index];
            try {
              final sources = await _filesFor(ep);
              for (final source in sources) {
                found.add(_DownloadChoice(ep, source, _qualityName(source), -1));
              }
            } catch (_) {}
            if (mounted) setState(() => _scanned++);
          }
        }
        await Future.wait(List.generate(3, (_) => worker()));
        _choices = found;
        if (_choices.isEmpty) throw Exception('No direct MP4 sources were found in this episode range.');
      }
      final qs = _qualities;
      _quality = qs.isEmpty ? null : qs.first;
      if (_quality != null) await _loadSizes();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<int> _getSize(Source source) async {
    try {
      final response = await http.head(Uri.parse(source.url!), headers: source.headers)
          .timeout(const Duration(seconds: 10));
      final length = response.contentLength ?? int.tryParse(response.headers['content-length'] ?? '');
      return length ?? -1;
    } catch (_) { return -1; }
  }

  Future<void> _loadSizes() async {
    final matching = _choices.where((e) => e.quality == _quality).toList();
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= matching.length) return;
        final choice = matching[index];
        final size = await _getSize(choice.source);
        final key = _choiceKey(choice);
        _sizes[key] = size;
        final pos = _choices.indexOf(choice);
        if (pos >= 0) _choices[pos] = _DownloadChoice(choice.episode, choice.source, choice.quality, size);
      }
    }
    await Future.wait(List.generate(4, (_) => worker()));
    if (mounted) setState(() {});
  }

  String _choiceKey(_DownloadChoice c) => c.episode?.id ?? 'movie';
  String _sizeLabel(int n) {
    if (n < 0) return 'Size unavailable';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  String _safe(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_').replaceAll(RegExp(r'_+'), '_');

  Future<void> _selectDub(DubOption dub) async {
    setState(() { _loading = true; _quality = null; _choices = []; _selected.clear(); _sizes.clear(); });
    try {
      final next = _item.copyWith(id: dub.subjectId, detailPath: dub.detailPath);
      _item = await detailOf(next);
      _season = _seasons.isEmpty ? null : _seasons.first;
      _rangeStart = 0;
      await _scan();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _changeSeason(int s) async {
    setState(() { _season = s; _rangeStart = 0; });
    await _scan();
  }

  Future<void> _changeRange(int start) async {
    setState(() => _rangeStart = start);
    await _scan();
  }

  void _selectAll(bool value) {
    setState(() {
      if (value) {
        _selected.addAll(_visibleChoices.map(_choiceKey));
      } else {
        _selected.removeAll(_visibleChoices.map(_choiceKey));
      }
    });
  }

  Future<void> _startDownloads() async {
    final selected = <_DownloadChoice>[];
    if (_series) {
      final unique = <String, _DownloadChoice>{};
      for (final choice in _visibleChoices) {
        if (_selected.contains(_choiceKey(choice))) unique.putIfAbsent(_choiceKey(choice), () => choice);
      }
      selected.addAll(unique.values);
    } else {
      selected.addAll(_visibleChoices.take(1));
    }
    if (selected.isEmpty) return;
    setState(() => _queueing = true);
    try {
      for (final c in selected) {
        final epLabel = c.episode == null ? '' : '_S${c.episode!.season.toString().padLeft(2, '0')}E${c.episode!.episode.toString().padLeft(2, '0')}';
        final file = '${_safe(_item.title)}$epLabel_${_safe(c.quality)}.mp4';
        await DownloadService.instance.enqueue(
          url: c.source.url!,
          title: '${_item.title}${c.episode == null ? '' : ' · ${c.episode!.label}'} · ${c.quality}',
          fileName: file,
          headers: c.source.headers,
        );
      }
      if (mounted) {
        setState(() { _queueing = false; _selected.clear(); });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${selected.length} download(s) added to queue')));
      }
    } catch (e) {
      if (mounted) setState(() => _queueing = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  Widget _tabs(List<Widget> children) => SizedBox(
    height: 48,
    child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: children),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final seasons = _seasons;
    final episodes = _pageEpisodes;
    final choices = _visibleChoices;
    final allSelected = choices.isNotEmpty && choices.every((e) => _selected.contains(_choiceKey(e)));
    return Scaffold(
      appBar: AppBar(title: const Text('Download')),
      body: Column(children: [
        if (_item.dubs.length > 1)
          _tabs([for (final dub in _item.dubs) Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              showCheckmark: false,
              label: Text(dub.language + (dub.original ? ' · Original' : '')),
              selected: dub.subjectId == _item.id && dub.detailPath == _item.detailPath,
              onSelected: _loading ? null : (_) => _selectDub(dub),
            ),
          )]),
        if (_series && seasons.length > 1)
          _tabs([for (final s in seasons) Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              showCheckmark: false, label: Text(s == 0 ? 'Specials' : 'Season $s'),
              selected: s == _season, onSelected: _loading ? null : (_) => _changeSeason(s),
            ),
          )]),
        if (_series && _seasonEpisodes.length > 100)
          _tabs([for (var start = 0; start < _seasonEpisodes.length; start += 100) Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              showCheckmark: false,
              label: Text('${(start + 1).toString().padLeft(3, '0')}-${(start + 100 < _seasonEpisodes.length ? start + 100 : _seasonEpisodes.length).toString().padLeft(3, '0')}'),
              selected: _rangeStart == start, onSelected: _loading ? null : (_) => _changeRange(start),
            ),
          )]),
        if (_qualities.isNotEmpty)
          _tabs([for (final q in _qualities) Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(showCheckmark: false, label: Text(q), selected: q == _quality,
              onSelected: _loading ? null : (_) async { setState(() => _quality = q); await _loadSizes(); }),
          )]),
        if (_loading)
          Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_series ? 'Checking episodes $_scanned/$_scanTotal…' : 'Finding download qualities…'),
          ]))),
        if (!_loading && _error != null)
          Expanded(child: Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.download_for_offline_outlined, size: 42),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _scan, child: const Text('Retry')),
            ]),
          ))),
        if (!_loading && _error == null && !_series)
          Expanded(child: ListView(children: [
            if (choices.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: Text('${_item.title} · ${_quality ?? 'Original'}'),
                subtitle: Text(_sizeLabel(choices.first.size)),
                trailing: const Icon(Icons.download_outlined),
              ),
          ])),
        if (!_loading && _error == null && _series)
          Expanded(child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: episodes.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 100, mainAxisSpacing: 8, crossAxisSpacing: 8,
              childAspectRatio: .95,
            ),
            itemBuilder: (context, i) {
              final ep = episodes[i];
              final matching = choices.where((c) => c.episode?.id == ep.id).toList();
              final match = matching.isEmpty ? null : matching.first;
              final available = match != null;
              final selected = _selected.contains(ep.id);
              return Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                color: selected ? cs.primaryContainer : null,
                child: InkWell(
                  onTap: !available ? null : () => setState(() {
                    if (selected) { _selected.remove(ep.id); } else { _selected.add(ep.id); }
                  }),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('E${ep.episode.toString().padLeft(2, '0')}', style: TextStyle(fontWeight: FontWeight.w800, color: available ? cs.onSurface : cs.onSurface.withOpacity(.35))),
                    const SizedBox(height: 5),
                    Text(available ? _sizeLabel(match.size) : 'Unavailable',
                      style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant), textAlign: TextAlign.center),
                    if (selected) Icon(Icons.check_circle, size: 15, color: cs.primary),
                  ]),
                ),
              );
            },
          )),
      ]),
      bottomNavigationBar: _loading || _error != null ? null : SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            if (_series) ...[
              TextButton(onPressed: () => _selectAll(!allSelected), child: Text(allSelected ? 'Deselect all' : 'Select all')),
              const SizedBox(width: 8),
              Text('${_selected.length} selected', style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
            ] else
              const Spacer(),
            FilledButton.icon(
              onPressed: _queueing || (_series && _selected.isEmpty) ? null : _startDownloads,
              icon: _queueing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download, size: 18),
              label: Text(_queueing ? 'Adding…' : 'Download'),
            ),
          ]),
        ),
      ),
    );
  }
}
