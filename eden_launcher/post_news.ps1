# Post a news entry without shipping a build (uploads news.md and news/ only; the game files aren't touched).
# Usage: .\post_news.ps1 -Title "Roadmap update" -Notes "Text, **markdown** and ![](news/pic.png) are fine"
# Or edit ExportedGames\release\news.md by hand (newest entry on top) and run: .\post_news.ps1 -UploadOnly
param(
    [string]$Title = "",
    [string]$Notes = "",
    [switch]$UploadOnly
)
$ErrorActionPreference = "Stop"
$cfg   = Get-Content "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json
$stage = "$($cfg.exports_dir)\release"
$news  = "$stage\news.md"
if (-not $UploadOnly -and (-not $Title -or -not $Notes)) { throw "give -Title and -Notes, or -UploadOnly" }

New-Item -ItemType Directory -Force $stage | Out-Null
$old = if (Test-Path $news) { [IO.File]::ReadAllText($news).TrimStart([char]0xFEFF) } else { "# Eden_Project`n`n" }
if (-not $UploadOnly) {
    # insert after the "# Eden_Project" title line, so the new entry is first
    $entry = "## $Title ($(Get-Date -Format yyyy-MM-dd))`n$Notes`n`n"
    $old = if ($old -match "(?s)^(# [^\n]*\n+)(.*)$") { $Matches[1] + $entry + $Matches[2] } else { $entry + $old }
}
[IO.File]::WriteAllText($news, $old, (New-Object Text.UTF8Encoding $false))  # no BOM

$dest = "$($cfg.ssh_target):$($cfg.server_dir)/"
scp -o BatchMode=yes $news $dest
if ($LASTEXITCODE) { throw "scp news.md failed" }
if (Test-Path "$stage\news") { scp -o BatchMode=yes -r "$stage\news" $dest; if ($LASTEXITCODE) { throw "scp news images failed" } }
$live = Invoke-RestMethod "$($cfg.tunnel_url)/news.md?t=$(Get-Random)" -UserAgent "EdenLauncher/release"
if ($live.TrimStart([char]0xFEFF) -ne $old) { throw "tunnel serves different news.md than uploaded" }
@{ ok = $true; posted = $Title } | ConvertTo-Json -Compress
