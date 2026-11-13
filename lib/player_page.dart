import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';
import 'providers.dart';
import 'store.dart';
import 'widgets.dart';

const Color _kSeek = Color(0xFFE8335F);

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

  Episode? get _next {
    if (_ep == null) return null;
    final i = widget.list.indexWhere((e) => e.id == _ep!.id);
    return i >= 0 && i + 1 < widget.list.length ? widget.list[i + 1] : null;
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
      if (!mounted) return;
      if (p && _msg != null) setState(() => _msg = null);
      _kick();
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
    _subs.add(_player.stream.track.listen((_) {
      if (mounted) setState(() {});
    }));
    _setup();
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
    await _player.open(Media(s.url!, httpHeaders: s.headers));
    await _player.setRate(_rate);
  }

  void _pickSource() {
    if (_srcs.isEmpty || !mounted) return;
    _sheet('Sources', [
      for (final s in _srcs)
        ListTile(
          title: Text(s.name),
          subtitle: s.note != null ? Text(s.note!) : null,
          enabled: s.playable || s.link != null,
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

  /* ---- controls ---- */

  void _kick() {
    _hideTimer?.cancel();
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    if (_player.state.playing) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _player.state.playing) setState(() => _visible = false);
      });
    }
  }

  void _toggleUi() {
    if (_visible) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      _kick();
    }
  }

  void _skip(int seconds) {
    final p = _player.state.position + Duration(seconds: seconds);
    final d = _player.state.duration;
    _player.seek(p < Duration.zero ? Duration.zero : (p > d ? d : p));
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

  String _trackName(String id, String? title, String? language, String fallback) {
    if (id == 'auto') return 'Auto';
    if (id == 'no') return fallback;
    final t = (title ?? '').trim();
    if (t.isNotEmpty) return t;
    final l = (language ?? '').trim();
    return l.isNotEmpty ? l.toUpperCase() : 'Track $id';
  }

  String _short(String name) => name.length > 4 ? name.substring(0, 2).toUpperCase() : name;

  void _pickAudio() {
    final sel = _player.state.track.audio;
    final tracks = _player.state.tracks.audio;
    _sheet('Audio', [
      for (final t in tracks)
        ListTile(
          title: Text(_trackName(t.id, t.title, t.language, 'Off')),
          trailing: t.id == sel.id ? const Icon(Icons.check) : null,
          onTap: () {
            _player.setAudioTrack(t);
            Navigator.pop(context);
          },
        ),
    ]);
  }

  void _pickSubtitle() {
    final sel = _player.state.track.subtitle;
    final tracks = _player.state.tracks.subtitle;
    _sheet('Subtitles', [
      for (final t in tracks)
        ListTile(
          title: Text(_trackName(t.id, t.title, t.language, 'None')),
          trailing: t.id == sel.id ? const Icon(Icons.check) : null,
          onTap: () {
            _player.setSubtitleTrack(t);
            Navigator.pop(context);
          },
        ),
    ]);
  }

  void _pickSpeed() {
    _sheet('Playback speed', [
      for (final r in _rates)
        ListTile(
          title: Text('${r}x'),
          trailing: r == _rate ? const Icon(Icons.check) : null,
          onTap: () {
            _player.setRate(r);
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
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
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
          Video(controller: _video, fit: _fits[_fitI].$1, controls: NoVideoControls),
          GestureDetector(behavior: HitTestBehavior.opaque, onTap: _toggleUi),
          IgnorePointer(
            ignoring: !showUi,
            child: AnimatedOpacity(
              opacity: showUi ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: _controls(context, msgOn, next),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context, bool msgOn, Episode? next) {
    return ColoredBox(
      color: Colors.black54,
      child: SafeArea(
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
    final sub = _ep != null ? '${_ep!.label} · ${_ep!.title}' : (widget.item.year ?? '');
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
                Text(widget.item.title,
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
    final gap = MediaQuery.sizeOf(context).width * 0.13;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          color: Colors.white70,
          iconSize: 54,
          icon: const Icon(Icons.replay_10),
          tooltip: 'Back 10 seconds',
          onPressed: () => _skip(-10),
        ),
        SizedBox(width: gap),
        StreamBuilder<bool>(
          stream: _player.stream.buffering,
          initialData: _player.state.buffering,
          builder: (context, buf) {
            if (buf.data == true) {
              return const SizedBox(
                width: 68,
                height: 68,
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                ),
              );
            }
            return StreamBuilder<bool>(
              stream: _player.stream.playing,
              initialData: _player.state.playing,
              builder: (context, snap) {
                final playing = snap.data ?? false;
                return IconButton(
                  color: Colors.white,
                  iconSize: 68,
                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  tooltip: playing ? 'Pause' : 'Play',
                  onPressed: () => _player.playOrPause(),
                );
              },
            );
          },
        ),
        SizedBox(width: gap),
        IconButton(
          color: Colors.white70,
          iconSize: 54,
          icon: const Icon(Icons.forward_10),
          tooltip: 'Forward 10 seconds',
          onPressed: () => _skip(10),
        ),
      ],
    );
  }

  Widget _bottom() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        StreamBuilder<Duration>(
          stream: _player.stream.position,
          initialData: _player.state.position,
          builder: (context, snap) {
            final pos = snap.data ?? Duration.zero;
            final dur = _player.state.duration;
            return Row(
              children: [
                SizedBox(
                  width: 50,
                  child: Text(_fmt(pos),
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                ),
                Expanded(
                  child: _SeekBar(
                    position: pos,
                    duration: dur,
                    buffer: _player.state.buffer,
                    onSeek: (d) {
                      _player.seek(d);
                      _kick();
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(_fmt(dur),
                      textAlign: TextAlign.end,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            _opt(Icons.graphic_eq, _short(_trackName(_player.state.track.audio.id,
                _player.state.track.audio.title, _player.state.track.audio.language, 'Off')), _pickAudio),
            _opt(Icons.subtitles_outlined, _trackName(_player.state.track.subtitle.id,
                _player.state.track.subtitle.title, _player.state.track.subtitle.language, 'None'),
                _pickSubtitle),
            _opt(Icons.speed, _rate.toStringAsFixed(_rate == _rate.roundToDouble() ? 1 : 2), _pickSpeed),
            _opt(Icons.picture_in_picture_alt_outlined, 'PIP',
                () => toast(context, 'Picture-in-picture is coming soon')),
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
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
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
          if (_ended && next != null) ...[
            Text('Up next: ${next.title}',
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _playNext, child: const Text('Play next episode')),
          ] else if (_msg != null) ...[
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
