"""Folio Audio sync server (FastAPI + SQLite). Run: python server.py"""
import os, sqlite3, time, uuid, secrets, shutil
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, UploadFile, File, Form, Header, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel

DATA = Path(os.environ.get("FOLIO_DATA", Path.home() / "FolioAudioData"))
AUDIO, ART = DATA / "audio", DATA / "art"
for d in (AUDIO, ART):
    d.mkdir(parents=True, exist_ok=True)
KEY_FILE = DATA / "pairing.key"
if not KEY_FILE.exists():
    KEY_FILE.write_text(secrets.token_urlsafe(12))
KEY = KEY_FILE.read_text().strip()
AUDIO_EXT = {".mp3", ".m4a", ".m4b", ".aac", ".flac", ".ogg", ".opus", ".wav", ".wma"}
IMG_EXT = {".jpg", ".jpeg", ".png", ".webp"}

db = sqlite3.connect(DATA / "folio.db", check_same_thread=False)
db.row_factory = sqlite3.Row
db.executescript("""
CREATE TABLE IF NOT EXISTS books(id TEXT PRIMARY KEY, title TEXT, author TEXT,
  cover TEXT, background TEXT, art_version INTEGER DEFAULT 0, updated REAL, deleted INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS chapters(id TEXT PRIMARY KEY, book_id TEXT, idx INTEGER,
  title TEXT, file TEXT, size INTEGER);
CREATE TABLE IF NOT EXISTS progress(book_id TEXT PRIMARY KEY, chapter_id TEXT,
  position_ms INTEGER, event_ts REAL, device TEXT);
""")
app = FastAPI(title="Folio Audio")


def auth(k: Optional[str]):
    if k != KEY:
        raise HTTPException(401, "Bad pairing key")


def book_json(r):
    chs = db.execute("SELECT id,idx,title,size FROM chapters WHERE book_id=? ORDER BY idx", (r["id"],)).fetchall()
    p = db.execute("SELECT * FROM progress WHERE book_id=?", (r["id"],)).fetchone()
    return {"id": r["id"], "title": r["title"], "author": r["author"],
            "hasCover": bool(r["cover"]), "hasBackground": bool(r["background"]),
            "artVersion": r["art_version"], "updated": r["updated"],
            "chapters": [dict(c) for c in chs],
            "progress": dict(p) if p else None}


@app.get("/api/ping")
def ping(x_key: Optional[str] = Header(None)):
    auth(x_key)
    return {"ok": True, "version": "0.8.0"}


@app.get("/api/books")
def books(x_key: Optional[str] = Header(None)):
    auth(x_key)
    rows = db.execute("SELECT * FROM books WHERE deleted=0 ORDER BY title COLLATE NOCASE").fetchall()
    return [book_json(r) for r in rows]


@app.post("/api/books")
async def upload(title: str = Form(...), author: str = Form(""),
                 files: list[UploadFile] = File(...), x_key: Optional[str] = Header(None)):
    auth(x_key)
    bid = uuid.uuid4().hex
    files = sorted(files, key=lambda f: (f.filename or "").lower())
    n = 0
    for f in files:
        ext = Path(f.filename or "").suffix.lower()
        if ext not in AUDIO_EXT:
            continue
        cid = uuid.uuid4().hex
        dest = AUDIO / f"{cid}{ext}"
        with open(dest, "wb") as out:
            shutil.copyfileobj(f.file, out, 1024 * 1024)
        db.execute("INSERT INTO chapters VALUES(?,?,?,?,?,?)",
                   (cid, bid, n, Path(f.filename).stem, dest.name, dest.stat().st_size))
        n += 1
    if n == 0:
        raise HTTPException(400, "No supported audio files")
    db.execute("INSERT INTO books(id,title,author,updated) VALUES(?,?,?,?)", (bid, title, author, time.time()))
    db.commit()
    return {"id": bid}


class Meta(BaseModel):
    title: Optional[str] = None
    author: Optional[str] = None


@app.patch("/api/books/{bid}")
def edit(bid: str, m: Meta, x_key: Optional[str] = Header(None)):
    auth(x_key)
    if m.title is not None:
        db.execute("UPDATE books SET title=? WHERE id=?", (m.title, bid))
    if m.author is not None:
        db.execute("UPDATE books SET author=? WHERE id=?", (m.author, bid))
    db.execute("UPDATE books SET updated=? WHERE id=?", (time.time(), bid))
    db.commit()
    return {"ok": True}


@app.delete("/api/books/{bid}")
def delete(bid: str, x_key: Optional[str] = Header(None)):
    auth(x_key)
    for c in db.execute("SELECT file FROM chapters WHERE book_id=?", (bid,)).fetchall():
        (AUDIO / c["file"]).unlink(missing_ok=True)
    db.execute("DELETE FROM chapters WHERE book_id=?", (bid,))
    db.execute("UPDATE books SET deleted=1, updated=? WHERE id=?", (time.time(), bid))
    db.commit()
    return {"ok": True}


@app.get("/api/chapters/{cid}/audio")
def audio(cid: str, key: Optional[str] = None, x_key: Optional[str] = Header(None)):
    auth(x_key or key)  # FileResponse supports HTTP range requests (seeking)
    r = db.execute("SELECT file FROM chapters WHERE id=?", (cid,)).fetchone()
    if not r:
        raise HTTPException(404)
    return FileResponse(AUDIO / r["file"])


@app.post("/api/books/{bid}/art/{kind}")
async def set_art(bid: str, kind: str, file: UploadFile = File(...), x_key: Optional[str] = Header(None)):
    auth(x_key)
    if kind not in ("cover", "background"):
        raise HTTPException(400)
    ext = Path(file.filename or "").suffix.lower()
    if ext not in IMG_EXT:
        raise HTTPException(400, "JPG, PNG or WebP only")
    data = await file.read()
    if len(data) > 10 * 1024 * 1024:
        raise HTTPException(413, "Max 10 MB")
    name = f"{bid}_{kind}_{int(time.time())}{ext}"
    (ART / name).write_bytes(data)
    db.execute(f"UPDATE books SET {kind}=?, art_version=art_version+1, updated=? WHERE id=?",
               (name, time.time(), bid))
    db.commit()
    return {"ok": True}


@app.get("/api/books/{bid}/art/{kind}")
def get_art(bid: str, kind: str, key: Optional[str] = None, x_key: Optional[str] = Header(None)):
    auth(x_key or key)
    r = db.execute("SELECT cover,background FROM books WHERE id=?", (bid,)).fetchone()
    if not r or kind not in ("cover", "background") or not r[kind]:
        raise HTTPException(404)
    return FileResponse(ART / r[kind])


class Prog(BaseModel):
    chapter_id: str
    position_ms: int
    event_ts: float  # client wall-clock seconds of the listening event
    device: str = ""


@app.put("/api/progress/{bid}")
def put_progress(bid: str, p: Prog, x_key: Optional[str] = Header(None)):
    """Last-writer-wins by listening-event timestamp, not arrival order."""
    auth(x_key)
    cur = db.execute("SELECT event_ts FROM progress WHERE book_id=?", (bid,)).fetchone()
    if cur is None or p.event_ts > cur["event_ts"]:
        db.execute("INSERT OR REPLACE INTO progress VALUES(?,?,?,?,?)",
                   (bid, p.chapter_id, p.position_ms, p.event_ts, p.device))
        db.commit()
        return {"applied": True}
    return {"applied": False}


if __name__ == "__main__":
    print(f"\nFolio Audio server\n  Pairing key: {KEY}\n  Data folder: {DATA}\n")
    uvicorn.run(app, host="0.0.0.0", port=8765)
