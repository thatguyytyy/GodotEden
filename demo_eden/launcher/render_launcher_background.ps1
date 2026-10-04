# Renders launcher/launcher_background_movie.tscn to PNG frames, then encodes the silent, looping .ogv (Theora).
#   .\launcher\render_launcher_background.ps1 -Godot <path to godot.exe> [-Seconds 24] [-Fps 30] [-Quality 7] [-Out launcher_background.ogv]
# Quality is Theora's 0-10; lower it (or use 1600x1000) if the file passes ~30 MB.
param(
	[Parameter(Mandatory)][string]$Godot,
	[int]$Seconds = 24,
	[int]$Fps = 30,
	[int]$Quality = 7,
	[string]$Out = "launcher_background.ogv"
)
$project = Split-Path $PSScriptRoot -Parent
$frames = Join-Path $env:TEMP "launcher_background_frames"
if (Test-Path $frames) { Remove-Item $frames -Recurse -Force }
& $Godot --path $project res://launcher/launcher_background_movie.tscn --fixed-fps $Fps -- "--out=$frames" "--seconds=$Seconds" "--fps=$Fps"
if ($LASTEXITCODE -ne 0) { throw "Godot failed" }
& ffmpeg -y -framerate $Fps -i (Join-Path $frames "%05d.png") -an -c:v libtheora -q:v $Quality -pix_fmt yuv420p $Out
if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed" }
Remove-Item $frames -Recurse -Force
"{0:N1} MB -> {1}" -f ((Get-Item $Out).Length / 1MB), $Out
