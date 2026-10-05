@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d "C:\DEV_DRIVE\Dev\GodotEden"
python -m SCons platform=windows target=editor vulkan=yes use_mingw=no d3d12=no voxel_ispc=yes custom_modules=eden_modules -j8
