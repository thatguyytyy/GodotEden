"""Usage: python build_launcher.py  -> dist/EdenLauncher.exe  (pip install pyinstaller pyside6 requests)
Tunnel URL comes from config.json and is baked into a COPY of launcher.py under build/, so the tracked source
never contains the real URL (the repo is public). Add --installer to also build Output/EdenSetup.exe (Inno Setup)."""
import json, re, shutil, subprocess, sys
from pathlib import Path

here = Path(__file__).parent
url = json.loads((here / "config.json").read_text(encoding="utf-8-sig"))["tunnel_url"]
work = here / "build"
(work / "src").mkdir(parents=True, exist_ok=True)
src = work / "src" / "launcher.py"
text = (here / "launcher.py").read_text(encoding="utf-8")
patched, n = re.subn(r'^SERVER_URL = ".*?"', f'SERVER_URL = "{url}"', text, count=1, flags=re.M)
assert n == 1, "SERVER_URL line not found in launcher.py"
src.write_text(patched, encoding="utf-8")
subprocess.run([sys.executable, "-m", "PyInstaller", "--onefile", "--noconsole", "--noconfirm",
                "--icon", str(here / "assets" / "eden.ico"), "--add-data", f"{here / 'assets'};assets",
                "--name", "EdenLauncher", "--distpath", str(here / "dist"), "--workpath", str(work / "pyi"),
                "--specpath", str(work), str(src)], check=True)
if "--installer" in sys.argv:
    iscc = next((p for p in (shutil.which("ISCC"),
                             r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
                             str(Path.home() / r"AppData\Local\Programs\Inno Setup 6\ISCC.exe"))
                 if p and Path(p).exists()), "ISCC")
    subprocess.run([iscc, "installer.iss"], check=True, cwd=here)
