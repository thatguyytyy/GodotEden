@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d "%~dp0"
python -m SCons platform=windows target=template_release vulkan=yes use_mingw=no d3d12=no voxel_ispc=yes custom_modules=eden_modules -j8 || exit /b 1
python -m SCons platform=windows target=template_debug vulkan=yes use_mingw=no d3d12=no voxel_ispc=yes custom_modules=eden_modules -j8
