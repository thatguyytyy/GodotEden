#!/bin/sh
# Builds the Linux dedicated-server engine from the Windows source tree. Run as root inside WSL (Ubuntu):
#   wsl -d Ubuntu -u root -- sh /mnt/c/DEV_DRIVE/Dev/GodotEden/demo_eden/multiplayer/server/deploy/build_linux_server.sh
# Result: /root/godot/bin/godot.linuxbsd.template_release.x86_64 (copy it to the server as eden_server).
#
# Why a chroot: the server (Ubuntu 25.04) has glibc 2.41. Building on WSL's own Ubuntu 26.04 (glibc 2.43) makes a
# binary that needs GLIBC_2.43 and won't start there, so the build runs in an Ubuntu 24.04 (glibc 2.39) chroot.
# The binary links libstdc++ statically; it needs only libc, libm and libgomp on the server.
#
# First time only (then this script is enough):
#   apt-get install -y debootstrap rsync
#   debootstrap --variant=minbase noble /opt/noble http://archive.ubuntu.com/ubuntu
#   (add "universe" to /opt/noble/etc/apt/sources.list.d/ubuntu.sources, bind-mount /proc and /dev into /opt/noble)
#   chroot /opt/noble apt-get install -y build-essential scons python3 pkg-config
set -e
SRC=/mnt/c/DEV_DRIVE/Dev/GodotEden
mountpoint -q /opt/noble/proc || mount --bind /proc /opt/noble/proc
mountpoint -q /opt/noble/dev || mount --bind /dev /opt/noble/dev
mkdir -p /root/godot /opt/noble/src
mountpoint -q /opt/noble/src || mount --bind /root/godot /opt/noble/src
# Source onto WSL's own disk (the Windows drive is far too slow to compile on). Not copied: the demo project, the
# Windows binaries, git data and the 2.5 GB ONNX Runtime (the eden_terrain_diffusion module is Windows-only).
rsync -a --delete --exclude=demo_eden --exclude=bin --exclude=.git --exclude=.stdb --exclude=thirdparty/onnxruntime \
  --exclude='*.obj' --exclude='*.lib' --exclude='*.pdb' --exclude='*.exp' --exclude='.sconsign*' --exclude=obj \
  --exclude=.scons_cache --exclude=.vs --exclude=bin "$SRC/" /root/godot/
# (--delete would remove the build output, but bin is excluded from both sides, so incremental builds work)
chroot /opt/noble bash -c 'cd /src && scons platform=linuxbsd target=template_release arch=x86_64 \
  x11=no wayland=no vulkan=no opengl3=no alsa=no pulseaudio=no dbus=no speechd=no fontconfig=no udev=no touch=no \
  use_static_cpp=yes disable_path_overrides=no voxel_ispc=no custom_modules=eden_modules \
  module_godotsteam_enabled=no tests=no -j"$(nproc)"'
python3 - <<'EOF'
import re
d = open('/root/godot/bin/godot.linuxbsd.template_release.x86_64', 'rb').read()
v = sorted(set(re.findall(rb'GLIBC_(\d+\.\d+)', d)), key=lambda s: [int(x) for x in s.split(b'.')])
print('needs glibc up to', v[-1].decode(), '(the server has 2.41)')
EOF
