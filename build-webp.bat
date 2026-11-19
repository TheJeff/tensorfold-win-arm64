@echo off
setlocal
rem Build libwebpdecoder.dll (WebP input decoding) for this Windows ARM64 tree.
rem
rem TensorFold pins libwebp 1.6.0 exactly -- zig/src/core/picture/webp.zig calls
rem WebPGetDecoderVersion() and refuses anything that is not 0x010600, because that
rem is the release Pillow 13.0.0 bundles and its pixels are the reference.
rem
rem Unlike JPEG, no patch is needed to make the engine find this. webp.zig:20 has no
rem Windows name (it asks for libwebpdecoder.so.3 even on Windows), but webp.zig:45
rem checks TENSORFOLD_LIBWEBP before the name list -- and the engine's own missing-
library message tells you to set exactly that. So set it in gui/models.json:
rem
rem   "TENSORFOLD_LIBWEBP": "...\\zig-out-v126\\native\\lib\\libwebpdecoder.dll"
rem
rem libwebpdecoder is an unconditional CMake target, so turning every tool off still
rem produces it. The decoder also needs libsharpyuv.dll beside it.
rem
rem Overridable from the environment: WEBP_VER, LIBDIR.

set "ROOT=C:\Projects\tensorfold-win-arm64"
set "VS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
set "CMAKE=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"

if "%WEBP_VER%"=="" set "WEBP_VER=1.6.0"
if "%LIBDIR%"=="" set "LIBDIR=%ROOT%\tensorfold\zig-out-v126\native\lib"

set "DL=%ROOT%\downloads"
set "SRC=%DL%\libwebp-%WEBP_VER%"
set "BLD=%DL%\libwebp-build"
set "TARBALL=%DL%\libwebp-%WEBP_VER%.tar.gz"

call "%VS%\VC\Auxiliary\Build\vcvarsall.bat" arm64
if errorlevel 1 (
  echo VCVARSALL FAILED
  exit /b 1
)
set "PATH=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"

if not exist "%DL%" mkdir "%DL%"

echo === source ===
if not exist "%TARBALL%" (
  curl.exe -fsSL -o "%TARBALL%" "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-%WEBP_VER%.tar.gz"
  if errorlevel 1 (
    echo DOWNLOAD FAILED
    exit /b 1
  )
)
if not exist "%SRC%\CMakeLists.txt" (
  tar.exe -xf "%TARBALL%" -C "%DL%"
  if errorlevel 1 (
    echo EXTRACT FAILED
    exit /b 1
  )
)
echo using %SRC%

echo === configure ===
if exist "%BLD%" rmdir /s /q "%BLD%"
rem CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded is what keeps the DLL self-contained:
rem without it libwebpdecoder.dll imports VCRUNTIME140.dll and the box needs the
rem Visual C++ redistributable. With it, the only import is KERNEL32.dll.
"%CMAKE%" -S "%SRC%" -B "%BLD%" -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
  -DBUILD_SHARED_LIBS=ON ^
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF ^
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF ^
  -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_LIBWEBPMUX=OFF -DWEBP_BUILD_WEBPMUX=OFF ^
  -DWEBP_BUILD_EXTRAS=OFF ^
  -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64
if errorlevel 1 (
  echo CONFIGURE FAILED
  exit /b 1
)

echo === build ===
"%CMAKE%" --build "%BLD%"
if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
if not exist "%BLD%\libwebpdecoder.dll" (
  echo NO libwebpdecoder.dll PRODUCED
  exit /b 1
)

echo === install ===
if not exist "%LIBDIR%" mkdir "%LIBDIR%"
copy /y "%BLD%\libwebpdecoder.dll" "%LIBDIR%\libwebpdecoder.dll" >nul
if errorlevel 1 (
  echo INSTALL FAILED
  exit /b 1
)
if exist "%BLD%\libsharpyuv.dll" copy /y "%BLD%\libsharpyuv.dll" "%LIBDIR%\libsharpyuv.dll" >nul

rem webp.zig's Fns struct needs all three of these or it treats the library as absent.
for %%S in (WebPGetDecoderVersion WebPGetInfo WebPDecodeRGBAInto) do (
  findstr /m /c:"%%S" "%LIBDIR%\libwebpdecoder.dll" >nul
  if errorlevel 1 (
    echo MISSING EXPORT %%S -- the server will refuse this library
    exit /b 1
  )
)

echo WEBP BUILD OK
echo installed libwebpdecoder.dll into %LIBDIR%
echo set TENSORFOLD_LIBWEBP to that path in gui/models.json, and serve with --vision
dir "%LIBDIR%\*.dll"
