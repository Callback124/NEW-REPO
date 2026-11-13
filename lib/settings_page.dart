import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'downloads_service.dart';
import 'providers.dart';
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      showDragHandle: true,
                      builder: (_) => const AddProviderSheet(),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('Add provider'),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                    'A provider is a source of titles. Add a Stremio-compatible addon, a JSON catalog, or a repository that lists several providers.',
                    style: TextStyle(color: cs.onSurfaceVariant)),
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
              section('Playback'),
              SwitchListTile(
                title: const Text('Skip the source picker'),
                subtitle: const Text('Play the first working source straight away'),
                value: app.autoplay,
                onChanged: app.setAutoplay,
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
              section('Data'),
              ListTile(
                title: const Text('Copy backup'),
                subtitle: const Text('Providers, library and watch progress'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: app.exportJson()));
                  if (context.mounted) toast(context, 'Backup copied to the clipboard');
                },
              ),
              ListTile(
                title: const Text('Restore from clipboard'),
                onTap: () async {
                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                  try {
                    app.importJson(d?.text ?? '');
                    if (context.mounted) toast(context, 'Backup restored');
                  } catch (_) {
                    if (context.mounted) toast(context, 'The clipboard does not hold a Stratus backup');
                  }
                },
              ),
              ListTile(
                title: Text('Reset Stratus', style: TextStyle(color: cs.error)),
                subtitle: const Text('Clears everything stored on this device'),
                onTap: () => _confirmReset(context),
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

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Stratus?'),
        content: const Text('Providers, library and watch progress will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok == true) await app.reset();
  }
}

class AddProviderSheet extends StatefulWidget {
  const AddProviderSheet({super.key});

  @override
  State<AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends State<AddProviderSheet> {
  final _url = TextEditingController();
  final _json = TextEditingController();
  bool _busy = false;
  String? _ok;
  String? _err;
  String? _repoName;
  List<RepoEntry> _repo = const [];
  final Set<String> _installed = {};

  @override
  void dispose() {
    _url.dispose();
    _json.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _url.text.trim().isNotEmpty ? _url.text.trim() : _json.text.trim();
    if (text.isEmpty) {
      setState(() {
        _err = 'Paste a link or JSON first.';
        _ok = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
      _ok = null;
      _repo = const [];
    });
    try {
      final r = await detect(text);
      if (r.def == null) {
        setState(() {
          _repoName = r.repoName;
          _repo = r.repo;
          if (r.repo.isEmpty) _err = 'This repository has no providers.';
        });
      } else {
        app.addProvider(r.def!);
        setState(() => _ok = 'Added ${r.def!.name} (${r.info}).');
      }
    } catch (e) {
      setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install(RepoEntry e) async {
    try {
      final r = await detect(e.url);
      if (r.def == null) throw ProviderError('Nested repositories are not supported.');
      app.addProvider(r.def!);
      setState(() => _installed.add(e.url));
    } catch (err) {
      if (mounted) toast(context, err.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add a provider',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Paste a Stremio addon link, a JSON catalog link, or a repository link.',
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 14),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), hintText: 'https://example.com/manifest.json'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _json,
              minLines: 4,
              maxLines: 8,
              autocorrect: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), hintText: 'Or paste catalog JSON here'),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 10, children: [
              FilledButton(
                onPressed: _busy ? null : _add,
                child: Text(_busy ? 'Checking…' : 'Add'),
              ),
              OutlinedButton(
                onPressed: () => setState(() {
                  _url.clear();
                  _json.text = sampleCatalog;
                }),
                child: const Text('Insert example'),
              ),
            ]),
            if (_ok != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_ok!, style: TextStyle(color: cs.primary)),
              ),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_err!, style: TextStyle(color: cs.error)),
              ),
            if (_repo.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text('${_repoName ?? 'Repository'} lists ${_repo.length} providers.'),
              ),
              for (final e in _repo)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.name),
                  subtitle: Text(e.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: FilledButton.tonal(
                    onPressed: _installed.contains(e.url) ? null : () => _install(e),
                    child: Text(_installed.contains(e.url) ? 'Added' : 'Install'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
