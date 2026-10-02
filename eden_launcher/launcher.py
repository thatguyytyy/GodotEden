import hashlib, os, re, subprocess, sys, time
from pathlib import Path

import requests
from PySide6.QtCore import QPropertyAnimation, QRectF, QThread, QUrl, Qt, Signal
from PySide6.QtGui import (QColor, QDesktopServices, QFont, QIcon, QImage, QLinearGradient, QPainter,
                           QPainterPath, QPen, QPixmap, QTextCharFormat, QTextCursor, QTextDocument)
from PySide6.QtWidgets import (QApplication, QGraphicsOpacityEffect, QLabel, QMenu, QProgressBar,
                               QPushButton, QTextBrowser, QWidget)

SERVER_URL = "https://YOUR-TUNNEL.example.com"  # build_launcher.py bakes in config.json's tunnel_url (on a copy)
GAME_EXE = "GodotEden.exe" if sys.platform == "win32" else "GodotEden"
# Game lives in ./game next to the launcher so the launcher exe is never overwritten/locked.
BASE = Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve().parent
GAME_DIR = BASE / "game"
RES = Path(getattr(sys, "_MEIPASS", Path(__file__).parent)) / "assets"
W, H = 1000, 640
LAUNCHER_VERSION = "1.1"  # shown bottom-right so you can tell which launcher a tester has; bump when you ship one
UA = {"User-Agent": "EdenLauncher/1.0"}  # the server only serves requests that carry this

STYLE = """
QLabel { color:#c9d4e3; }
QPushButton#win { background:transparent; color:#aab6c8; font-size:20px; border:none; border-radius:4px; }
QPushButton#win::menu-indicator { image:none; }
QPushButton#win:hover { background:rgba(255,255,255,40); color:white; }
QWidget#card { background:rgba(11,15,23,225); border:1px solid rgba(255,255,255,28); border-radius:6px; }
QPushButton#details { background:rgba(255,255,255,12); color:#e6edf7; border:1px solid #8793a6; font-weight:bold; letter-spacing:2px; }
QPushButton#details:hover { background:rgba(255,255,255,35); }
QPushButton#play { color:white; font-size:22px; font-weight:bold; border:1px solid #a9c0ea; border-radius:3px;
    background:qlineargradient(x1:0,y1:0,x2:0,y2:1,stop:0 #6d93d6,stop:1 #3c62a2); }
QPushButton#play:hover { background:qlineargradient(x1:0,y1:0,x2:0,y2:1,stop:0 #82a6e6,stop:1 #4a73b8); }
QPushButton#play:disabled { background:rgba(60,70,90,200); color:#8b98a9; border-color:#4a5568; }
QProgressBar { background:rgba(8,12,20,215); border:1px solid #8a7a4a; border-radius:4px; color:white; font-weight:bold; padding-left:10px; }
QProgressBar::chunk { border-radius:3px; background:qlineargradient(x1:0,y1:0,x2:1,y2:0,stop:0 #2b78bd,stop:1 #4fd3da); }
QTextBrowser { background:transparent; border:none; color:#d5deea; font-size:14px; selection-background-color:#27456f; }
QScrollBar:vertical { background:transparent; width:8px; margin:2px; }
QScrollBar::handle:vertical { background:rgba(255,255,255,60); border-radius:3px; min-height:30px; }
QScrollBar::handle:vertical:hover { background:rgba(255,255,255,110); }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height:0; }
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background:transparent; }
QMenu { background:#0f1520; color:#dbe4f0; border:1px solid #2a3547; padding:4px; }
QMenu::item { padding:6px 22px; } QMenu::item:selected { background:#27456f; }
"""


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def fmt(b: float) -> str:
    return f"{b/1e9:.2f} GB" if b >= 1e9 else f"{b/1e6:.1f} MB"


def parse_news(md: str):
    """news.md -> [(title, body)]; each '## ' heading is one card."""
    items, cur = [], None
    for line in md.splitlines():
        if line.startswith("## "):
            cur = (line[3:].strip(), [])
            items.append(cur)
        elif cur:
            cur[1].append(line)
    return [(t, "\n".join(b).strip()) for t, b in items]


IMG_RE = re.compile(r"!\[[^\]]*\]\(([^)\s]+)[^)]*\)")  # ![alt](path)


def blur(pix: QPixmap, passes: int = 3) -> QPixmap:
    """Cheap blur: repeated halve-then-restore with smooth scaling (no extra deps)."""
    small = pix
    for _ in range(passes):
        small = small.scaled(max(small.width() // 2, 1), max(small.height() // 2, 1),
                             Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
    return small.scaled(pix.size(), Qt.IgnoreAspectRatio, Qt.SmoothTransformation)


class ImageFetcher(QThread):
    """Downloads the images a news entry references (relative paths come from the server)."""
    fetched = Signal(dict)  # {markdown path: bytes}

    def __init__(self, paths):
        super().__init__()
        self.paths = paths

    def run(self):
        out = {}
        for p in self.paths:
            url = p if p.startswith("http") else f"{SERVER_URL}/{p.lstrip('/')}"
            try:
                r = requests.get(url, headers=UA, timeout=10)
                if r.ok:
                    out[p] = r.content
            except requests.RequestException:
                pass
        self.fetched.emit(out)


class ResView(QTextBrowser):
    """QTextBrowser that serves already-downloaded images (it can't fetch http itself)."""
    def __init__(self, parent):
        super().__init__(parent)
        self.images = {}
        self.setOpenExternalLinks(True)

    def set_md(self, md):
        """setMarkdown + restyle: Qt ignores CSS for Markdown, so links/spacing are patched on the document."""
        self.setMarkdown(md)
        doc = self.document()
        cur = QTextCursor(doc)
        cur.beginEditBlock()
        block = doc.begin()
        while block.isValid():
            c = QTextCursor(block)
            bf = c.blockFormat(); bf.setTopMargin(6); bf.setBottomMargin(6); c.setBlockFormat(bf)
            it = block.begin()
            while not it.atEnd():
                frag = it.fragment()
                if frag.charFormat().isAnchor():
                    c = QTextCursor(doc)
                    c.setPosition(frag.position()); c.setPosition(frag.position() + frag.length(), QTextCursor.KeepAnchor)
                    fmt = QTextCharFormat(); fmt.setForeground(QColor("#6fcfff")); c.mergeCharFormat(fmt)
                it += 1
            block = block.next()
        cur.endEditBlock()

    def loadResource(self, rtype, url):
        if rtype == QTextDocument.ImageResource and url.toString() in self.images:
            return self.images[url.toString()]
        return super().loadResource(rtype, url)


class Viewer(QWidget):
    """Full-window overlay: blurred, tinted copy of the launcher with a glass panel holding the markdown."""
    PANEL = QRectF(70, 60, W - 140, H - 120)

    def __init__(self, parent, title, body):
        super().__init__(parent)
        self.setGeometry(0, 0, W, H)
        self.setFocusPolicy(Qt.StrongFocus)
        self.shot = blur(parent.grab())  # grabbed before this widget is visible, so it isn't in the picture
        self.md = f"## {title}\n\n{body}"
        pr = self.PANEL.toRect()
        self.view = ResView(self)
        self.view.setGeometry(pr.x() + 28, pr.y() + 26, pr.width() - 56, pr.height() - 52)
        self.view.set_md(self.md)
        close = QPushButton("✕", self); close.setObjectName("win")
        close.setGeometry(pr.right() - 40, pr.y() + 8, 32, 30); close.clicked.connect(self.close_viewer)
        self.fetch = None
        paths = list(dict.fromkeys(IMG_RE.findall(body)))
        if paths:
            self.fetch = ImageFetcher(paths)
            self.fetch.fetched.connect(self.on_images)
            self.fetch.start()
        self.eff = QGraphicsOpacityEffect(self); self.setGraphicsEffect(self.eff)
        self.anim = QPropertyAnimation(self.eff, b"opacity", self)
        self.anim.setDuration(180); self.anim.setStartValue(0.0); self.anim.setEndValue(1.0)
        self.show(); self.raise_(); self.setFocus(); self.anim.start()

    def on_images(self, data):
        maxw = self.view.viewport().width() - 24
        for name, raw in data.items():
            img = QImage.fromData(raw)
            if not img.isNull():
                self.view.images[name] = img.scaledToWidth(maxw, Qt.SmoothTransformation) if img.width() > maxw else img
        scroll = self.view.verticalScrollBar().value()
        self.view.set_md(self.md)  # re-layout now that the images exist
        self.view.verticalScrollBar().setValue(scroll)

    def close_viewer(self):
        if self.fetch:
            self.fetch.wait()  # never drop a running QThread
        self.deleteLater()

    def keyPressEvent(self, e):
        if e.key() == Qt.Key_Escape:
            self.close_viewer()

    def mousePressEvent(self, e):
        if not self.PANEL.contains(e.position()):
            self.close_viewer()  # click outside the glass panel closes it

    def paintEvent(self, _):
        p = QPainter(self); p.setRenderHints(QPainter.Antialiasing | QPainter.SmoothPixmapTransform)
        clip = QPainterPath(); clip.addRoundedRect(QRectF(0.5, 0.5, W - 1, H - 1), 14, 14); p.setClipPath(clip)
        p.drawPixmap(0, 0, self.shot)
        p.fillRect(self.rect(), QColor(5, 8, 14, 150))  # dim everything behind the panel
        panel = QPainterPath(); panel.addRoundedRect(self.PANEL, 12, 12)
        p.fillPath(panel, QColor(16, 22, 34, 175))      # semi-transparent glass
        p.setPen(QPen(QColor(255, 255, 255, 55), 1)); p.drawPath(panel)


class Worker(QThread):
    """mode 'check': fetch manifest+news, find stale files. mode 'update': download them."""
    status = Signal(str)
    speed = Signal(str)          # "x MB remaining · y MB/s"
    progress = Signal(int, int)  # done bytes, total bytes
    news = Signal(str)
    version = Signal(str)
    checked = Signal(list)       # [(rel, size, sha256)] stale files
    launcher_ready = Signal(str)  # path of a verified new launcher exe, to swap in
    failed = Signal(str)
    done = Signal()

    def __init__(self, mode, pending=None):
        super().__init__()
        self.mode, self.pending = mode, pending or []

    def run(self):
        try:
            self._check() if self.mode == "check" else self._update()
        except Exception as e:
            self.failed.emit(str(e))

    def _check(self):
        self.status.emit("Contacting server...")
        try:
            r = requests.get(f"{SERVER_URL}/news.md", params={"t": time.time()}, headers=UA, timeout=15)
            self.news.emit(r.content.decode("utf-8-sig"))  # -sig: tolerate a BOM
        except requests.RequestException:
            self.news.emit("")
        r = requests.get(f"{SERVER_URL}/manifest.json", params={"t": time.time()}, headers=UA, timeout=15)  # t= defeats edge caching
        r.raise_for_status()
        manifest = r.json()
        self.version.emit(str(manifest.get("version", "")))
        lp = manifest.get("launcher")  # published launcher exe: {sha256, size}; the hash IS the version
        if lp and getattr(sys, "frozen", False) and sha256(Path(sys.executable)) != lp["sha256"]:
            return self._self_update(lp)
        files = manifest["files"]
        stale = []
        for i, (rel, info) in enumerate(files.items(), 1):
            self.status.emit(f"Verifying files {i}/{len(files)}...")
            p = GAME_DIR / rel
            if not p.is_file() or p.stat().st_size != info["size"] or sha256(p) != info["sha256"]:
                stale.append((rel, info["size"], info["sha256"]))
        self.checked.emit(stale)

    def _fetch(self, rel, dest, digest, on_chunk=None):
        """Download SERVER_URL/rel to dest, verifying the SHA-256 before it replaces anything."""
        dest.parent.mkdir(parents=True, exist_ok=True)
        part = dest.with_name(dest.name + ".part")
        h = hashlib.sha256()
        with requests.get(f"{SERVER_URL}/{rel}", headers=UA, stream=True, timeout=30) as r:
            r.raise_for_status()
            with part.open("wb") as f:
                for chunk in r.iter_content(1 << 20):
                    f.write(chunk); h.update(chunk)
                    if on_chunk:
                        on_chunk(len(chunk))
        if h.hexdigest() != digest:
            part.unlink()
            raise RuntimeError(f"Hash mismatch for {rel}")
        os.replace(part, dest)  # atomic; fails loudly if the game is still running

    def _self_update(self, info):
        self.status.emit("Updating launcher...")
        exe = Path(sys.executable)
        new = exe.with_name(exe.name + ".new")
        self._fetch("launcher/EdenLauncher.exe", new, info["sha256"])
        self.launcher_ready.emit(str(new))

    def _update(self):
        total, t0, done = sum(s for _, s, _ in self.pending), time.time(), [0]

        def tick(n):
            done[0] += n
            self.progress.emit(done[0], total)
            rate = done[0] / max(time.time() - t0, 0.001)
            self.speed.emit(f"{fmt(total - done[0])} remaining · {rate/1e6:.2f} MB/s")

        for rel, _, digest in self.pending:
            self._fetch(rel, GAME_DIR / rel, digest, tick)
        if sys.platform != "win32":
            (GAME_DIR / GAME_EXE).chmod(0o755)
        self.done.emit()


class Launcher(QWidget):
    LABELS = {"check": "...", "update": "UPDATE", "play": "PLAY", "retry": "RETRY"}

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Eden_Project Launcher")
        self.setWindowFlags(Qt.FramelessWindowHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setFixedSize(W, H)
        self.setStyleSheet(STYLE)
        self.bg = QPixmap(str(RES / "bg.jpg"))
        self.news, self.news_i, self.pending, self.state = [], 0, [], "check"

        def label(text, x, y, w, h, size, color, bold=False, spacing=0):
            l = QLabel(text, self)
            f = QFont("Segoe UI", size); f.setBold(bold); f.setLetterSpacing(QFont.AbsoluteSpacing, spacing)
            l.setFont(f); l.setStyleSheet(f"color:{color};"); l.setGeometry(x, y, w, h)
            return l

        # window controls + settings gear
        self.gear = QPushButton("⚙", self); self.gear.setObjectName("win"); self.gear.setGeometry(18, 14, 34, 34)
        menu = QMenu(self)
        menu.addAction("Verify files", lambda: self.btn.isEnabled() and self.start("check"))
        menu.addAction("Open game folder", self.open_folder)
        self.gear.setMenu(menu)
        for text, x, slot in (("—", W - 82, self.showMinimized), ("✕", W - 46, self.close)):
            b = QPushButton(text, self); b.setObjectName("win"); b.setGeometry(x, 12, 32, 30); b.clicked.connect(slot)

        # logo (text; swap for an image when there is one)
        label("EDEN", 52, 60, 420, 80, 50, "#eaf4ff", True, 12)
        label("PROJECT", 56, 138, 300, 26, 15, "#6fcfff", True, 14)

        # news card + dots
        self.card = QWidget(self); self.card.setObjectName("card"); self.card.setGeometry(52, 196, 520, 192)
        self.card_title = QLabel(self.card); self.card_title.setGeometry(22, 14, 476, 30)
        self.card_title.setFont(QFont("Segoe UI", 15, QFont.Bold)); self.card_title.setStyleSheet("color:#f2f6fb;")
        self.card_body = QLabel(self.card); self.card_body.setGeometry(22, 52, 476, 90)
        self.card_body.setWordWrap(True); self.card_body.setTextFormat(Qt.MarkdownText)
        self.card_body.setAlignment(Qt.AlignTop | Qt.AlignLeft); self.card_body.setStyleSheet("color:#b4c0d0;font-size:13px;")
        self.details = QPushButton("DETAILS", self.card); self.details.setObjectName("details")
        self.details.setGeometry(150, 150, 220, 30); self.details.clicked.connect(self.show_details)
        self.dots = []

        # play button, version, status
        self.btn = QPushButton("...", self); self.btn.setObjectName("play"); self.btn.setGeometry(52, 462, 240, 58)
        self.btn.setEnabled(False); self.btn.clicked.connect(self.on_click)
        label(f"Launcher {LAUNCHER_VERSION}", W - 230, 552, 190, 18, 9, "#5d6a7c").setAlignment(Qt.AlignRight)
        self.ver = label("", 54, 528, 400, 20, 10, "#8b98a9")
        self.stat = label("", 54, 550, 520, 20, 10, "#8b98a9")

        # download bar (only while updating)
        self.bar = QProgressBar(self); self.bar.setGeometry(36, 590, W - 72, 32)
        self.bar.setAlignment(Qt.AlignLeft | Qt.AlignVCenter); self.bar.hide()
        self.set_news("")
        self.start("check")

    # ---- window chrome -------------------------------------------------
    def paintEvent(self, _):
        p = QPainter(self); p.setRenderHints(QPainter.Antialiasing | QPainter.SmoothPixmapTransform)
        clip = QPainterPath(); clip.addRoundedRect(QRectF(0.5, 0.5, W - 1, H - 1), 14, 14); p.setClipPath(clip)
        p.fillRect(self.rect(), QColor("#0a0e16"))
        if not self.bg.isNull():
            p.drawPixmap(0, -(self.bg.height() - H) // 2, self.bg)
        g = QLinearGradient(0, 0, W, 0)  # darken the left so text reads; planet stays visible on the right
        g.setColorAt(0, QColor(7, 10, 17, 238)); g.setColorAt(0.55, QColor(7, 10, 17, 120)); g.setColorAt(1, QColor(7, 10, 17, 0))
        p.fillRect(self.rect(), g)
        v = QLinearGradient(0, H * 0.7, 0, H)
        v.setColorAt(0, QColor(7, 10, 17, 0)); v.setColorAt(1, QColor(7, 10, 17, 200))
        p.fillRect(self.rect(), v)
        p.setClipping(False); p.setPen(QPen(QColor(255, 255, 255, 45), 1)); p.drawPath(clip)

    def mousePressEvent(self, e):
        if e.button() == Qt.LeftButton and e.position().y() < 64:
            self.windowHandle().startSystemMove()

    # ---- news ----------------------------------------------------------
    def set_news(self, md):
        self.news, self.news_i = parse_news(md), 0
        for d in self.dots:
            d.deleteLater()
        self.dots = []
        for i in range(len(self.news)):
            d = QPushButton(self); d.setGeometry(52 + i * 34, 402, 28, 6); d.setCursor(Qt.PointingHandCursor)
            d.clicked.connect(lambda _=False, i=i: self.show_news(i)); d.show(); self.dots.append(d)
        self.show_news(0)

    def show_news(self, i):
        self.news_i = i
        title, body = self.news[i] if self.news else ("Eden_Project", "No patch notes yet.")
        self.card_title.setText(title.upper()); self.card_body.setText(IMG_RE.sub("", body).strip())
        self.details.setVisible(bool(self.news))
        for j, d in enumerate(self.dots):
            d.setStyleSheet(f"background:{'#e0b040' if j == i else 'rgba(255,255,255,70)'};border:none;border-radius:3px;")

    def show_details(self):
        title, body = self.news[self.news_i]
        self.viewer = Viewer(self, title, body)

    # ---- state machine -------------------------------------------------
    def set_state(self, state, enabled=True):
        self.state = state
        self.btn.setText(self.LABELS[state]); self.btn.setEnabled(enabled)

    def start(self, mode):
        self.btn.setEnabled(False)
        if mode == "update":
            self.btn.setText("UPDATING"); self.bar.setValue(0); self.bar.show()
        if getattr(self, "w", None):
            self.w.wait()  # never drop a QThread that is still running
        self.w = Worker(mode, self.pending)
        # bound methods (not lambdas) so the slots run on the GUI thread, not the worker's
        self.w.status.connect(self.stat.setText)
        self.w.speed.connect(self.on_speed)
        self.w.progress.connect(self.on_progress)
        self.w.news.connect(self.set_news)
        self.w.version.connect(self.on_version)
        self.w.failed.connect(self.on_failed)
        self.w.checked.connect(self.on_checked)
        self.w.launcher_ready.connect(self.on_launcher_ready)
        self.w.done.connect(self.on_downloaded)
        self.w.start()

    def on_speed(self, text):
        self.bar.setFormat("    " + text)  # leading spaces: QSS padding doesn't move the bar text

    def on_progress(self, done, total):
        self.bar.setMaximum(max(total, 1))
        self.bar.setValue(done)

    def on_version(self, v):
        self.ver.setText(f"Version: {v}" if v else "")

    def on_launcher_ready(self, new_path):
        """Windows can't overwrite a running exe but can rename it: move ourselves aside, drop the new one in, restart."""
        exe = Path(sys.executable)
        old = exe.with_name(exe.name + ".old")
        try:
            old.unlink(missing_ok=True)
            os.replace(exe, old)
            try:
                os.replace(new_path, exe)
            except OSError:
                os.replace(old, exe)  # put the working launcher back
                raise
        except OSError as e:
            self.on_failed(f"Launcher update failed: {e}")
            return
        # PYINSTALLER_RESET_ENVIRONMENT: otherwise the child reuses this process's extraction dir
        subprocess.Popen([str(exe)] + sys.argv[1:], env={**os.environ, "PYINSTALLER_RESET_ENVIRONMENT": "1"})
        QApplication.quit()

    def on_downloaded(self):
        self.start("check")  # re-verify; flips to Play when clean

    def on_checked(self, stale):
        self.pending = stale
        self.bar.hide()
        if stale:
            self.stat.setText(f"Update available · {len(stale)} files · {fmt(sum(s for _, s, _ in stale))}")
            self.set_state("update")
        else:
            self.stat.setText("Ready to play")
            self.set_state("play")

    def on_failed(self, msg):
        self.bar.hide(); self.pending = []
        self.stat.setText(f"Error: {msg}")
        self.set_state("retry")

    def on_click(self):
        if self.state == "update":
            self.start("update")
        elif self.state == "retry":
            self.start("check")
        elif self.state == "play":
            subprocess.Popen([str(GAME_DIR / GAME_EXE)], cwd=GAME_DIR)
            QApplication.quit()

    def open_folder(self):
        GAME_DIR.mkdir(parents=True, exist_ok=True)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(GAME_DIR)))


if __name__ == "__main__":
    if getattr(sys, "frozen", False):  # leftovers from a launcher self-update
        for suffix in (".old", ".new"):
            try:
                Path(sys.executable + suffix).unlink(missing_ok=True)
            except OSError:
                pass  # previous launcher still exiting; the next start cleans it
    app = QApplication(sys.argv)
    app.setWindowIcon(QIcon(str(RES / "eden.ico")))
    win = Launcher(); win.show()
    sys.exit(app.exec())
