import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'api.dart';
import 'player.dart';

late Api api;
late PlayerController pc;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    JustAudioMediaKit.ensureInitialized();
  } else if (Platform.isAndroid) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.folio.audio.playback',
      androidNotificationChannelName: 'Folio Audio',
      androidNotificationOngoing: true,
    );
  }
  api = Api();
  await api.init();
  pc = PlayerController(api);
  runApp(const FolioApp());
}

class FolioApp extends StatelessWidget {
  const FolioApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Folio Audio',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xFFF59E0B)),
        home: const Shell(),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 800;
    final pages = const [LibraryPage(downloadsOnly: false),
      LibraryPage(downloadsOnly: true), ConnectionPage()];
    final dests = const [
      (Icons.library_books, 'Library'),
      (Icons.download_done, 'Downloads'),
      (Icons.wifi, 'Connection')
    ];
    return Scaffold(
      body: Row(children: [
        if (wide)
          NavigationRail(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              labelType: NavigationRailLabelType.all,
              destinations: [for (final d in dests)
                NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2))]),
        Expanded(child: Column(children: [
          Expanded(child: pages[tab]),
          const MiniPlayer(),
        ])),
      ]),
      bottomNavigationBar: wide ? null : NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: [for (final d in dests)
            NavigationDestination(icon: Icon(d.$1), label: d.$2)]),
    );
  }
}

class LibraryPage extends StatefulWidget {
  final bool downloadsOnly;
  const LibraryPage({super.key, required this.downloadsOnly});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String q = '';

  Future<void> _import() async {
    final r = await FilePicker.platform.pickFiles(
        allowMultiple: true, type: FileType.custom,
        allowedExtensions: ['mp3','m4a','m4b','aac','flac','ogg','opus','wav','wma']);
    if (r == null || r.files.isEmpty) return;
    final first = r.files.first.name;
    final guess = first.replaceAll(RegExp(r'\.[^.]+$'), '');
    if (!mounted) return;
    final title = TextEditingController(text: guess);
    final author = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Import audiobook'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
        TextField(controller: author, decoration: const InputDecoration(labelText: 'Author')),
        const SizedBox(height: 8),
        Text('${r.files.length} file(s) → chapters sorted by filename'),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Upload')),
      ],
    ));
    if (ok == true) {
      await api.upload(title.text, author.text,
          r.files.where((f) => f.path != null).map((f) => f.path!).toList());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: api,
        builder: (context, _) {
          var list = api.books.where((b) =>
              (!widget.downloadsOnly || api.isDownloaded(b)) &&
              (b.title + b.author).toLowerCase().contains(q.toLowerCase())).toList();
          final recent = api.books.where((b) => b.progTs > 0).toList()
            ..sort((a, b) => b.progTs.compareTo(a.progTs));
          return Scaffold(
            appBar: AppBar(
              title: Text(widget.downloadsOnly ? 'Downloads' : 'Library'),
              actions: [
                if (!api.online) const Padding(padding: EdgeInsets.all(8),
                    child: Chip(label: Text('Offline'))),
                IconButton(onPressed: api.refresh, icon: const Icon(Icons.refresh)),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    onChanged: (v) => setState(() => q = v),
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
                        hintText: 'Search title or author', isDense: true,
                        border: OutlineInputBorder())))),
            ),
            floatingActionButton: widget.downloadsOnly ? null : FloatingActionButton.extended(
                onPressed: api.online ? _import : null,
                icon: const Icon(Icons.add), label: const Text('Import')),
            body: Column(children: [
              if (!widget.downloadsOnly && recent.isNotEmpty && q.isEmpty)
                Card(margin: const EdgeInsets.all(12), child: ListTile(
                  leading: Cover(recent.first, 48),
                  title: const Text('Pick up where you left off'),
                  subtitle: Text(recent.first.title),
                  trailing: const Icon(Icons.play_arrow),
                  onTap: () => openBook(context, recent.first),
                )),
              Expanded(child: list.isEmpty
                  ? const Center(child: Text('No audiobooks here yet'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 180, childAspectRatio: 0.62,
                          crossAxisSpacing: 12, mainAxisSpacing: 12),
                      itemCount: list.length,
                      itemBuilder: (_, i) => BookTile(list[i]))),
            ]),
          );
        },
      );
}

Future<void> openBook(BuildContext context, Book b) async {
  if (pc.book?.id != b.id) await pc.open(b, autoplay: false);
  if (context.mounted) {
    Navigator.push(context, PageRouteBuilder(
        pageBuilder: (_, __, ___) => PlayerPage(b),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child)));
  }
}

class Cover extends StatelessWidget {
  final Book b;
  final double size;
  const Cover(this.b, this.size, {super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
      width: size, height: size,
      child: b.hasCover
          ? Image.network(api.artUrl(b, 'cover'), fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(Icons.menu_book))
          : const Icon(Icons.menu_book));
}

class BookTile extends StatelessWidget {
  final Book b;
  const BookTile(this.b, {super.key});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => openBook(context, b),
        onLongPress: () => bookMenu(context, b),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Center(child: b.hasCover
              ? Image.network(api.artUrl(b, 'cover'), fit: BoxFit.contain)
              : const Icon(Icons.menu_book, size: 64))),
          const SizedBox(height: 6),
          Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(b.author, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          if (api.isDownloaded(b))
            const Icon(Icons.download_done, size: 14),
        ]),
      );
}

void bookMenu(BuildContext context, Book b) {
  showModalBottomSheet(context: context, builder: (c) => SafeArea(child: Column(
    mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.edit), title: const Text('Edit title & author'),
          onTap: () { Navigator.pop(c); editDialog(context, b); }),
      ListTile(leading: const Icon(Icons.image), title: const Text('Set book cover'),
          onTap: () async { Navigator.pop(c); await pickArt(b, 'cover'); }),
      ListTile(leading: const Icon(Icons.wallpaper), title: const Text('Set player background'),
          onTap: () async { Navigator.pop(c); await pickArt(b, 'background'); }),
      if (api.isDownloaded(b))
        ListTile(leading: const Icon(Icons.delete_sweep), title: const Text('Remove download'),
            onTap: () { Navigator.pop(c); api.removeDownload(b); })
      else
        ListTile(leading: const Icon(Icons.download), title: const Text('Download for offline'),
            onTap: () {
              Navigator.pop(c);
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Downloading ${b.title}…')));
              api.download(b, (_) {});
            }),
      ListTile(leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
          title: const Text('Delete audiobook'),
          onTap: () async {
            Navigator.pop(c);
            final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
              title: Text('Delete "${b.title}"?'),
              content: const Text('This removes it from the server and all devices.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
              ]));
            if (ok == true) api.deleteBook(b);
          }),
    ])));
}

Future<void> pickArt(Book b, String kind) async {
  final r = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp']);
  if (r?.files.single.path != null) await api.uploadArt(b, kind, r!.files.single.path!);
}

Future<void> editDialog(BuildContext context, Book b) async {
  final t = TextEditingController(text: b.title);
  final a = TextEditingController(text: b.author);
  final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
    title: const Text('Edit audiobook'),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: t, decoration: const InputDecoration(labelText: 'Title')),
      TextField(controller: a, decoration: const InputDecoration(labelText: 'Author')),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
    ]));
  if (ok == true) await api.editMeta(b, title: t.text, author: a.text);
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: pc,
        builder: (context, _) {
          final b = pc.book;
          if (b == null) return const SizedBox.shrink();
          return Material(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: ListTile(
              leading: Cover(b, 40),
              title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(b.chapters.isEmpty ? '' : b.chapters[pc.chapterIndex].title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                  icon: Icon(pc.player.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: () => pc.player.playing ? pc.player.pause() : pc.player.play()),
              onTap: () => openBook(context, b),
            ),
          );
        },
      );
}

String fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

class PlayerPage extends StatefulWidget {
  final Book b;
  const PlayerPage(this.b, {super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  double? drag;
  @override
  Widget build(BuildContext context) {
    final b = widget.b;
    return Scaffold(
      body: Stack(children: [
        if (b.hasBackground)
          Positioned.fill(child: Image.network(api.artUrl(b, 'background'), fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox())),
        Positioned.fill(child: Container(color: Colors.black.withOpacity(b.hasBackground ? 0.65 : 0.0))),
        SafeArea(child: ListenableBuilder(listenable: pc, builder: (context, _) => Column(children: [
          Align(alignment: Alignment.centerLeft, child: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down), onPressed: () => Navigator.pop(context))),
          // scrollable: artwork + chapters
          Expanded(child: ListView(padding: const EdgeInsets.symmetric(horizontal: 24), children: [
            Center(child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 300),
                child: b.hasCover ? Image.network(api.artUrl(b, 'cover'), fit: BoxFit.contain)
                    : const Icon(Icons.menu_book, size: 160))),
            const SizedBox(height: 16),
            Text(b.title, textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall),
            Text(b.author, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            for (var i = 0; i < b.chapters.length; i++)
              ListTile(
                dense: true,
                selected: i == pc.chapterIndex,
                leading: Icon(i == pc.chapterIndex ? Icons.graphic_eq : Icons.music_note),
                title: Text(b.chapters[i].title),
                onTap: () { pc.toChapter(i); pc.player.play(); },
              ),
          ])),
          // fixed controls
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Column(children: [
            StreamBuilder<Duration>(
              stream: pc.player.positionStream,
              builder: (_, snap) {
                final pos = snap.data ?? Duration.zero;
                final dur = pc.player.duration ?? Duration.zero;
                final v = (drag ?? pos.inMilliseconds.toDouble())
                    .clamp(0, dur.inMilliseconds.toDouble().clamp(1, double.infinity));
                return Column(children: [
                  Slider(
                    value: v.toDouble(),
                    max: dur.inMilliseconds.toDouble().clamp(1, double.infinity),
                    onChanged: (x) => setState(() => drag = x),
                    onChangeEnd: (x) async {
                      await pc.seek(Duration(milliseconds: x.round()));
                      setState(() => drag = null);
                    }),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(fmt(Duration(milliseconds: v.round()))),
                    Text('-${fmt(dur - Duration(milliseconds: v.round()))}'),
                  ]),
                ]);
              }),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(iconSize: 32, icon: const Icon(Icons.skip_previous),
                  onPressed: () => pc.toChapter(pc.chapterIndex - 1)),
              IconButton(iconSize: 36, icon: const Icon(Icons.replay_10), onPressed: () => pc.skip(-10)),
              IconButton.filled(iconSize: 48,
                  icon: Icon(pc.player.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: () => pc.player.playing ? pc.player.pause() : pc.player.play()),
              IconButton(iconSize: 36, icon: const Icon(Icons.forward_30), onPressed: () => pc.skip(30)),
              IconButton(iconSize: 32, icon: const Icon(Icons.skip_next),
                  onPressed: () => pc.toChapter(pc.chapterIndex + 1)),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              PopupMenuButton<double>(
                  initialValue: pc.speed, onSelected: pc.setSpeed,
                  child: Chip(label: Text('${pc.speed}×')),
                  itemBuilder: (_) => [for (final s in [0.8, 1.0, 1.25, 1.5, 1.75, 2.0])
                    PopupMenuItem(value: s, child: Text('$s×'))]),
              const SizedBox(width: 12),
              PopupMenuButton<int>(
                  onSelected: (m) => pc.setSleep(m == 0 ? null : m),
                  child: Chip(avatar: const Icon(Icons.bedtime, size: 16),
                      label: Text(pc.sleepMinutes == null ? 'Sleep off' : '${pc.sleepMinutes} min')),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 0, child: Text('Off')),
                    PopupMenuItem(value: 15, child: Text('15 minutes')),
                    PopupMenuItem(value: 30, child: Text('30 minutes')),
                    PopupMenuItem(value: 60, child: Text('60 minutes')),
                  ]),
            ]),
          ])),
        ]))),
      ]),
    );
  }
}

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});
  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  late final host = TextEditingController(text: api.host);
  late final key = TextEditingController(text: api.key);
  String status = '';
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Connection')),
        body: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
          const Text('Enter your PC\'s local IP address and the pairing key shown '
              'in the server window.'),
          TextField(controller: host, decoration: const InputDecoration(labelText: 'Server IP (e.g. 192.168.1.20)')),
          TextField(controller: key, decoration: const InputDecoration(labelText: 'Pairing key')),
          const SizedBox(height: 16),
          FilledButton(onPressed: () async {
            setState(() => status = 'Connecting…');
            final ok = await api.connect(host.text, key.text);
            setState(() => status = ok ? 'Connected ✓' : 'Could not reach server');
          }, child: const Text('Connect')),
          const SizedBox(height: 12),
          Text(status),
        ])),
      );
}
