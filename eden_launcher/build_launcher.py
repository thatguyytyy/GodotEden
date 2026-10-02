"""Usage: python build_launcher.py  -> dist/EdenLauncher.exe  (pip install pyinstaller pyside6 requests)
Tunnel URL comes from config.json; add --installer to also build Output/EdenSetup.exe (needs Inno Setup)."""
import json, re, shutil, subprocess, sys
from pathlib import Path

here = Path(__file__).parent
url = json.loads((here / "config.json").read_text(encoding="utf-8-sig"))["tunnel_url"]
src = here / "launcher.py"
original = src.read_text(encoding="utf-8")
src.write_text(re.sub(r'^SERVER_URL = ".*?"', f'SERVER_URL = "{url}"', original, count=1, flags=re.M), encoding="utf-8")
try:
    subprocess.run([sys.executable, "-m", "PyInstaller", "--onefile", "--noconsole", "--noconfirm",
                    "--icon", str(here / "assets" / "eden.ico"), "--add-data", f"{here / 'assets'};assets", "--name", "EdenLauncher", str(src)], check=True, cwd=here)
finally:
    src.write_text(original, encoding="utf-8")  # keep the source clean
if "--installer" in sys.argv:
    iscc = next((p for p in (shutil.which("ISCC"),
                             r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
                             str(Path.home() / r"AppData\Local\Programs\Inno Setup 6\ISCC.exe"))
                 if p and Path(p).exists()), "ISCC")
    subprocess.run([iscc, "installer.iss"], check=True, cwd=here)
