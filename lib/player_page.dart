import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';
import 'providers.dart';
import 'store.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.item, this.ep, this.list = const []});
  final Item item;
  final Episode? ep;
  final List<Episode> list;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  final List<StreamSubscription<dynamic>> _subs = [];

  late Episode? _ep = widget.ep;
  List<Source> _srcs = const [];
  Source? _cur;
  String? _msg = 'Finding sources…';
  bool _ended = false;
  bool _showPickInMsg = false;
  Duration? _startAt;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  int _gen = 0;

  Episode? get _next {
    if (_ep == null) return null;
    final i = widget.list.indexWhere((e) => e.id == _ep!.id);
    return i >= 0 && i + 1 < widget.list.length ? widget.list[i + 1] : null;
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _subs.add(_player.stream.duration.listen((d) {
      if (_startAt != null && d > Duration.zero) {
        _player.seek(_startAt!);
        _startAt = null;
      }
    }));
    _subs.add(_player.stream.position.listen((pos) {
      final d = _player.state.duration;
      final now = DateTime.now();
      if (d.inSeconds > 0 && pos.inSeconds > 1 && now.difference(_lastSave).inSeconds >= 5) {
        _lastSave = now;
        app.setProgress(widget.item, _ep, pos.inSeconds.toDouble(), d.inSeconds.toDouble());
      }
    }));
    _subs.add(_player.stream.playing.listen((p) {
      if (p && _msg != null && mounted) setState(() => _msg = null);
    }));
    _subs.add(_player.stream.completed.listen((done) {
      if (!done || !mounted) return;
      final d = _player.state.duration.inSeconds.toDouble();
      if (d > 0) app.setProgress(widget.item, _ep, d, d);
      setState(() => _ended = true);
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (e.isEmpty || !mounted) return;
      setState(() {
        _msg = 'This source could not be played. Try another one.';
        _showPickInMsg = true;
      });
    }));
    _setup();
  }

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
      final l = await getSources(widget.item, _ep);
      if (!mounted || gen != _gen) return;
      _srcs = l;
      final ok = l.where((s) => s.playable).toList();
      if (l.isEmpty) {
        setState(() => _msg = 'No sources were found for this title.');
      } else if (ok.isEmpty) {
        setState(() {
          _msg = 'None of these sources can play in the app.';
          _showPickInMsg = true;
        });
      } else if (ok.length == 1 || app.autoplay) {
        await _load(ok.first);
      } else {
        setState(() {
          _msg = 'Choose a source to start watching.';
          _showPickInMsg = true;
        });
        _pickSource();
      }
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _msg = e.toString());
    }
  }

  Future<void> _load(Source s) async {
    final pr = app.progress[progressKey(widget.item, _ep)];
    final resume = pr != null && pr.t > 5 && pr.d - pr.t > 10;
    _startAt = resume ? Duration(seconds: pr.t.toInt()) : null;
    setState(() {
      _cur = s;
      _msg = 'Loading…';
      _showPickInMsg = false;
      _ended = false;
    });
    await _player.open(Media(s.url!));
  }

  void _pickSource() {
    if (_srcs.isEmpty || !mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Sources', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            for (final s in _srcs)
              ListTile(
                title: Text(s.name),
                subtitle: s.note != null ? Text(s.note!) : null,
                enabled: s.playable || s.link != null,
                trailing: _cur == s
                    ? const Icon(Icons.check)
                    : (s.link != null ? const Icon(Icons.open_in_new, size: 18) : null),
                onTap: () {
                  Navigator.pop(ctx);
                  if (s.playable) {
                    _load(s);
                  } else if (s.link != null) {
                    launchUrl(Uri.parse(s.link!), mode: LaunchMode.externalApplication);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  void _playNext() {
    final n = _next;
    if (n == null) return;
    _saveNow();
    _player.stop();
    setState(() => _ep = n);
    _setup();
  }

  void _saveNow() {
    final d = _player.state.duration.inSeconds.toDouble();
    final t = _player.state.position.inSeconds.toDouble();
    if (d > 0 && t > 1) app.setProgress(widget.item, _ep, t, d);
  }

  @override
  void dispose() {
    _saveNow();
    app.progressRev.value++;
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.item.title;
    final sub = _ep != null ? '${_ep!.label} · ${_ep!.title}' : (widget.item.year ?? '');
    final next = _next;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.w600)),
                        if (sub.isNotEmpty)
                          Text(sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.list),
                    tooltip: 'Sources',
                    onPressed: _pickSource,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(controller: _video),
                  if (_msg != null || (_ended && next != null))
                    Container(
                      color: Colors.black54,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_ended && next != null) ...[
                            Text('Up next: ${next.title}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white)),
                            const SizedBox(height: 12),
                            FilledButton(
                                onPressed: _playNext, child: const Text('Play next episode')),
                          ] else if (_msg != null) ...[
                            Text(_msg!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white)),
                            if (_showPickInMsg) ...[
                              const SizedBox(height: 12),
                              OutlinedButton(
                                  onPressed: _pickSource, child: const Text('Choose source')),
                            ],
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
