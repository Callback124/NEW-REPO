import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'downloads_service.dart';
import 'models.dart';
import 'player_page.dart';
import 'music_page.dart';
import 'jiosaavn_service.dart';

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
    if (record.isMusic && raw != null && raw.isNotEmpty) {
      final song = SaavnSong(id: record.songId.isEmpty ? record.id.toString() : record.songId, title: record.title, artist: record.artist, album: '', image: record.image, duration: record.duration, encryptedUrl: '');
      try {
        await JioSaavnPlayer.instance.playOffline(song, raw);
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SaavnFullPlayer()));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Offline music could not be played: $e')));
      }
      return;
    }
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
    final item = Item(pid: 'offline', id: record.fileName, title: record.title);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(item: item, localFile: File(uri.toFilePath())),
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
                Text('Your downloaded movies, episodes and music will appear here.'),
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
                    Text(r.phase.isNotEmpty ? r.phase : _status(r)),
                    if (!done && !failed) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: r.total > 0 ? r.progress : null),
                      const SizedBox(height: 3),
                      Text(r.id < 0 ? '${r.downloaded}/${r.total} episodes · ${(r.progress * 100).toStringAsFixed(0)}%' : (r.total > 0 ? '${(r.progress * 100).toStringAsFixed(0)}% · ${r.sizeLabel}' : 'Waiting for file size…')),
                    ],
                    if (done) Text(r.sizeLabel),
                  ]),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'play') await _playOffline(r);
                      if (v == 'open') await DownloadService.instance.open(r.id);
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
