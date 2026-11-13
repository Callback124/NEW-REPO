import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'downloads_service.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    DownloadService.instance.refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => DownloadService.instance.refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _playOffline(DownloadRecord record) async {
    final raw = record.localUri;
    if (raw == null || raw.isEmpty) {
      await DownloadService.instance.open(record.id);
      return;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'file') {
      await DownloadService.instance.open(record.id);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OfflineVideoPage(file: File(uri.toFilePath()), title: record.title),
    ));
  }

  String _status(DownloadRecord r) => switch (r.status) {
    'complete' => 'Completed',
    'running' => 'Downloading',
    'paused' => 'Paused',
    'failed' => 'Failed · code ${r.reason}',
    'cancelled' => 'Cancelled',
    _ => 'Queued',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadService.instance,
      builder: (context, _) {
        final records = DownloadService.instance.records;
        return CustomScrollView(slivers: [
          const SliverAppBar(floating: true, title: Text('Downloads')),
          if (records.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.download_for_offline_outlined, size: 54),
                SizedBox(height: 12),
                Text('No downloads yet'),
                SizedBox(height: 4),
                Text('Movies and episodes you download will appear here.'),
              ])),
            )
          else
            SliverList.builder(
              itemCount: records.length,
              itemBuilder: (context, index) {
                final r = records[index];
                final done = r.status == 'complete';
                final failed = r.status == 'failed' || r.status == 'cancelled';
                return ListTile(
                  leading: Icon(done ? Icons.check_circle_outline :
                    failed ? Icons.error_outline : Icons.downloading),
                  title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_status(r)),
                    if (!done && !failed) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: r.total > 0 ? r.progress : null),
                      const SizedBox(height: 3),
                      Text(r.total > 0 ? '${(r.progress * 100).toStringAsFixed(0)}% · ${r.sizeLabel}' : 'Waiting for file size…'),
                    ],
                    if (done) Text(r.sizeLabel),
                  ]),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'play') await _playOffline(r);\n                      if (v == 'open') await DownloadService.instance.open(r.id);
                      if (v == 'cancel') await DownloadService.instance.cancel(r.id);
                      if (v == 'remove') await DownloadService.instance.forget(r.id);
                    },
                    itemBuilder: (_) => [
                      if (done) const PopupMenuItem(value: 'play', child: Text('Play offline')),
                      if (done) const PopupMenuItem(value: 'open', child: Text('Open with another app')),
                      if (!done && !failed) const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                      const PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                  ),
                  onTap: done ? () => _playOffline(r) : null,
                );
              },
            ),
        ]);
      },
    );
  }
}


class OfflineVideoPage extends StatefulWidget {
  const OfflineVideoPage({super.key, required this.file, required this.title});
  final File file;
  final String title;

  @override
  State<OfflineVideoPage> createState() => _OfflineVideoPageState();
}

class _OfflineVideoPageState extends State<OfflineVideoPage> {
  late final VideoPlayerController _controller = VideoPlayerController.file(widget.file);
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      await _controller.setLooping(false);
      if (mounted) setState(() => _ready = true);
      await _controller.play();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not play this downloaded video: $e');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _time(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Center(
        child: _error != null
            ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
            : !_ready
                ? const CircularProgressIndicator()
                : ListenableBuilder(
                    listenable: _controller,
                    builder: (context, _) {
                      final value = _controller.value;
                      final duration = value.duration;
                      final position = value.position;
                      final max = duration.inMilliseconds.toDouble().clamp(1.0, double.infinity).toDouble();
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AspectRatio(
                            aspectRatio: value.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
                            child: VideoPlayer(_controller),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(children: [
                              Text(_time(position), style: Theme.of(context).textTheme.labelSmall),
                              Expanded(
                                child: Slider(
                                  value: position.inMilliseconds.toDouble().clamp(0.0, max).toDouble(),
                                  max: max,
                                  onChanged: (v) => _controller.seekTo(Duration(milliseconds: v.round())),
                                ),
                              ),
                              Text(_time(duration), style: Theme.of(context).textTheme.labelSmall),
                            ]),
                          ),
                          IconButton.filled(
                            onPressed: () => value.isPlaying ? _controller.pause() : _controller.play(),
                            icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                            iconSize: 30,
                          ),
                        ],
                      );
                    },
                  ),
      ),
    );
  }
}
