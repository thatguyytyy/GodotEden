# Setting up GodotEden

GodotEden is a fork of Godot 4.6 with engine modules for a voxel planet game: a forked voxel module, planet
generators, atmosphere, ocean, ambience/weather and foliage. The game project that uses it lives in a separate
repository (eden-project); the playable test planet, eden-demo, is
also separate (`C:\DEV_DRIVE\Dev\Projects\eden-demo`, formerly `demo_eden/` in this repository). Paths below
marked `eden-demo/` are in that project.

Windows x64 is the supported platform. The build is Vulkan (Forward+).

## 1. Install the tools

| Tool | Needed for | Notes |
|---|---|---|
| Visual Studio 2022, workload **Desktop development with C++** | building | Community edition is fine |
| Python 3.8+ and SCons (`pip install scons`) | building | |
| Git (and access to the private `ZundleFire/EdenModules` repo) | cloning | see step 2 |
| [ISPC](https://ispc.github.io/) | optional: SIMD noise in the voxel module | on PATH, or set `ISPC_PATH`; without it a scalar fallback is built |
| ONNX Runtime 1.20.1 (win-x64-gpu) | optional: `eden_terrain_diffusion` | see step 4 |
| SpacetimeDB CLI 2.7 and .NET 8 SDK | optional: multiplayer | see `eden-demo/multiplayer/README.md` |
| ffmpeg | optional: encoding recorded clips | |

## 2. Clone with submodules

```powershell
git clone https://github.com/ZundleFire/GodotEden.git
cd GodotEden
git submodule update --init --recursive
```

Two submodules:

- `modules/voxel`: the forked voxel module (`ZundleFire/godot_voxel`, branch `GPU_Renderer`). Public.
- `eden_modules`: atmosphere, clouds, rings and ocean (`ZundleFire/EdenModules`). **Private**: your GitHub account
  needs access. Without it, build without `custom_modules=eden_modules` (the demo scenes that use the atmosphere
  and ocean will then show missing node types).

## 3. Build the editor

From the repository root:

```powershell
build_eden.bat
```

It sets up the MSVC environment and runs:

```
python -m SCons platform=windows target=editor vulkan=yes use_mingw=no d3d12=no voxel_ispc=yes custom_modules=eden_modules -j8
```

The output is `bin/godot.windows.editor.x86_64.exe` (plus a `.console.exe` wrapper for command-line runs).
A first build takes a while; later ones only rebuild what changed. Check the binary's modified time after a build:
running the `.bat` through another shell (for example `cmd /c` from Git Bash) can exit 0 without building.

`build_eden_tests.bat` builds with `tests=yes` for the engine's C++ unit tests.

## 4. Optional large assets (not in git)

These are kept out of git because of their size (`.gitignore`); copy them in from the project's asset storage.

- **Space panoramas**: `eden-demo/Panoramics/SkySphere_01.HDR` … `SkySphere_20.HDR` (about 2 GB; the `.import`
  files are in git). After copying, run `python eden-demo/set_panorama_import.py` so they import at a size that
  fits in VRAM. Without them the sky falls back to procedural stars, and scenes that reference a panorama log a
  missing-resource error.
- **ONNX Runtime 1.20.1** for `modules/eden_terrain_diffusion`: extract the official
  `onnxruntime-win-x64-gpu-1.20.1` release into `thirdparty/onnxruntime/` so that
  `thirdparty/onnxruntime/lib/onnxruntime.lib` and `thirdparty/onnxruntime/include/` exist. Without it the module
  is skipped automatically and everything else builds.

## 5. Open the demo planet

```powershell
bin\godot.windows.editor.x86_64.exe --path C:\DEV_DRIVE\Dev\Projects\eden-demo --editor
```

The first open imports every asset (several minutes). The main scenes:

- `eden_play.tscn`: walk the planet as a character (WASD, Shift run, Space jump, mouse look; Esc settings,
  K calendar, G build hammer, LMB/RMB dig/place).
- `_ocean_editor_probe.tscn`: the full planet with atmosphere, ocean, weather and foliage, for editing.

Graphics presets (Low/Medium/High/Ultra) are on the `EdenGraphics` node and in the in-game settings menu.
The first switch to a higher preset can pause for a long time while shaders compile; later switches are instant.

## 6. Tests

Each test runs the real planet scene in a window and prints PASS/FAIL. Run from `eden-demo/`:

```powershell
..\bin\godot.windows.editor.x86_64.console.exe --path . -s res://_play_test.gd
..\bin\godot.windows.editor.x86_64.console.exe --path . -s res://_planet_move_test.gd
..\bin\godot.windows.editor.x86_64.console.exe --path . -s res://building/_build_test.gd
..\bin\godot.windows.editor.x86_64.console.exe --path . -s res://settings/_settings_test.gd
..\bin\godot.windows.editor.x86_64.console.exe --path . -s res://settings/_season_test.gd
python multiplayer/mp_test.py ..\bin\godot.windows.editor.x86_64.console.exe
```

After adding a script with a new `class_name`, run the editor once with `--import` so other scripts can see it.

Benchmarks and clip recording live in `eden-demo/perf/` (`run_perf_report.py`, `_record_clips.gd`). Close other
GPU-heavy programs first: a game running in the background skews the numbers.

## Where things are

| Path | What |
|---|---|
| `modules/eden_planet_gen` | planet generators V1-V4 (V4 is current), world data module |
| `modules/eden_ambience` | look, fog, particles, audio, regional weather and snow |
| `modules/eden_foliage` | procedural tree, bush and rock generators |
| `modules/eden_erosion`, `eden_stamps`, `eden_icosphere`, `eden_terrain_diffusion` | terrain tooling |
| `modules/voxel` (submodule) | voxel terrain, GPU-driven renderer, instancer (incl. the no-overlap site grid) |
| `eden_modules` (submodule) | atmosphere, clouds, rings, parent planet, space panorama, ocean |
| `EDEN_SYSTEMS_REFERENCE.md`, `VOXEL_REFERENCE.md` | system reference notes |
