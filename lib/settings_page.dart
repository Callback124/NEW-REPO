import 'package:flutter/material.dart';
import 'downloads_service.dart';
import 'store.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final cardColor = dark ? const Color(0xFF191C24) : Colors.white;
        Widget heading(String title, String subtitle, IconData icon) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
          child: Row(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(color: cs.primary.withValues(alpha: .12), borderRadius: BorderRadius.circular(13)),
              child: Icon(icon, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w750)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ])),
          ]),
        );
        return CustomScrollView(slivers: [
          const SliverAppBar(pinned: true, title: Text('Settings', style: TextStyle(fontWeight: FontWeight.w800))),
          SliverToBoxAdapter(child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [cs.primary, cs.primary.withValues(alpha: .72)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(children: [
                Container(width: 48, height: 48, decoration: BoxDecoration(color: Colors.white.withValues(alpha: .18), borderRadius: BorderRadius.circular(15)), child: const Icon(Icons.movie_creation_outlined, color: Colors.white, size: 28)),
                const SizedBox(width: 14),
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('MovieFox', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                  SizedBox(height: 3),
                  Text('Personalize your streaming experience', style: TextStyle(color: Colors.white70, fontSize: 12)),
                ])),
              ]),
            ),
          )),
          SliverToBoxAdapter(child: heading('Downloads', 'Choose where your downloads are saved', Icons.download_rounded)),
          SliverToBoxAdapter(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              color: cardColor, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              child: Padding(padding: const EdgeInsets.all(16), child: ListenableBuilder(
                listenable: DownloadService.instance,
                builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Save downloaded videos', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  SizedBox(width: double.infinity, child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'app_only', icon: Icon(Icons.phone_android), label: Text('App only')),
                      ButtonSegment(value: 'both', icon: Icon(Icons.photo_library_outlined), label: Text('App + Gallery')),
                    ],
                    selected: {DownloadService.instance.downloadLocation},
                    onSelectionChanged: (s) => DownloadService.instance.setDownloadLocation(s.first),
                  )),
                  const SizedBox(height: 10),
                  Text(
                    DownloadService.instance.downloadLocation == 'both'
                      ? 'Downloads will be available in MovieFox and your phone gallery.'
                      : 'Downloads stay inside MovieFox and are not shown in gallery apps.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                ]),
              )),
            ),
          )),
          SliverToBoxAdapter(child: heading('Appearance', 'Choose how MovieFox looks on your device', Icons.palette_outlined)),
          SliverToBoxAdapter(child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            child: Card(
              color: cardColor, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('App theme', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                SizedBox(width: double.infinity, child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto), label: Text('System')),
                    ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
                    ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
                  ],
                  selected: {app.theme},
                  onSelectionChanged: (s) => app.setTheme(s.first),
                )),
              ])),
            ),
          )),
        ]);
      },
    );
  }
}
