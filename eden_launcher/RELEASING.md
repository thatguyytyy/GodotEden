# Eden launcher: release runbook (for Claude Code)

Flow: Windows dev box exports + hashes -> scp to Ubuntu (nginx :8080) -> cloudflared tunnel -> launcher on testers' PCs.

## Ship a game update (no human input)
    powershell -File eden_launcher\release.ps1 -Version <x.y.z> -Notes "<patch notes>"
Exports demo_eden, stages `ExportedGames\release`, writes manifest.json, scp's (payload, then manifest), and verifies the
tunnel serves the new version. Last stdout line is JSON `{"ok":true,...}`; non-zero exit = failed, message on stderr.
Flags: `-NoUpload` (stage only), `-SkipExport` (reuse `Eden_Project_<v>.exe`). Pick the version by bumping the last one in
`ExportedGames\release\manifest.json`.

## News
`ExportedGames\release\news.md` is the news file. Each `## Heading` is one card in the launcher, shown in file order
(NOT sorted by date): newest entry on top. `release.ps1 -Notes` and `post_news.ps1` both insert at the top.
- With a build: `release.ps1 -Version x.y.z -Notes "..."`
- Without a build: `post_news.ps1 -Title "Roadmap" -Notes "..."` (or hand-edit news.md, then `post_news.ps1 -UploadOnly`)
- Images: put the file in `ExportedGames\release\news\` and write `![](news/shot.png)` in the entry. Both scripts upload
  `news/`; the manifest ignores it, so testers' game folders stay clean. Images show in the DETAILS viewer.

## Ship a new launcher (rare: only when launcher.py changes)
    python eden_launcher\build_launcher.py --installer     # -> Output\EdenSetup.exe, send to testers

## One-time setup
1. Copy `config.example.json` to `config.json` (git-ignored: the repo is public, so keep real hosts/logins out of it)
   and fill in tunnel_url, ssh_target. ssh must work key-only: `ssh -o BatchMode=yes <ssh_target> true`.
2. Ubuntu (done 2026-10-02): `server/eden_server.py` runs as the user systemd service `eden-files` on 127.0.0.1:8473,
   serving /var/www/eden_project. Needs `sudo loginctl enable-linger <user>` to survive logout/reboot.
   cloudflared ingress -> `http://localhost:8473`. (80/3000/8080 are taken by other things; no nginx.)
3. Install Inno Setup 6 (`winget install JRSoftware.InnoSetup`) and `pip install pyside6 requests pyinstaller`.
