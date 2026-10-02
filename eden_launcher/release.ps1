# Non-interactive release: export -> stage -> manifest -> upload -> verify through the tunnel.
# Usage: .\release.ps1 -Version 0.1.2 -Notes "Fixed X" [-NoUpload] [-SkipExport]
# Settings live in config.json. Last stdout line is a JSON result; exit code 0 = released and verified.
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Notes = "",
    [switch]$NoUpload,
    [switch]$SkipExport
)
$ErrorActionPreference = "Stop"
$cfg   = Get-Content "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json
$repo  = (Resolve-Path "$PSScriptRoot\..").Path
$stage = "$($cfg.exports_dir)\release"
$exe   = "$($cfg.exports_dir)\Eden_Project_$Version.exe"

if (-not $SkipExport) {
    & "$repo\$($cfg.godot_editor)" --headless --path "$repo\demo_eden" --export-release $cfg.export_preset $exe
    if ($LASTEXITCODE -or -not (Test-Path $exe)) { throw "export failed" }
}
if (-not (Test-Path $exe)) { throw "missing $exe (run without -SkipExport)" }

New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $exe "$stage\GodotEden.exe" -Force
foreach ($f in $cfg.extra_files) { Copy-Item "$($cfg.exports_dir)\$f" $stage -Force }

# news.md: newest entry on top
$news = "$stage\news.md"
$old = if (Test-Path $news) { [IO.File]::ReadAllText($news).TrimStart([char]0xFEFF) } else { "# Eden_Project`n`n" }
if ($Notes -and $old -notmatch "(?m)^## $([regex]::Escape($Version))\b") {
    $old = "## $Version ($(Get-Date -Format yyyy-MM-dd))`n$Notes`n`n$old"
}
[IO.File]::WriteAllText($news, $old, (New-Object Text.UTF8Encoding $false))  # no BOM (PS 5.1 -Encoding utf8 adds one)

python "$PSScriptRoot\generate_manifest.py" $stage $Version
if ($LASTEXITCODE) { throw "manifest failed" }

$uploaded = $false
if (-not $NoUpload) {
    $ssh = @("-o", "BatchMode=yes")   # never prompt; fail fast if the key isn't set up
    $dest = "$($cfg.ssh_target):$($cfg.server_dir)/"
    # payload first, manifest last: testers never see a manifest pointing at missing files
    scp @ssh (Get-ChildItem $stage -File | Where-Object Name -ne "manifest.json").FullName $dest
    if ($LASTEXITCODE) { throw "scp payload failed" }
    if (Test-Path "$stage\news") {   # images referenced from news.md as ![](news/x.png)
        scp @ssh -r "$stage\news" $dest
        if ($LASTEXITCODE) { throw "scp news images failed" }
    }
    scp @ssh "$stage\manifest.json" $dest
    if ($LASTEXITCODE) { throw "scp manifest failed" }
    $live = (Invoke-RestMethod "$($cfg.tunnel_url)/manifest.json?t=$(Get-Random)" -UserAgent "EdenLauncher/release").version
    if ($live -ne $Version) { throw "tunnel serves version '$live', expected '$Version'" }
    $uploaded = $true
}
@{ ok = $true; version = $Version; staged = $stage; uploaded = $uploaded } | ConvertTo-Json -Compress
