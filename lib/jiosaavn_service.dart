import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dart_des/dart_des.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

class SaavnSong {
  const SaavnSong({required this.id, required this.title, required this.artist, required this.album, required this.image, required this.duration, required this.encryptedUrl, this.lyricsId = '', this.albumId = ''});
  final String id, title, artist, album, image, encryptedUrl, lyricsId, albumId;
  final int duration;
  factory SaavnSong.fromJson(Map raw) {
    final more = raw['more_info'] is Map ? raw['more_info'] as Map : const {};
    final artists = more['artistMap'] is Map ? more['artistMap']['primary_artists'] : null;
    final artist = artists is List ? artists.map((e) => e is Map ? e['name'] : e).where((e) => e != null).join(', ') : (raw['primary_artists'] ?? raw['singers'] ?? raw['artist'] ?? '');
    var image = (raw['image'] ?? raw['album_image'] ?? '').toString().replaceAll('150x150', '500x500').replaceAll('50x50', '500x500').replaceAll('http://', 'https://');
    return SaavnSong(id: (raw['id'] ?? raw['songid'] ?? '').toString(), title: saavnClean(raw['title'] ?? raw['song'] ?? 'Unknown song'), artist: saavnClean(artist).isEmpty ? 'Unknown artist' : saavnClean(artist), album: saavnClean(raw['album'] ?? ''), image: image, duration: int.tryParse((raw['duration'] ?? 0).toString()) ?? 0, encryptedUrl: (raw['encrypted_media_url'] ?? '').toString(), lyricsId: (more['lyrics_id'] ?? raw['lyrics_id'] ?? '').toString(), albumId: (raw['albumid'] ?? more['album_id'] ?? '').toString());
  }
}
String saavnClean(dynamic value) {
  var s = value?.toString() ?? '';
  if (s == '{}' || s == '[]' || s == 'null') return '';
  return s.replaceAll('&quot;', '"').replaceAll('&amp;', '&').replaceAll('&#039;', "'").replaceAll('&#39;', "'").replaceAll('&nbsp;', ' ').replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
}
class SaavnSection {
  const SaavnSection(this.title, this.items);
  final String title;
  final List<Map<String, dynamic>> items;
}
class JioSaavnApi {
  static const _bases = ['https://www.jiosaavn.com/api.php', 'https://saavn.com/api.php', 'https://www.saavn.com/api.php'];
  static const _contexts = ['web6dot0', 'android', 'wap6dot0'];
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  final http.Client _client = http.Client();
  int _mirror = 0;
  Future<dynamic> call(String method, [Map<String, String> params = const {}]) async {
    Object? last;
    for (var i = 0; i < _bases.length; i++) {
      final index = (_mirror + i) % _bases.length;
      final query = <String, String>{'__call': method, 'api_version': '4', '_format': 'json', '_marker': '0', 'ctx': _contexts[index], ...params};
      try {
        final uri = Uri.parse(_bases[index]).replace(queryParameters: query);
        final response = await _client.get(uri, headers: {'User-Agent': _ua, 'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'en-US,en;q=0.9,hi;q=0.8', 'Cookie': 'L=hindi%2Cenglish; gdpr_acceptance=true; DL=english'}).timeout(const Duration(seconds: 18));
        if (response.statusCode != 200) throw Exception('HTTP ' + response.statusCode.toString());
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        _mirror = index;
        return decoded;
      } catch (e) { last = e; }
    }
    throw Exception('JioSaavn service unavailable: ' + last.toString());
  }
  Future<List<SaavnSong>> searchSongs(String q, {int page = 1}) async => _songList(await call('search.getResults', {'q': q, 'p': '$page', 'n': '50'}));
  Future<List<Map<String, dynamic>>> searchMedia(String kind, String q) async {
    final method = switch (kind) {'albums' => 'search.getAlbumResults', 'playlists' => 'search.getPlaylistResults', _ => 'search.getArtistResults'};
    final data = await call(method, {'q': q, 'p': '1', 'n': '40'});
    final rows = data is Map ? (data['results'] ?? data['data']) : data;
    return rows is List ? rows.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
  }
  Future<List<SaavnSection>> home() async {
    final data = await call('webapi.getLaunchData');
    final root = data is Map ? data : <String, dynamic>{};
    final sections = <SaavnSection>[];
    void add(String title, dynamic raw) {
      if (raw is List) { final rows = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(); if (rows.isNotEmpty) sections.add(SaavnSection(title, rows)); }
    }
    add('Trending Now', root['new_trending']); add('Editorial Picks', root['top_playlists']); add('New Trending Albums', root['new_albums']); add('Top Charts', root['charts']); add('Genres & Moods', root['browse_discover']);
    for (final key in ['promo:vx:data:68','promo:vx:data:112','promo:vx:data:107','promo:vx:data:185','promo:vx:data:211']) {
      add(key.contains('68') ? 'Free Hits' : (key.contains('112') || key.contains('107') ? 'Devotional / Bhakti' : 'Best of 90s'), root[key]);
    }
    return sections;
  }
  Future<List<SaavnSong>> albumSongs(String id, {bool playlist = false}) async => _songList(await call(playlist ? 'playlist.getDetails' : 'content.getAlbumDetails', {(playlist ? 'listid' : 'albumid'): id, 'cc': 'in'}));
  Future<Map<String, dynamic>> songDetails(String id) async {
    final data = await call('song.getDetails', {'pids': id, 'cc': 'in'});
    if (data is Map) { final value = data[id]; if (value is Map) return Map<String, dynamic>.from(value); if (data['songs'] is List && (data['songs'] as List).isNotEmpty) return Map<String, dynamic>.from(data['songs'][0] as Map); }
    throw Exception('Song details not found');
  }
  Future<String> lyrics(SaavnSong song) async {
    var lyricsId = song.lyricsId;
    if (lyricsId.isEmpty) { final details = await songDetails(song.id); final more = details['more_info']; lyricsId = (more is Map ? more['lyrics_id'] : null)?.toString() ?? ''; }
    if (lyricsId.isNotEmpty) { try { final data = await call('lyrics.getLyrics', {'lyrics_id': lyricsId}); if (data is Map && data['lyrics'] != null) return saavnClean(data['lyrics']); } catch (_) {} }
    for (final uri in [Uri.https('saavn.dev', '/api/songs/' + song.id + '/lyrics'), Uri.https('lrclib.net', '/api/get', {'track_name': song.title, 'artist_name': song.artist})]) {
      try { final r = await _client.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 12)); if (r.statusCode != 200) continue; final d = jsonDecode(utf8.decode(r.bodyBytes)); if (d is Map) { final value = d['lyrics'] ?? (d['data'] is Map ? d['data']['lyrics'] : null) ?? d['plainLyrics'] ?? d['syncedLyrics']; if (value != null && value.toString().isNotEmpty) return value.toString(); } } catch (_) {}
    }
    throw Exception('Lyrics not available');
  }
  List<SaavnSong> _songList(dynamic data) {
    dynamic rows = data;
    if (data is Map) rows = data['songs'] ?? data['results'] ?? data['list'] ?? data['data'];
    if (rows is Map) rows = rows['songs'] ?? rows['results'] ?? [];
    if (rows is! List) return [];
    return rows.whereType<Map>().map((e) => SaavnSong.fromJson(e)).where((s) => s.id.isNotEmpty).toList();
  }
  void dispose() => _client.close();
}
class JioSaavnPlayer {
  JioSaavnPlayer._() { audio.playerStateStream.listen((state) { if (state.processingState == ProcessingState.completed) next(); }); }
  static final instance = JioSaavnPlayer._();
  final AudioPlayer audio = AudioPlayer();
  final JioSaavnApi api = JioSaavnApi();
  final List<SaavnSong> queue = [];
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  int index = -1;
  String bitrate = '320';
  SaavnSong? get current => index >= 0 && index < queue.length ? queue[index] : null;
  Future<void> playList(List<SaavnSong> songs, {int start = 0}) async {
    if (songs.isEmpty) return;
    queue..clear()..addAll(songs); index = start.clamp(0, queue.length - 1).toInt(); revision.value++; await playCurrent();
  }
  Future<String> _resolve(SaavnSong song, String quality) async {
    var encrypted = song.encryptedUrl;
    if (encrypted.isEmpty) { final d = await api.songDetails(song.id); encrypted = (d['encrypted_media_url'] ?? '').toString(); }
    if (encrypted.isEmpty) throw Exception('Audio URL not available');
    final decrypted = DES(key: '38346591'.codeUnits, mode: DESMode.ECB).decrypt(base64.decode(encrypted.trim()));
    final padding = decrypted.isEmpty ? 0 : decrypted.last;
    final plainBytes = padding > 0 && padding <= 8 && padding <= decrypted.length ? decrypted.sublist(0, decrypted.length - padding) : decrypted;
    var url = utf8.decode(plainBytes).trim();
    url = url.replaceAll(RegExp(r'_\d+\.(mp4|m4a)'), '_$quality.mp4').replaceFirst('http://', 'https://');
    return url;
  }
  Future<void> playCurrent() async {
    final song = current; if (song == null) return;
    try {
      final url = await _resolve(song, bitrate);
      await audio.setUrl(url, headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36'});
      await audio.play();
    } catch (e) {
      if (bitrate == '320') { bitrate = '160'; final url = await _resolve(song, bitrate); await audio.setUrl(url); await audio.play(); } else { rethrow; }
    }
  }
  Future<void> next() async { if (queue.isEmpty) return; index = (index + 1) % queue.length; revision.value++; await playCurrent(); }
  Future<void> previous() async { if (queue.isEmpty) return; if (audio.position > const Duration(seconds: 3)) { await audio.seek(Duration.zero); return; } index = (index - 1 + queue.length) % queue.length; revision.value++; await playCurrent(); }
  Future<void> setQuality(String value) async {
    bitrate = value; if (current != null) { final wasPlaying = audio.playing; final pos = audio.position; await audio.pause(); final url = await _resolve(current!, value); await audio.setUrl(url); await audio.seek(pos); if (wasPlaying) await audio.play(); }
  }
}