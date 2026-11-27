import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'api.dart';

class PlayerController extends ChangeNotifier {
  final Api api;
  final AudioPlayer player = AudioPlayer();
  Book? book;
  double speed = 1.0;
  Timer? _sleep;
  int? sleepMinutes;
  Timer? _sync, _poll;

  PlayerController(this.api) {
    player.currentIndexStream.listen((_) => notifyListeners());
    player.playerStateStream.listen((_) => notifyListeners());
    // Save every 10 s while playing; save immediately on pause.
    _sync = Timer.periodic(const Duration(seconds: 10), (_) {
      if (player.playing) _save();
    });
    player.playingStream.listen((p) {
      if (!p) _save();
    });
    // Check for newer position from another device every 2 s.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _checkRemote());
  }

  int get chapterIndex => player.currentIndex ?? 0;

  Future<void> open(Book b, {bool autoplay = true}) async {
    book = b;
    final sources = [
      for (final c in b.chapters)
        AudioSource.uri(api.chapterUri(c),
            tag: MediaItem(
                id: c.id, title: c.title, album: b.title, artist: b.author,
                artUri: b.hasCover ? Uri.parse(api.artUrl(b, 'cover')) : null))
    ];
    var idx = b.chapters.indexWhere((c) => c.id == b.progChapter);
    if (idx < 0) idx = 0;
    await player.setAudioSource(ConcatenatingAudioSource(children: sources),
        initialIndex: idx, initialPosition: Duration(milliseconds: b.progMs));
    await player.setSpeed(speed);
    if (autoplay) player.play();
    notifyListeners();
  }

  Future<void> _save() async {
    final b = book;
    if (b == null || b.chapters.isEmpty) return;
    await api.saveProgress(
        b, b.chapters[chapterIndex].id, player.position.inMilliseconds);
  }

  Future<void> seek(Duration d) async {
    await player.seek(d);
    _save();
  }

  Future<void> skip(int seconds) async {
    final target = player.position + Duration(seconds: seconds);
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> toChapter(int i) async {
    if (i < 0 || i >= (book?.chapters.length ?? 0)) return;
    await player.seek(Duration.zero, index: i);
    _save();
  }

  Future<void> setSpeed(double s) async {
    speed = s;
    await player.setSpeed(s);
    notifyListeners();
  }

  void setSleep(int? minutes) {
    _sleep?.cancel();
    sleepMinutes = minutes;
    if (minutes != null) {
      _sleep = Timer(Duration(minutes: minutes), () {
        player.pause();
        sleepMinutes = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// If the server holds a newer event for the open book from another device, jump to it.
  Future<void> _checkRemote() async {
    final b = book;
    if (b == null || !api.online) return;
    final before = b.progTs;
    await api.refresh();
    final fresh = api.books.where((x) => x.id == b.id);
    if (fresh.isEmpty) return;
    final f = fresh.first;
    if (f.progTs > before + 1 && f.progChapter != null) {
      final i = b.chapters.indexWhere((c) => c.id == f.progChapter);
      if (i >= 0 && (i != chapterIndex ||
          (player.position.inMilliseconds - f.progMs).abs() > 3000)) {
        b.progTs = f.progTs;
        await player.seek(Duration(milliseconds: f.progMs), index: i);
      }
    }
  }

  @override
  void dispose() {
    _sync?.cancel();
    _poll?.cancel();
    _sleep?.cancel();
    player.dispose();
    super.dispose();
  }
}
