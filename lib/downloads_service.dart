import 'dart:convert';

import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.title,
    required this.fileName,
    required this.url,
    this.status = 'queued',
    this.downloaded = 0,
    this.total = -1,
    this.localUri,
    this.reason = 0,
  });

  final int id;
  final String title;
  final String fileName;
  final String url;
  final String status;
  final int downloaded;
  final int total;
  final String? localUri;
  final int reason;

  double get progress => total > 0 ? (downloaded / total).clamp(0, 1).toDouble() : 0;
  String get sizeLabel => total > 0 ? _bytes(total) : 'Size unknown';

  factory DownloadRecord.fromMap(Map m) => DownloadRecord(
    id: (m['id'] as num).toInt(),
    title: (m['title'] ?? '').toString(),
    fileName: (m['fileName'] ?? '').toString(),
    url: (m['url'] ?? '').toString(),
    status: (m['status'] ?? 'queued').toString(),
    downloaded: (m['downloaded'] as num?)?.toInt() ?? 0,
    total: (m['total'] as num?)?.toInt() ?? -1,
    localUri: m['localUri']?.toString(),
    reason: (m['reason'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'fileName': fileName, 'url': url,
  };
}

String _bytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();
  static const _channel = MethodChannel('app.stratus/downloads');
  static const _key = 'native_download_records';
  static const _locationKey = 'download_location';

  String downloadLocation = 'app_only';
  List<DownloadRecord> records = [];
  bool ready = false;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    downloadLocation = prefs.getString(_locationKey) == 'both' ? 'both' : 'app_only';
    notifyListeners();
  }

  Future<void> setDownloadLocation(String value) async {
    downloadLocation = value == 'both' ? 'both' : 'app_only';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_locationKey, downloadLocation);
    notifyListeners();
  }

  Future<void> refresh() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final saved = <Map<String, dynamic>>[];
    if (raw != null) {
      try {
        saved.addAll((jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)));
      } catch (_) {}
    }
    if (saved.isEmpty) {
      records = [];
      ready = true;
      notifyListeners();
      return;
    }
    try {
      final ids = saved.map((e) => (e['id'] as num).toInt()).where((id) => id > 0).toList();
      final live = ids.isEmpty ? <dynamic>[] : await _channel.invokeListMethod<dynamic>('queryAll', {'ids': ids}) ?? [];
      final byId = {for (final v in live.whereType<Map>()) (v['id'] as num).toInt(): v};
      records = saved.map((m) {
        final id = (m['id'] as num).toInt();
        final state = byId[id];
        return DownloadRecord.fromMap({...m, if (state != null) ...Map<String, dynamic>.from(state)});
      }).toList()
        ..sort((a, b) => b.id.compareTo(a.id));
    } catch (_) {
      records = saved.map(DownloadRecord.fromMap).toList()
        ..sort((a, b) => b.id.compareTo(a.id));
    }
    ready = true;
    notifyListeners();
  }

  Future<void> enqueue({
    required String url,
    required String title,
    required String fileName,
    Map<String, String> headers = const {},
  }) async {
    final id = await _channel.invokeMethod<int>('enqueue', {
      'url': url, 'title': title, 'fileName': fileName, 'headers': headers,
      'gallery': downloadLocation == 'both',
    });
    if (id == null) throw Exception('Android Download Manager did not return a task ID.');
    final entry = {'id': id, 'title': title, 'fileName': fileName, 'url': url};
    final prefs = await SharedPreferences.getInstance();
    final list = <Map<String, dynamic>>[];
    final raw = prefs.getString(_key);
    if (raw != null) {
      try { list.addAll((jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map))); } catch (_) {}
    }
    list.removeWhere((e) => e['id'] == id);
    list.add(entry);
    await prefs.setString(_key, jsonEncode(list));
    await refresh();
  }


  Future<void> saveMergedToGallery(String localPath, String fileName) async {
    await _channel.invokeMethod<bool>('saveMergedToGallery', {'path': localPath, 'fileName': fileName});
  }

  Future<void> addMergedFile({
    required String title,
    required String fileName,
    required String localPath,
  }) async {
    final file = File(localPath);
    if (!await file.exists() || await file.length() == 0) {
      throw Exception('Merged video file was not created.');
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = <Map<String, dynamic>>[];
    if (raw != null) {
      try { list.addAll((jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map))); } catch (_) {}
    }
    final id = -DateTime.now().microsecondsSinceEpoch;
    final size = await file.length();
    list.add({
      'id': id, 'title': title, 'fileName': fileName, 'url': '',
      'status': 'complete', 'downloaded': size, 'total': size,
      'localUri': file.uri.toString(), 'reason': 0,
    });
    await prefs.setString(_key, jsonEncode(list));
    await refresh();
  }

  Future<void> cancel(int id) async {
    if (id > 0) await _channel.invokeMethod<bool>('cancel', {'id': id});
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      final list = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();
      for (final entry in list) {
        if (entry['id'] == id) entry['status'] = 'cancelled';
      }
      await prefs.setString(_key, jsonEncode(list));
    }
    await refresh();
  }

  Future<void> open(int id) async {
    if (id > 0) await _channel.invokeMethod<bool>('open', {'id': id});
  }

  Future<void> forget(int id) async {
    if (id > 0) await _channel.invokeMethod<bool>('remove', {'id': id});
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = raw == null ? <Map<String, dynamic>>[] :
      (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    list.removeWhere((e) => e['id'] == id);
    await prefs.setString(_key, jsonEncode(list));
    await refresh();
  }
}
