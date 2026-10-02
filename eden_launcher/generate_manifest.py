"""Usage: python3 generate_manifest.py <build_dir> [version]  -> writes <build_dir>/manifest.json"""
import hashlib, json, sys, time
from pathlib import Path

SKIP = {"manifest.json", "news.md"}  # served alongside, not part of the game files
SKIP_DIRS = ("news/", "launcher/")   # news images / the launcher's own exe: served, but not game files


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    root = Path(sys.argv[1]).resolve()
    version = sys.argv[2] if len(sys.argv) > 2 else time.strftime("%Y%m%d-%H%M%S")
    files = {}
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root).as_posix()
        if p.is_file() and rel not in SKIP and not rel.startswith(SKIP_DIRS):
            files[rel] = {"sha256": sha256(p), "size": p.stat().st_size}
    manifest = {"version": version, "files": files}
    exe = root / "launcher" / "EdenLauncher.exe"
    if exe.is_file():  # installed launchers compare their own hash against this and self-update
        manifest["launcher"] = {"sha256": sha256(exe), "size": exe.stat().st_size}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"{len(files)} files, version {version}" + (", launcher published" if "launcher" in manifest else ""))


if __name__ == "__main__":
    main()
