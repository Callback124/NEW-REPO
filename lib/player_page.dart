import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';
import 'providers.dart';
import 'store.dart';
import 'widgets.dart';

const Color _kSeek = Color(0xFFE8335F);

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.item, this.ep, this.list = const [], this.localFile});
  final Item item;
  final File? localFile;
  final Episode? ep;
  final List<Episode> list;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _player;
  late Item _item = widget.item;

  late Episode? _ep = widget.ep;
  late List<Episode> _episodes = widget.list;
  List<Source> _srcs = const [];
  Source? _cur;
  String? _msg = 'Finding sources…';
  bool _ended = false;
  bool _showPickInMsg = false;
  Duration? _startAt;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  int _gen = 0;
  bool _transitioning = false;
  bool _locked = false;

  bool _visible = true;
  Timer? _hideTimer;
  double _rate = 1.0;
  int _fitI = 0;
  static const List<(BoxFit, String)> _fits = [
    (BoxFit.contain, 'Fit'),
    (BoxFit.cover, 'Cover'),
    (BoxFit.fill, 'Stretch'),
  ];
  static const List<double> _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIChangeCallback((visible) async {
      if (visible) await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    });
    if (widget.localFile != null) {
      _loadLocal(widget.localFile!);
    } else {
      _setup();
    }
  }

  List<Episode> get _episodeSequence {
    final sorted = [..._episodes]
      ..sort((a, b) => a.season != b.season ? a.season.compareTo(b.season) : a.episode.compareTo(b.episode));
    final seen = <String>{};
    return sorted.where((e) => seen.add(e.id)).toList();
  }

  Episode? get _next {
    if (_ep == null) return null;
    final sequence = _episodeSequence;
    final i = sequence.indexWhere((e) => e.id == _ep!.id);
    return i >= 0 && i + 1 < sequence.length ? sequence[i + 1] : null;
  }

  Episode? get _previous {
    if (_ep == null) return null;
    final sequence = _episodeSequence;
    final i = sequence.indexWhere((e) => e.id == _ep!.id);
    return i > 0 ? sequence[i - 1] : null;
  }

  /* ---- sources ---- */

  Future<void> _setup() async {
    final gen = ++_gen;
    setState(() {
      _msg = 'Finding sources…';
      _showPickInMsg = false;
      _ended = false;
      _srcs = const [];
      _cur = null;
    });
    try {
      final l = await getSources(_item, _ep);
      if (!mounted || gen != _gen) return;
      _srcs = l;
      final ok = l.where((s) =>
          s.playable && (_sourceResolution(s) == 0 || _sourceResolution(s) <= 1080)).toList()
        ..sort((a, b) => _sourceResolution(b).compareTo(_sourceResolution(a)));
      if (l.isEmpty) {
        _transitioning = false;
        setState(() => _msg = 'No sources were returned by MovieBox for this episode.');
      } else if (ok.isEmpty) {
        _transitioning = false;
        setState(() {
          _msg = 'No supported source found. This device supports up to 1080p; 4K/above streams exceed its decoder capabilities.';
          _showPickInMsg = true;
        });
      } else {
        // Try the highest supported variant first, then fall back to lower qualities
        // if this device's decoder cannot initialize the selected stream.
        for (final source in ok) {
          final loaded = await _load(source);
          if (loaded) return;
          if (!mounted || gen != _gen) return;
        }
        _transitioning = false;
        if (mounted) setState(() {
          _msg = 'None of the available Story TV qualities could be played on this device.';
          _showPickInMsg = true;
          _buffering = false;
        });
      }
    } catch (e) {
      _transitioning = false;
      if (mounted && gen == _gen) setState(() => _msg = e.toString());
    }
  }

  void _onPlayerChanged() {
    final controller = _player;
    if (!mounted || controller == null || !controller.value.isInitialized) return;
    if (_transitioning) return;
    final value = controller.value;
    if (_startAt != null && value.duration > Duration.zero) {
      final seek = _startAt!;
      _startAt = null;
      controller.seekTo(seek);
    }
    final now = DateTime.now();
    if (value.duration.inSeconds > 0 && value.position.inSeconds > 1 &&
        now.difference(_lastSave).inSeconds >= 5) {
      _lastSave = now;
      app.setProgress(_item, _ep, value.position.inSeconds.toDouble(),
          value.duration.inSeconds.toDouble());
    }
    if (value.hasError) {
      setState(() {
        _msg = value.errorDescription ?? 'This source could not be played. Try another one.';
        _showPickInMsg = true;
      });
      return;
    }
    if (value.isCompleted && !_ended) {
      final d = value.duration.inSeconds.toDouble();
      if (d > 0) app.setProgress(_item, _ep, d, d);
      setState(() => _ended = true);
      if (_next != null) _playNext();
    } else {
      setState(() {
        if (value.isPlaying) _msg = null;
        _buffering = value.isBuffering;
      });
      if (value.isPlaying != _wasPlaying) {
        _wasPlaying = value.isPlaying;
        if (value.isPlaying) {
          _kick();
        } else {
          _hideTimer?.cancel();
        }
      }
    }
  }

  bool _buffering = false;
  bool _wasPlaying = false;

  Future<bool> _load(Source s) async {
    final pr = app.progress[progressKey(_item, _ep)];
    final resume = pr != null && pr.t > 5 && pr.d - pr.t > 10;
    _startAt = resume ? Duration(seconds: pr.t.toInt()) : null;
    setState(() {
      _cur = s;
      _msg = 'Loading…';
      _showPickInMsg = false;
      _ended = false;
      _buffering = true;
    });
    final old = _player;
    old?.removeListener(_onPlayerChanged);
    if (old != null) await old.dispose();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(s.url!),
      httpHeaders: s.headers,
      videoPlayerOptions: VideoPlayerOptions(),
    );
    _player = controller;
    try {
      await controller.initialize();
      if (!mounted || _player != controller) return false;
      final videoSize = controller.value.size;
      final isLandscape = videoSize.width >= videoSize.height;
      await SystemChrome.setPreferredOrientations(isLandscape
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      await controller.setLooping(false);
      await controller.setPlaybackSpeed(_rate);
      if (_startAt != null) {
        await controller.seekTo(_startAt!);
        _startAt = null;
      }
      _transitioning = false;
      controller.addListener(_onPlayerChanged);
      setState(() {
        _msg = null;
        _buffering = false;
      });
      await controller.play();
      if (mounted) setState(() {});
      return true;
    } catch (e) {
      _transitioning = false;
      if (!mounted) return false;
      setState(() {
        _msg = 'Player error: $e';
        _showPickInMsg = true;
        _buffering = false;
      });
      return false;
    }
  }

  Future<void> _loadLocal(File file) async {
    setState(() {
      _msg = 'Loading offline video…';
      _showPickInMsg = false;
      _ended = false;
      _buffering = true;
      _cur = null;
      _srcs = const [];
    });
    final old = _player;
    old?.removeListener(_onPlayerChanged);
    if (old != null) await old.dispose();
    final controller = VideoPlayerController.file(file);
    _player = controller;
    try {
      await controller.initialize();
      if (!mounted || _player != controller) return;
      final landscape = controller.value.size.width >= controller.value.size.height;
      await SystemChrome.setPreferredOrientations(landscape
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      await controller.setLooping(false);
      await controller.setPlaybackSpeed(_rate);
      _transitioning = false;
      controller.addListener(_onPlayerChanged);
      setState(() {
        _msg = null;
        _buffering = false;
      });
      await controller.play();
      if (mounted) setState(() {});
    } catch (e) {
      _transitioning = false;
      if (!mounted) return;
      setState(() {
        _msg = 'Offline playback error: $e';
        _showPickInMsg = false;
        _buffering = false;
      });
    }
  }

  void _pickSource() {
    if (_srcs.isEmpty || !mounted) return;
    _sheet('Sources', [
      for (final s in _srcs)
        ListTile(
          title: Text(s.name),
          subtitle: _sourceResolution(s) > 1080
              ? const Text('Above 1080p · Not supported on this device')
              : (s.note != null ? Text(s.note!) : null),
          enabled: (s.playable && (_sourceResolution(s) == 0 || _sourceResolution(s) <= 1080)) || s.link != null,
          trailing: _cur == s
              ? const Icon(Icons.check)
              : (s.link != null ? const Icon(Icons.open_in_new, size: 18) : null),
          onTap: () {
            Navigator.pop(context);
            if (s.playable) {
              _load(s);
            } else if (s.link != null) {
              launchUrl(Uri.parse(s.link!), mode: LaunchMode.externalApplication);
            }
          },
        ),
    ]);
  }

  void _playNext() {
    if (_transitioning) return;
    final n = _next;
    if (n == null) return;
    _transitioning = true;
    _saveNow();
    _player?.pause();
    setState(() => _ep = n);
    _setup();
  }

  void _playPrevious() {
    if (_transitioning) return;
    final previous = _previous;
    if (previous == null) return;
    _transitioning = true;
    _saveNow();
    _player?.pause();
    setState(() => _ep = previous);
    _setup();
  }

  void _saveNow() {
    final value = _player?.value;
    if (value == null || !value.isInitialized) return;
    final d = value.duration.inSeconds.toDouble();
    final t = value.position.inSeconds.toDouble();
    if (d > 0 && t > 1) app.setProgress(_item, _ep, t, d);
  }

  /* ---- controls ---- */

  void _kick() {
    _hideTimer?.cancel();
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    if (_player?.value.isPlaying ?? false) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && (_player?.value.isPlaying ?? false)) setState(() => _visible = false);
      });
    }
  }

  void _toggleUi() {
    if (_locked) return;
    if (_visible) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      _kick();
    }
  }

  void _skip(int seconds) {
    final controller = _player;
    if (controller == null || !controller.value.isInitialized) return;
    final p = controller.value.position + Duration(seconds: seconds);
    final d = controller.value.duration;
    controller.seekTo(p < Duration.zero ? Duration.zero : (p > d ? d : p));
    _kick();
  }

  Future<void> _sheet(String title, List<Widget> children) {
    _hideTimer?.cancel();
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(title,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ...children,
          ],
        ),
      ),
    ).whenComplete(_kick);
  }

  int _sourceResolution(Source s) {
    final namedQuality = RegExp(r'(\\d{3,4})\\s*p?', caseSensitive:false).firstMatch(s.name);
    if (namedQuality != null) {
      final namedValue = int.tryParse(namedQuality.group(1) ?? '') ?? 0;
      if (namedValue >= 240 && namedValue <= 4320) return namedValue;
    }
    final text = '${s.name} ${s.note ?? ''} ${s.url ?? ''}'.toLowerCase();
    if (RegExp(r'\b(8k|4320)\b').hasMatch(text)) return 4320;
    if (RegExp(r'\b(4k|2160|uhd)\b').hasMatch(text)) return 2160;
    final matches = RegExp(r'\b(\d{3,4})\s*p?\b').allMatches(text);
    var best = 0;
    for (final m in matches) {
      final value = int.tryParse(m.group(1) ?? '') ?? 0;
      if (value >= 240 && value <= 4320 && value > best) best = value;
    }
    return best;
  }

  Future<void> _switchDub(DubOption dub) async {
    if (dub.subjectId == _item.id && dub.detailPath == _item.detailPath) return;
    final previous = _player?.value.position ?? Duration.zero;
    final previousSeason = _ep?.season;
    final previousEpisode = _ep?.episode;
    final current = _item.copyWith(id: dub.subjectId, detailPath: dub.detailPath);
    setState(() {
      _item = current;
      _ep = null;
      _msg = 'Loading ${dub.language}…';
      _srcs = const [];
      _cur = null;
    });
    try {
      final fresh = await detailOf(current);
      if (!mounted) return;
      setState(() {
        _item = fresh;
        _episodes = fresh.episodes;
        _ep = fresh.episodes.isEmpty
            ? null
            : fresh.episodes.cast<Episode?>().firstWhere(
                (e) => e!.season == previousSeason && e.episode == previousEpisode,
                orElse: () => fresh.episodes.first);
      });
      await _setup();
      if (previous > Duration.zero && _player?.value.isInitialized == true) {
        await _player!.seekTo(previous);
      }
    } catch (e) {
      if (mounted) setState(() => _msg = 'Could not switch audio: $e');
    }
  }

  void _pickAudio() {
    _sheet('Audio', [
      if (_item.dubs.isEmpty)
        const ListTile(title: Text('No alternate languages available')),
      for (final dub in _item.dubs)
        ListTile(
          title: Text(dub.language + (dub.original ? ' · Original' : '')),
          trailing: dub.subjectId == _item.id && dub.detailPath == _item.detailPath
              ? const Icon(Icons.check, color: Colors.green)
              : null,
          onTap: () {
            Navigator.pop(context);
            _switchDub(dub);
          },
        ),
    ]);
  }

  void _lockControls() {
    _hideTimer?.cancel();
    setState(() { _locked = true; _visible = true; });
  }

  void _unlockControls() {
    setState(() { _locked = false; _visible = true; });
    _kick();
  }

  void _selectEpisode(Episode episode) {
    if (_ep?.id == episode.id || _transitioning) return;
    _transitioning = true;
    _saveNow();
    _player?.pause();
    setState(() => _ep = episode);
    _setup();
  }

  Future<void> _pickEpisodes() {
    _hideTimer?.cancel();
    final seasons = (_episodes.map((e) => e.season).toSet().toList()..sort());
    final isStoryTv = _item.pid == 'storytv';
    var selectedSeason = _ep?.season ?? seasons.first;
    var rangeStart = 0;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateSheet) {
          final seasonEpisodes = _episodes
              .where((e) => e.season == selectedSeason)
              .toList()
            ..sort((a, b) => a.episode.compareTo(b.episode));
          final rangeCount = (seasonEpisodes.length + 99) ~/ 100;
          if (rangeStart >= rangeCount * 100) rangeStart = 0;
          final visible = seasonEpisodes.skip(rangeStart).take(100).toList();
          return SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .78,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Text('Episodes',
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (!isStoryTv && seasons.length > 1)
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final season in seasons)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              showCheckmark: false,
                              label: Text(season == 0 ? 'Specials' : 'Season $season'),
                              selected: selectedSeason == season,
                              onSelected: (_) => updateSheet(() {
                                selectedSeason = season;
                                rangeStart = 0;
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (rangeCount > 1)
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (var r = 0; r < rangeCount; r++)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              showCheckmark: false,
                              label: Text(
                                '${(r * 100 + 1).toString().padLeft(3, '0')}-${((r + 1) * 100 < seasonEpisodes.length ? (r + 1) * 100 : seasonEpisodes.length).toString().padLeft(3, '0')}',
                              ),
                              selected: rangeStart == r * 100,
                              onSelected: (_) => updateSheet(() => rangeStart = r * 100),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                    itemCount: visible.length,
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 76,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemBuilder: (context, i) {
                      final episode = visible[i];
                      final selected = episode.id == _ep?.id;
                      final number = episode.episode == 0 ? i + rangeStart + 1 : episode.episode;
                      return Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            _selectEpisode(episode);
                          },
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('E${number.toString().padLeft(2, '0')}',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                                    color: selected ? Theme.of(ctx).colorScheme.primary : Theme.of(ctx).colorScheme.onSurface)),
                              ],
                            ),
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
      ),
    ).whenComplete(_kick);
  }

  void _pickSpeed() {
    _sheet('Playback speed', [
      for (final r in _rates)
        ListTile(
          title: Text('${r}x'),
          trailing: r == _rate ? const Icon(Icons.check) : null,
          onTap: () {
            _player?.setPlaybackSpeed(r);
            setState(() => _rate = r);
            Navigator.pop(context);
          },
        ),
    ]);
  }

  String _qualityLabel() {
    final m = RegExp(r'(\d{3,4}p|4K)', caseSensitive: false).firstMatch(_cur?.name ?? '');
    return m != null ? m.group(1)! : 'Source';
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '${d.inMinutes}:$s';
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveNow();
    app.progressRev.value++;
    _player?.removeListener(_onPlayerChanged);
    final controller = _player;
    if (controller != null) {
      unawaited(controller.dispose());
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  /* ---- layout ---- */

  @override
  Widget build(BuildContext context) {
    final next = _next;
    final msgOn = _msg != null || (_ended && next != null);
    final showUi = _visible || msgOn;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_player != null && _player!.value.isInitialized)
            SizedBox.expand(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final videoSize = _player!.value.size;
                  return ClipRect(
                    child: FittedBox(
                      fit: _fits[_fitI].$1,
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: videoSize.width,
                        height: videoSize.height,
                        child: VideoPlayer(_player!),
                      ),
                    ),
                  );
                },
              ),
            )
          else
            const ColoredBox(color: Colors.black),
          GestureDetector(behavior: HitTestBehavior.opaque, onTap: _locked ? null : _toggleUi),
          IgnorePointer(
            ignoring: !showUi,
            child: AnimatedOpacity(
              opacity: showUi ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleUi,
                child: _controls(context, msgOn, next),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context, bool msgOn, Episode? next) {
    if (_locked) {
      return ColoredBox(
        color: Colors.transparent,
        child: SafeArea(child: Align(
          alignment: Alignment.topLeft,
          child: IconButton(
            tooltip: 'Unlock controls', onPressed: _unlockControls,
            color: Colors.white, iconSize: 24,
            icon: const Icon(Icons.lock_open_rounded),
          ),
        )),
      );
    }
    return ColoredBox(
      color: Colors.black54,
      child: SafeArea(
        left: true, right: true, top: false, bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
          child: Column(
            children: [
              _topRow(),
              Expanded(child: msgOn ? _messageBody(next) : Center(child: _centerRow(context))),
              if (!msgOn) _bottom(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topRow() {
    final sub = _ep != null ? '${_ep!.label} · ${_ep!.title}' : (_item.year ?? '');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          color: Colors.white,
          iconSize: 34,
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                if (sub.isNotEmpty)
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ),
          ),
        ),
        IconButton(
          color: Colors.white,
          icon: const Icon(Icons.cast),
          tooltip: 'Cast',
          onPressed: () => toast(context, 'Casting is not available yet'),
        ),
      ],
    );
  }

  Widget _centerRow(BuildContext context) {
    final previous = _previous;
    final next = _next;
    final hasEpisodeNavigation = _episodes.length > 1 && _ep != null;

    Widget control({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
      double size = 42,
      Color color = Colors.white70,
    }) => IconButton(
      constraints: BoxConstraints.tightFor(width: size + 12, height: size + 12),
      padding: EdgeInsets.zero,
      color: color,
      iconSize: size,
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (hasEpisodeNavigation) ...[
          control(
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous episode',
            color: previous == null ? Colors.white24 : Colors.white,
            onPressed: previous == null ? null : _playPrevious,
            size: 42,
          ),
          const SizedBox(width: 20),
        ],
        control(
          icon: Icons.replay_10_rounded,
          tooltip: 'Back 10 seconds',
          onPressed: () => _skip(-10),
          size: 42,
        ),
        const SizedBox(width: 20),
        _buffering
            ? const SizedBox(
                width: 68, height: 68,
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                ),
              )
            : control(
                icon: (_player?.value.isPlaying ?? false)
                    ? Icons.pause_rounded : Icons.play_arrow_rounded,
                tooltip: (_player?.value.isPlaying ?? false) ? 'Pause' : 'Play',
                onPressed: () {
                  final c = _player;
                  if (c == null) return;
                  c.value.isPlaying ? c.pause() : c.play();
                },
                size: 64,
                color: Colors.white,
              ),
        const SizedBox(width: 20),
        control(
          icon: Icons.forward_10_rounded,
          tooltip: 'Forward 10 seconds',
          onPressed: () => _skip(10),
          size: 42,
        ),
        if (hasEpisodeNavigation) ...[
          const SizedBox(width: 20),
          control(
            icon: Icons.skip_next_rounded,
            tooltip: 'Next episode',
            color: next == null ? Colors.white24 : Colors.white,
            onPressed: next == null ? null : _playNext,
            size: 42,
          ),
        ],
      ],
    );
  }

  Widget _bottom() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_player == null)
          Row(children: [const SizedBox(width: 50), Expanded(child: Container(height: 3, color: Colors.white24)), const SizedBox(width: 56)])
        else
          AnimatedBuilder(
          animation: _player!,
          builder: (context, _) {
            final value = _player?.value;
            final pos = value?.position ?? Duration.zero;
            final dur = value?.duration ?? Duration.zero;
            final buffer = value?.buffered.isNotEmpty == true
                ? value!.buffered.last.end : Duration.zero;
            return Row(
              children: [
                SizedBox(width: 50, child: Text(_fmt(pos),
                    style: const TextStyle(color: Colors.white, fontSize: 13))),
                Expanded(child: _SeekBar(
                  position: pos, duration: dur, buffer: buffer,
                  onSeek: (d) { _player?.seekTo(d); _kick(); },
                )),
                SizedBox(width: 56, child: Text(_fmt(dur), textAlign: TextAlign.end,
                    style: const TextStyle(color: Colors.white, fontSize: 13))),
              ],
            );
          },
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            _opt(Icons.graphic_eq, 'Audio', _pickAudio),
            _opt(Icons.lock_outline_rounded, 'Lock', _lockControls),
            if (_episodes.isNotEmpty && _ep != null)
              _opt(Icons.grid_view_rounded, 'Episodes', _pickEpisodes)
            else
              _opt(Icons.speed, _rate.toStringAsFixed(_rate == _rate.roundToDouble() ? 1 : 2), _pickSpeed),
            _opt(Icons.video_settings, _qualityLabel(), _pickSource),
            _opt(Icons.crop_free, _fits[_fitI].$2, () {
              setState(() => _fitI = (_fitI + 1) % _fits.length);
              _kick();
            }),
          ],
        ),
      ],
    );
  }

  Widget _opt(IconData icon, String label, VoidCallback onTap) {
    final portrait = MediaQuery.sizeOf(context).height > MediaQuery.sizeOf(context).width;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: portrait
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 22, color: Colors.white),
                    const SizedBox(height: 4),
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 22, color: Colors.white),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 14)),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _messageBody(Episode? next) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_msg != null) ...[
            Text(_msg!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            if (_showPickInMsg) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _pickSource, child: const Text('Choose source')),
            ],
          ],
        ],
      ),
    );
  }
}

/// Thin seek bar: dim track, buffered segment, pink progress and a round thumb.
class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.position,
    required this.duration,
    required this.buffer,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final Duration buffer;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  double _frac(double dx, double w) => w <= 0 ? 0 : (dx / w).clamp(0.0, 1.0);

  void _commit(double f) {
    final ms = (widget.duration.inMilliseconds * f).round();
    widget.onSeek(Duration(milliseconds: ms));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final total = widget.duration.inMilliseconds;
        final played = total > 0 ? widget.position.inMilliseconds / total : 0.0;
        final buffered = total > 0 ? widget.buffer.inMilliseconds / total : 0.0;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _commit(_frac(d.localPosition.dx, w)),
          onHorizontalDragStart: (d) => setState(() => _drag = _frac(d.localPosition.dx, w)),
          onHorizontalDragUpdate: (d) => setState(() => _drag = _frac(d.localPosition.dx, w)),
          onHorizontalDragEnd: (_) {
            final f = _drag;
            setState(() => _drag = null);
            if (f != null) _commit(f);
          },
          child: SizedBox(
            height: 32,
            child: CustomPaint(
              painter: _SeekPainter(
                played: (_drag ?? played).clamp(0.0, 1.0),
                buffered: buffered.clamp(0.0, 1.0),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({required this.played, required this.buffered});
  final double played;
  final double buffered;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final r = Radius.circular(2);
    RRect bar(double to) => RRect.fromLTRBR(0, y - 1.5, size.width * to, y + 1.5, r);
    canvas.drawRRect(bar(1), Paint()..color = Colors.white24);
    if (buffered > played) canvas.drawRRect(bar(buffered), Paint()..color = Colors.white54);
    canvas.drawRRect(bar(played), Paint()..color = _kSeek);
    canvas.drawCircle(Offset(size.width * played, y), 6.5, Paint()..color = _kSeek);
  }

  @override
  bool shouldRepaint(_SeekPainter old) => old.played != played || old.buffered != buffered;
}
