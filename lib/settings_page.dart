import 'package:flutter/material.dart';
import 'models.dart';
import 'downloads_service.dart';
import 'store.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        Widget section(String t) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(t.toUpperCase(),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: cs.onSurfaceVariant)),
            );
        return CustomScrollView(
          slivers: [
            const SliverAppBar(floating: true, title: Text('Settings')),
            SliverList.list(children: [
              section('Providers'),
              for (final p in app.providers)
                ListTile(
                  title: Text(p.name),
                  subtitle: Text(
                      '${p.kindLabel}${p.url != null ? ' · ${Uri.tryParse(p.url!)?.host ?? ''}' : ''}${p.data != null ? ' · pasted JSON' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (!p.builtin)
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmRemove(context, p),
                      ),
                    Switch(value: p.enabled, onChanged: (v) => app.toggleProvider(p.id, v)),
                  ]),
                ),
              section('Downloads'),
              ListenableBuilder(
                listenable: DownloadService.instance,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Save downloaded videos'),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'app_only', label: Text('App only')),
                            ButtonSegment(value: 'both', label: Text('App + Gallery')),
                          ],
                          selected: {DownloadService.instance.downloadLocation},
                          onSelectionChanged: (s) => DownloadService.instance.setDownloadLocation(s.first),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        DownloadService.instance.downloadLocation == 'both'
                            ? 'Downloads will appear in Stratus and your phone gallery.'
                            : 'Downloads stay inside Stratus and are hidden from gallery apps.',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              section('Appearance'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('System')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ],
                  selected: {app.theme},
                  onSelectionChanged: (s) => app.setTheme(s.first),
                ),
              ),
              const SizedBox(height: 32),
            ]),
          ],
        );
      },
    );
  }

  Future<void> _confirmRemove(BuildContext context, ProviderDef p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) app.removeProvider(p.id);
  }

}
