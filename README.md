# Folio Audio v0.8

Self-hosted audiobook player: native Windows app (.exe) + native Android app (.apk), both Flutter,
syncing through a small Python server on your PC.

## Get the .exe and .apk
1. Create a GitHub repo and push this folder to it (branch `main`).
2. Open the **Actions** tab, run **Build Folio Audio** (it also runs on every push).
3. Download the artifacts: `FolioAudio-Windows` (zip containing `folio_audio.exe`) and `FolioAudio-Android` (`app-release.apk`).

(Or locally: install Flutter, then in `app/` run `flutter create --platforms=windows,android .`,
`python ../tools/patch_android.py`, then `flutter build windows` / `flutter build apk`.)

## Run
1. Windows: `pip install -r server/requirements.txt`, then `python server/server.py`. Note the **pairing key** it prints.
2. Open the Windows app → Connection → host `127.0.0.1`, paste the key.
3. Android (same Wi-Fi): Connection → your PC's IP (run `ipconfig`), same key. Allow port 8765 in Windows Firewall.

## What's included
Import multi-file books, edit title/author, **delete books** (new), search, "pick up where you left off",
separate cover/background art, offline downloads, speeds 0.8–2×, 10s/30s skip, chapters, sleep timer,
mini-player, responsive layout, background playback + notification controls on Android,
timestamp-based progress sync with an offline queue.

## Not done / known gaps
Not compiled or run by me: written without Flutter available, so expect a few compile fixes on first build.
Online cover search (Open Library/Google Books), M4B chapter extraction, folder scanning, Windows media keys, and an
in-app Android updater are not implemented yet.
