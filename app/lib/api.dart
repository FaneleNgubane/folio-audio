import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Chapter {
  final String id, title;
  final int index, size;
  Chapter(this.id, this.title, this.index, this.size);
  factory Chapter.fromJson(Map j) =>
      Chapter(j['id'], j['title'] ?? '', j['idx'] ?? 0, j['size'] ?? 0);
}

class Book {
  String id, title, author;
  bool hasCover, hasBackground;
  int artVersion;
  List<Chapter> chapters;
  String? progChapter;
  int progMs;
  double progTs;
  Book(this.id, this.title, this.author, this.hasCover, this.hasBackground,
      this.artVersion, this.chapters, this.progChapter, this.progMs, this.progTs);
  factory Book.fromJson(Map j) {
    final p = j['progress'];
    return Book(
        j['id'], j['title'] ?? '', j['author'] ?? '', j['hasCover'] ?? false,
        j['hasBackground'] ?? false, j['artVersion'] ?? 0,
        (j['chapters'] as List).map((c) => Chapter.fromJson(c)).toList(),
        p?['chapter_id'], p?['position_ms'] ?? 0, (p?['event_ts'] ?? 0).toDouble());
  }
}

/// Talks to the PC server, caches the library, downloads books, queues progress.
class Api extends ChangeNotifier {
  String host = '', key = '';
  bool online = false;
  List<Book> books = [];
  Set<String> downloaded = {};
  List<Map<String, dynamic>> _pending = [];
  late SharedPreferences _p;
  late Directory _dir;
  final device = Platform.isAndroid ? 'android' : 'windows';

  String get base => 'http://$host:8765';
  Map<String, String> get _h => {'X-Key': key};
  bool get configured => host.isNotEmpty && key.isNotEmpty;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    _dir = await getApplicationSupportDirectory();
    host = _p.getString('host') ?? (Platform.isWindows ? '127.0.0.1' : '');
    key = _p.getString('key') ?? '';
    downloaded = (_p.getStringList('downloaded') ?? []).toSet();
    _pending = (_p.getStringList('pending') ?? [])
        .map((s) => jsonDecode(s) as Map<String, dynamic>).toList();
    final cached = _p.getString('library');
    if (cached != null) {
      books = (jsonDecode(cached) as List).map((b) => Book.fromJson(b)).toList();
    }
    notifyListeners();
    if (configured) refresh();
  }

  Future<bool> connect(String h, String k) async {
    host = h.trim();
    key = k.trim();
    await _p.setString('host', host);
    await _p.setString('key', key);
    await refresh();
    return online;
  }

  Future<void> refresh() async {
    try {
      final r = await http.get(Uri.parse('$base/api/books'), headers: _h)
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) throw 'status';
      await _p.setString('library', r.body);
      books = (jsonDecode(r.body) as List).map((b) => Book.fromJson(b)).toList();
      online = true;
      await flushPending();
    } catch (_) {
      online = false;
    }
    notifyListeners();
  }

  Future<void> upload(String title, String author, List<String> paths) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/api/books'))
      ..headers.addAll(_h)
      ..fields['title'] = title
      ..fields['author'] = author;
    for (final p in paths) {
      req.files.add(await http.MultipartFile.fromPath('files', p));
    }
    await req.send();
    await refresh();
  }

  Future<void> editMeta(Book b, {String? title, String? author}) async {
    await http.patch(Uri.parse('$base/api/books/${b.id}'),
        headers: {..._h, 'Content-Type': 'application/json'},
        body: jsonEncode({'title': title, 'author': author}));
    await refresh();
  }

  Future<void> deleteBook(Book b) async {
    await http.delete(Uri.parse('$base/api/books/${b.id}'), headers: _h);
    await removeDownload(b);
    await refresh();
  }

  Future<void> uploadArt(Book b, String kind, String path) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/api/books/${b.id}/art/$kind'))
      ..headers.addAll(_h)
      ..files.add(await http.MultipartFile.fromPath('file', path));
    await req.send();
    await refresh();
  }

  String artUrl(Book b, String kind) =>
      '$base/api/books/${b.id}/art/$kind?key=$key&v=${b.artVersion}';

  // ---- offline downloads ----
  File chapterFile(Chapter c) => File('${_dir.path}/dl_${c.id}');
  bool isDownloaded(Book b) => downloaded.contains(b.id);

  Future<void> download(Book b, void Function(double) onProgress) async {
    var done = 0;
    for (final c in b.chapters) {
      final f = chapterFile(c);
      if (!await f.exists()) {
        final res = await http.Client().send(http.Request(
            'GET', Uri.parse('$base/api/chapters/${c.id}/audio'))
          ..headers.addAll(_h));
        final sink = f.openWrite();
        await res.stream.pipe(sink);
      }
      onProgress(++done / b.chapters.length);
    }
    downloaded.add(b.id);
    await _p.setStringList('downloaded', downloaded.toList());
    notifyListeners();
  }

  Future<void> removeDownload(Book b) async {
    for (final c in b.chapters) {
      final f = chapterFile(c);
      if (await f.exists()) await f.delete();
    }
    downloaded.remove(b.id);
    await _p.setStringList('downloaded', downloaded.toList());
    notifyListeners();
  }

  /// Local file if downloaded, otherwise stream URL.
  Uri chapterUri(Chapter c) => chapterFile(c).existsSync()
      ? Uri.file(chapterFile(c).path)
      : Uri.parse('$base/api/chapters/${c.id}/audio?key=$key');

  // ---- progress sync (offline queue, timestamp-based conflict resolution) ----
  Future<void> saveProgress(Book b, String chapterId, int ms) async {
    final ts = DateTime.now().millisecondsSinceEpoch / 1000.0;
    b.progChapter = chapterId;
    b.progMs = ms;
    b.progTs = ts;
    _pending.removeWhere((e) => e['book'] == b.id);
    _pending.add({'book': b.id, 'chapter_id': chapterId, 'position_ms': ms,
      'event_ts': ts, 'device': device});
    await _p.setStringList('pending', _pending.map(jsonEncode).toList());
    flushPending();
  }

  Future<void> flushPending() async {
    for (final e in List.of(_pending)) {
      try {
        await http.put(Uri.parse('$base/api/progress/${e['book']}'),
            headers: {..._h, 'Content-Type': 'application/json'},
            body: jsonEncode({'chapter_id': e['chapter_id'],
              'position_ms': e['position_ms'], 'event_ts': e['event_ts'],
              'device': e['device']})).timeout(const Duration(seconds: 4));
        _pending.remove(e);
      } catch (_) {
        online = false;
        break;
      }
    }
    await _p.setStringList('pending', _pending.map(jsonEncode).toList());
  }
}
