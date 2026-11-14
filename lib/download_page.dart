import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https/return_code.dart';
import 'package:http/http.dart' as http;

import 'downloads_service.dart';
import 'models.dart';
import 'providers.dart';

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
  bool _queueing = false;
  String _downloadMode = 'all';

  bool get _series => _item.episodes.isNotEmpty || _item.type == 'series' || _item.subjectType == 2;
  List<int> get _seasons => (_item.episodes.map((e) => e.season).toSet().toList()..sort());
  List<Episode> get _seasonEpisodes => _item.episodes.where((e) => e.season == _season).toList()
    ..sort((a, b) => a.episode.compareTo(b.episode));
  List<Episode> get _pageEpisodes => _item.pid == 'storytv' ? _item.episodes : _seasonEpisodes.skip(_rangeStart).take(100).toList();
  List<String> get _qualities {
    final values = _choices.map((e) => e.quality).toSet().toList();
    values.sort((a, b) => _qualityRank(b).compareTo(_qualityRank(a)));
    return values;
  }
  List<_DownloadChoice> get _visibleChoices => _choices.where((e) {
    final ep = e.episode;
    return e.quality == _quality &&
        (!_series || (ep != null && (_item.pid == 'storytv' || (ep.season == _season &&
          ep.episode > _rangeStart && ep.episode <= _rangeStart + 100))));
  }).toList();

  @override
  void initState() {
    super.initState();
    if (_series && _item.episodes.isNotEmpty) _season = _item.episodes.first.season;
    _scan();
  }

  String _qualityName(Source s) {
    final uri = Uri.tryParse(s.url ?? '');
    final text = '${s.name} ${s.note ?? ''} ${uri?.path ?? ''} ${uri?.query ?? ''}';
    final match = RegExp(
      r'(4320|2160|1440|1080|900|720|540|480|360)\s*p?|4k|2k|uhd|fhd|hd',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) {
      if (text.toLowerCase().contains('auto')) return 'Auto';
      return 'Original';
    }
    final value = match.group(0)!.toUpperCase().replaceAll(' ', '');
    if (value == 'UHD' || value == '4K') return '4K';
    if (value == '2K') return '2K';
    if (value == 'FHD') return '1080p';
    if (value == 'HD') return '720p';
    return value.endsWith('P') ? value : '${value}p';
  }

  int _qualityRank(String q) {
    if (q == '4K') return 2160;
    if (q == '2K') return 1440;
    final m = RegExp(r'\d+').firstMatch(q);
    return m == null ? 0 : int.tryParse(m.group(0)!) ?? 0;
  }

  bool _isDirectFile(Source s) {
    final path = Uri.tryParse(s.url ?? '')?.path.toLowerCase() ?? '';
    if (_item.pid == 'storytv' && path.endsWith('.m3u8')) return true;
    if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return false;
    return path.endsWith('.mp4') || s.name.toLowerCase().contains('mp4');
  }

  Future<List<Source>> _storyTvVariants(Source master) async {
    final response = await http.get(Uri.parse(master.url!), headers: master.headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Could not read Story TV quality playlist.');
    }
    final lines = response.body.split(RegExp(r'\r?\n'));
    final result = <Source>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      var next = i + 1;
      while (next < lines.length && (lines[next].trim().isEmpty || lines[next].trim().startsWith('#'))) { next++; }
      if (next >= lines.length) continue;
      final resolution = RegExp(r'RESOLUTION=\d+x(\d+)', caseSensitive: false).firstMatch(line);
      final bandwidth = RegExp(r'BANDWIDTH=(\d+)', caseSensitive: false).firstMatch(line);
      var tier = resolution == null ? 0 : int.tryParse(resolution.group(1)!) ?? 0;
      if (tier == 0 && bandwidth != null) {
        final b = int.tryParse(bandwidth.group(1)!) ?? 0;
        tier = b >= 5000000 ? 1080 : b >= 2500000 ? 720 : b >= 1000000 ? 480 : 360;
      }
      if (tier <= 0) continue;
      result.add(Source.clean(name: '${tier}p',
        url: Uri.parse(master.url!).resolve(lines[next].trim()).toString(),
        headers: master.headers));
    }
    final seen = <String>{};
    final variants = result.where((s) => seen.add(s.url!)).toList()
      ..sort((a, b) => _qualityRank(b.name).compareTo(_qualityRank(a.name)));
    // Some Story TV episodes expose a media playlist (or a master playlist
    // without RESOLUTION metadata) instead of an EXT-X-STREAM-INF list.
    // It is still a valid HLS download source and FFmpeg can read it directly.
    if (variants.isEmpty) {
      return [Source.clean(name: 'Auto · adaptive quality',
        url: master.url!, headers: master.headers)];
    }
    return variants;
  }

  Future<List<Source>> _filesFor(Episode? ep) async {
    final sources = await getSources(_item, ep);
    if (_item.pid == 'storytv') {
      final masters = sources.where((s) => s.playable &&
        (Uri.tryParse(s.url!)?.path.toLowerCase().endsWith('.m3u8') ?? false));
      return masters.isEmpty ? [] : _storyTvVariants(masters.first);
    }
    final seen = <String>{};
    return sources.where((s) => s.playable && _isDirectFile(s) && seen.add(s.url!)).toList();
  }

  Future<void> _scan() async {
    setState(() { _loading = true; _error = null; _scanned = 0; _choices = []; _selected.clear(); });
    try {
      if (!_series) {
        final sources = await _filesFor(null);
        _choices = sources.map((s) => _DownloadChoice(null, s, _qualityName(s), -1)).toList()
        ..sort((a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
        if (_choices.isEmpty) throw Exception('No direct MP4 download source is available for this title.');
      } else {
        final eps = _item.pid == 'storytv' ? _item.episodes.take(1).toList() : _pageEpisodes;
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
        _choices = found..sort((a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
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
    final path = Uri.tryParse(source.url ?? '')?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return -1;
    try {
      final response = await http.head(Uri.parse(source.url!), headers: source.headers)
          .timeout(const Duration(seconds: 10));
      final length = response.contentLength ?? int.tryParse(response.headers['content-length'] ?? '');
      if (length != null && length > 0) return length;
    } catch (_) {}
    try {
      final response = await http.get(Uri.parse(source.url!), headers: {
        ...source.headers,
        'Range': 'bytes=0-0',
      }).timeout(const Duration(seconds: 10));
      final range = response.headers['content-range'];
      if (range != null && range.contains('/')) {
        final total = int.tryParse(range.substring(range.lastIndexOf('/') + 1));
        if (total != null && total > 0) return total;
      }
      final length = int.tryParse(response.headers['content-length'] ?? '');
      if (length != null && length > 1) return length;
    } catch (_) {}
    return -1;
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
    if (n <= 0) return 'Size unavailable';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  String _safe(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_').replaceAll(RegExp(r'_+'), '_');

  Future<void> _selectDub(DubOption dub) async {
    setState(() { _loading = true; _quality = null; _choices = []; _selected.clear(); });
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


  Future<void> _mergeStoryTvEpisodes(List<_DownloadChoice> selected, int taskId) async {
    if (selected.isEmpty) return;
    final sorted = [...selected]..sort((a, b) => a.episode!.season != b.episode!.season ? a.episode!.season.compareTo(b.episode!.season) : a.episode!.episode.compareTo(b.episode!.episode));
    final tempRoot = await getTemporaryDirectory();
    final work = Directory('${tempRoot.path}/storytv_${DateTime.now().microsecondsSinceEpoch}');
    await work.create(recursive: true);
    final outputDir = await getApplicationDocumentsDirectory();
    final fileName = '${_safe(_item.title)}_E${sorted.first.episode!.episode.toString().padLeft(3, '0')}-E${sorted.last.episode!.episode.toString().padLeft(3, '0')}.mp4';
    final output = '${outputDir.path}/$fileName';
    final concat = File('${work.path}/concat.txt');
    try {
      final paths = List<String?>.filled(sorted.length, null);
      var cursor = 0;
      var completed = 0;
      Object? workerError;
      Future<void> worker() async {
        while (true) {
          final i = cursor++;
          if (i >= sorted.length || workerError != null) return;
          try {
            final choice = sorted[i];
            await DownloadService.instance.updateMergeTask(taskId,
              completed: completed, total: sorted.length,
              phase: 'Downloading episode ${choice.episode!.episode} of ${sorted.length}');
            // Resolve a fresh signed CDN URL for every episode immediately before download.
            final sources = await getSources(_item, choice.episode);
            final master = sources.firstWhere(
              (x) => x.playable && (Uri.tryParse(x.url ?? '')?.path.toLowerCase().endsWith('.m3u8') ?? false),
              orElse: () => throw Exception('Episode ${choice.episode!.episode} stream is no longer available.'),
            );
            final variants = await _storyTvVariants(master);
            final source = variants.firstWhere((x) => x.name == choice.quality,
              orElse: () => variants.isNotEmpty ? variants.first : throw Exception('No downloadable quality found.'));
            final episodeFile = '${work.path}/episode_${i.toString().padLeft(4, '0')}.mp4';
            final headers = source.headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join();
            final samePlaylist = source.url == master.url;
            final ffmpegArgs = <String>[
              '-y',
              '-headers', headers, '-i', master.url!,
              if (!samePlaylist) ...[
                '-headers', headers, '-i', source.url!,
                '-map', '1:v:0', '-map', '0:a:0?',
              ] else ...[
                '-map', '0:v:0', '-map', '0:a:0?',
              ],
              '-c', 'copy', '-bsf:a', 'aac_adtstoasc', episodeFile,
            ];
            final session = await FFmpegKit.executeWithArguments(ffmpegArgs);
            final code = await session.getReturnCode();
            if (!ReturnCode.isSuccess(code)) {
              final logs = await session.getOutput();
              throw Exception('Episode ${choice.episode!.episode} failed. ${(logs ?? '').split('\n').reversed.take(5).toList().reversed.join(' ')}');
            }
            if (!await File(episodeFile).exists() || await File(episodeFile).length() == 0) {
              throw Exception('Episode ${choice.episode!.episode} produced an empty video.');
            }
            paths[i] = episodeFile;
            completed++;
            await DownloadService.instance.updateMergeTask(taskId,
              completed: completed, total: sorted.length,
              phase: 'Downloaded ${completed}/${sorted.length} episodes');
          } catch (e) {
            workerError ??= e;
          }
        }
      }
      await Future.wait(List.generate(sorted.length < 3 ? sorted.length : 3, (_) => worker()));
      if (workerError != null) throw workerError!;
      await concat.writeAsString(paths.map((p) => "file '${p!.replaceAll("'", "'\\''")}'\n").join());
      final merge = await FFmpegKit.executeWithArguments([
        '-y', '-f', 'concat', '-safe', '0', '-i', concat.path,
        '-c', 'copy', '-movflags', '+faststart', output,
      ]);
      final mergeCode = await merge.getReturnCode();
      if (!ReturnCode.isSuccess(mergeCode)) {
        throw Exception('Episodes could not be merged into one MP4. ${await merge.getOutput() ?? ''}');
      }
      if (DownloadService.instance.downloadLocation == 'both') {
        await DownloadService.instance.saveMergedToGallery(output, fileName);
      }
      final outputSize = await File(output).length();
      await DownloadService.instance.updateMergeTask(taskId, completed: outputSize, total: outputSize, phase: 'Completed', status: 'complete', localUri: File(output).uri.toString(), fileName: fileName);
    } catch (e) {
      await DownloadService.instance.updateMergeTask(taskId, completed: 0, total: sorted.length, phase: 'Failed: $e', status: 'failed', reason: 1);
    } finally {
      if (await work.exists()) await work.delete(recursive: true);
    }
  }

  Future<void> _startDownloads() async {
    final selected = <_DownloadChoice>[];
    if (_item.pid == 'storytv' && _series) {
      final episodes = _downloadMode == 'all'
          ? _item.episodes
          : _item.episodes.where((e) => _selected.contains(e.id)).toList();
      if (episodes.isEmpty) return;
      final template = _choices.firstWhere((e) => e.quality == _quality);
      selected.addAll(episodes.map((e) => _DownloadChoice(e, template.source, _quality ?? template.quality, -1)));
    } else if (_series) {
      final unique = <String, _DownloadChoice>{};
      for (final choice in _visibleChoices) {
        if (_selected.contains(_choiceKey(choice))) unique.putIfAbsent(_choiceKey(choice), () => choice);
      }
      selected.addAll(unique.values);
    } else if (_visibleChoices.isNotEmpty) {
      selected.add(_visibleChoices.first);
    }
    if (selected.isEmpty) return;
    if (_item.pid == 'storytv' && _series) {
      final taskId = await DownloadService.instance.createMergeTask(
        '${_item.title} · ${selected.length} episodes', selected.length);
      // Keep the merge alive after this route closes; the Downloads tab observes
      // its persisted progress record and remains usable while FFmpeg runs.
      _mergeStoryTvEpisodes(selected, taskId);
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        DownloadService.instance.onOpenDownloads?.call();
      }
      return;
    }
    setState(() => _queueing = true);
    try {
      for (final c in selected) {
        final epLabel = c.episode == null ? '' : '_S${c.episode!.season.toString().padLeft(2, '0')}E${c.episode!.episode.toString().padLeft(2, '0')}';
        final file = '${_safe(_item.title)}${epLabel}_${_safe(c.quality)}.mp4';
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
        if (_series && _item.pid != 'storytv' && _seasonEpisodes.length > 100)
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
        if (!_loading && _error == null && _series && _item.pid == 'storytv')
          Expanded(child: _downloadMode == 'all'
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.video_library_outlined, size: 42),
                const SizedBox(height: 10),
                Text('All episodes · ${_item.episodes.length} episodes'),
                const SizedBox(height: 4),
                const Text('Will be merged into one video', style: TextStyle(fontSize: 12)),
              ]))
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                itemCount: episodes.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5, mainAxisSpacing: 9, crossAxisSpacing: 9,
                  childAspectRatio: 1.12,
                ),
                itemBuilder: (context, i) {
                  final ep = episodes[i];
                  final available = _item.pid == 'storytv' || choices.any((x) => x.episode?.id == ep.id);
                  final selected = _selected.contains(ep.id);
                  return Card(
                    margin: EdgeInsets.zero,
                    color: selected ? cs.primaryContainer : null,
                    child: InkWell(
                      onTap: !available ? null : () => setState(() {
                        if (selected) { _selected.remove(ep.id); } else { _selected.add(ep.id); }
                      }),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text(ep.episode.toString().padLeft(3, '0'),
                          style: TextStyle(fontWeight: FontWeight.w800,
                            color: available ? cs.onSurface : cs.onSurface.withOpacity(.35))),
                        const SizedBox(height: 3),
                        Text(selected ? 'Selected' : (available ? 'Episode' : 'Unavailable'),
                          style: const TextStyle(fontSize: 10)),
                      ]),
                    ),
                  );
                },
              )),
        if (!_loading && _error == null && _series && _item.pid != 'storytv')
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
                    Text(available ? _sizeLabel(match!.size) : 'Unavailable',
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_series && _item.pid == 'storytv')
              Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: _queueing ? null : () => setState(() { _downloadMode = 'all'; _selected.clear(); }),
                  style: OutlinedButton.styleFrom(backgroundColor: _downloadMode == 'all' ? cs.primaryContainer : null),
                  child: const Text('All in One Download'),
                )),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(
                  onPressed: _queueing ? null : () => setState(() => _downloadMode = 'custom'),
                  style: OutlinedButton.styleFrom(backgroundColor: _downloadMode == 'custom' ? cs.primaryContainer : null),
                  child: const Text('Custom Download'),
                )),
              ]),
            if (_series && _item.pid == 'storytv' && _downloadMode == 'custom')
              Row(children: [
                TextButton(onPressed: () => setState(() => _selected.addAll(episodes
                  .where((e) => _item.pid == 'storytv' || choices.any((x) => x.episode?.id == e.id)).map((e) => e.id))),
                  child: const Text('Select All')),
                Text('${_selected.length} selected'),
                const Spacer(),
                TextButton(onPressed: () async {
                  final controller = TextEditingController();
                  final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
                    title: const Text('Custom episode range'),
                    content: TextField(controller: controller, autofocus: true,
                      decoration: const InputDecoration(hintText: '1-8,10,12-19')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Apply')),
                    ],
                  ));
                  if (value == null) return;
                  try {
                    final nums = <int>{};
                    for (final part in value.split(',')) {
                      final bits = part.trim().split('-');
                      if (bits.length == 1) { nums.add(int.parse(bits[0])); }
                      else if (bits.length == 2) {
                        final a = int.parse(bits[0]); final b = int.parse(bits[1]);
                        if (a <= 0 || b < a || b - a > 5000) throw FormatException();
                        nums.addAll(List.generate(b - a + 1, (i) => a + i));
                      } else { throw FormatException(); }
                    }
                    setState(() {
                      _selected
                        ..clear()
                        ..addAll(_item.episodes.where((e) => nums.contains(e.episode) &&
                          (_item.pid == 'storytv' || choices.any((x) => x.episode?.id == e.id))).map((e) => e.id));
                    });
                  } catch (_) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invalid range. Example: 1-8,10,12-19')));
                  }
                }, child: const Text('Custom Range')),
              ]),
            Row(children: [
              if (!_series) const Spacer(),
              if (_series && _item.pid != 'storytv') ...[
                TextButton(onPressed: () => _selectAll(!allSelected), child: Text(allSelected ? 'Deselect all' : 'Select all')),
                Text('${_selected.length} selected'), const Spacer(),
              ],
              if (_series && _item.pid == 'storytv' && _downloadMode == 'custom') const Spacer(),
              FilledButton.icon(
                onPressed: _queueing || (_series && _item.pid == 'storytv' && _downloadMode == 'custom' && _selected.isEmpty)
                  || (_series && _item.pid != 'storytv' && _selected.isEmpty) ? null : _startDownloads,
                icon: _queueing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download, size: 18),
                label: Text(_queueing ? 'Merging…' : 'Download'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

