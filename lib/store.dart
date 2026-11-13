import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// App-wide state. Persisted in SharedPreferences.
class AppState extends ChangeNotifier {
  late SharedPreferences _sp;

  List<ProviderDef> providers = [];
  List<Item> library = [];
  Map<String, Progress> progress = {};
  String active = 'all';
  ThemeMode theme = ThemeMode.dark;
  bool autoplay = false;

  /// Bumped when watch progress changes, so only the "Continue watching" row rebuilds.
  final ValueNotifier<int> progressRev = ValueNotifier<int>(0);

  Future<void> init() async {
    _sp = await SharedPreferences.getInstance();
    providers = _readList('providers').map(ProviderDef.fromJson).toList();
    // Remove the retired Internet Archive provider and migrate to MovieBox.
    providers = providers.where((p) => p.id != 'archive' && p.kind != 'archive').toList();
    if (!providers.any((p) => p.id == 'moviebox')) {
      providers.insert(0, ProviderDef.moviebox());
      _saveProviders();
    }
    library = _readList('library').map(Item.fromJson).toList();
    progress = {};
    final raw = _sp.getString('progress');
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          progress[k] = Progress.fromJson(Map<String, dynamic>.from(v as Map));
        });
      } catch (_) {}
    }
    active = _sp.getString('active') ?? 'all';
    try {
      theme = ThemeMode.values.byName(_sp.getString('theme') ?? 'dark');
    } catch (_) {
      theme = ThemeMode.dark;
    }
    autoplay = _sp.getBool('autoplay') ?? false;
  }

  List<Map<String, dynamic>> _readList(String key) {
    final s = _sp.getString(key);
    if (s == null) return [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  void _saveProviders() => _sp.setString(
      'providers', jsonEncode(providers.map((p) => p.toJson()).toList()));
  void _saveLibrary() =>
      _sp.setString('library', jsonEncode(library.map((i) => i.toJson()).toList()));
  void _saveProgress() => _sp.setString(
      'progress', jsonEncode(progress.map((k, v) => MapEntry(k, v.toJson()))));

  /* ---- providers ---- */
  List<ProviderDef> get enabled => providers.where((p) => p.enabled).toList();

  List<ProviderDef> scope() {
    final e = enabled;
    if (active != 'all' && !e.any((p) => p.id == active)) active = 'all';
    return active == 'all' ? e : e.where((p) => p.id == active).toList();
  }

  String get scopeName {
    if (active == 'all') return 'All providers';
    for (final p in providers) {
      if (p.id == active) return p.name;
    }
    return 'All providers';
  }

  ProviderDef? providerById(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  void setActive(String id) {
    active = id;
    _sp.setString('active', id);
    notifyListeners();
  }

  void toggleProvider(String id, bool on) {
    providers = [for (final p in providers) p.id == id ? p.copyWith(enabled: on) : p];
    _saveProviders();
    notifyListeners();
  }

  void removeProvider(String id) {
    providers = providers.where((p) => p.id != id).toList();
    if (active == id) active = 'all';
    _saveProviders();
    notifyListeners();
  }

  void addProvider(ProviderDef def) {
    if (def.url != null && providers.any((p) => p.url == def.url)) {
      throw ProviderError('That provider is already added.');
    }
    providers = [...providers, def];
    _saveProviders();
    notifyListeners();
  }

  /* ---- library ---- */
  bool inLibrary(Item it) => library.any((x) => x.key == it.key);

  void toggleLibrary(Item it) {
    if (inLibrary(it)) {
      library = library.where((x) => x.key != it.key).toList();
    } else {
      library = [it, ...library];
    }
    _saveLibrary();
    notifyListeners();
  }

  /* ---- progress ---- */
  void setProgress(Item it, Episode? ep, double t, double d) {
    progress[progressKey(it, ep)] = Progress(
      t: t,
      d: d,
      ts: DateTime.now().millisecondsSinceEpoch,
      item: it,
      ep: ep,
    );
    if (progress.length > 80) {
      final keys = progress.keys.toList()
        ..sort((a, b) => progress[a]!.ts.compareTo(progress[b]!.ts));
      for (final k in keys.take(progress.length - 80)) {
        progress.remove(k);
      }
    }
    _saveProgress();
  }

  List<MapEntry<String, Progress>> get resumables {
    final l = progress.entries
        .where((e) => e.value.d > 0 && e.value.frac > .02 && e.value.frac < .95)
        .toList()
      ..sort((a, b) => b.value.ts.compareTo(a.value.ts));
    return l.take(15).toList();
  }

  /* ---- settings ---- */
  void setTheme(ThemeMode m) {
    theme = m;
    _sp.setString('theme', m.name);
    notifyListeners();
  }

  void setAutoplay(bool v) {
    autoplay = v;
    _sp.setBool('autoplay', v);
    notifyListeners();
  }

  String exportJson() => jsonEncode({
        'v': 1,
        'providers': providers.map((p) => p.toJson()).toList(),
        'library': library.map((i) => i.toJson()).toList(),
        'progress': progress.map((k, v) => MapEntry(k, v.toJson())),
      });

  void importJson(String text) {
    final d = jsonDecode(text) as Map<String, dynamic>;
    for (final p in (d['providers'] as List? ?? [])) {
      final def = ProviderDef.fromJson(Map<String, dynamic>.from(p as Map));
      if (providerById(def.id) == null) providers = [...providers, def];
    }
    for (final i in (d['library'] as List? ?? [])) {
      final it = Item.fromJson(Map<String, dynamic>.from(i as Map));
      if (!inLibrary(it)) library = [...library, it];
    }
    (d['progress'] as Map? ?? {}).forEach((k, v) {
      progress[k.toString()] = Progress.fromJson(Map<String, dynamic>.from(v as Map));
    });
    _saveProviders();
    _saveLibrary();
    _saveProgress();
    notifyListeners();
  }

  Future<void> reset() async {
    await _sp.clear();
    await init();
    notifyListeners();
  }
}

final AppState app = AppState();
