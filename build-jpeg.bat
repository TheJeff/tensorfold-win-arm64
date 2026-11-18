@echo off
setlocal
rem Build turbojpeg.dll (JPEG input decoding) for this Windows ARM64 tree.
rem
rem TensorFold pins libjpeg-turbo 3.1.4.1 exactly -- zig/src/core/picture/jpeg.zig
rem reads the "libjpeg-turbo version X (build Y)" string out of the DLL's file
rem bytes and refuses any X that is not the pin, because that pin is the release
rem Pillow 12.3 decoded with for 0.6.6's pixels. The project publishes no ARM64
rem Windows binary for 3.1.4.1 (its 3.2.x releases do, but those are refused),
rem so this is built from source here.
rem
rem Nothing outside Visual Studio's own Build Tools is needed: CMake and Ninja
rem both ship inside it, and the arm64 Neon SIMD builds under MSVC, so the
rem resulting DLL is self-contained (it imports only KERNEL32.dll).
rem
rem Overridable from the environment: TJ_VER, LIBDIR.

set "ROOT=C:\Projects\tensorfold-win-arm64"
set "VS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
set "CMAKE=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set "NINJA=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"

if "%TJ_VER%"=="" set "TJ_VER=3.1.4.1"
if "%LIBDIR%"=="" set "LIBDIR=%ROOT%\tensorfold\zig-out-v126\native\lib"

set "DL=%ROOT%\downloads"
set "SRC=%DL%\libjpeg-turbo-%TJ_VER%"
set "BLD=%DL%\ljt-build"
set "TARBALL=%DL%\libjpeg-turbo-%TJ_VER%.tar.gz"

call "%VS%\VC\Auxiliary\Build\vcvarsall.bat" arm64
if errorlevel 1 (
  echo VCVARSALL FAILED
  exit /b 1
)
set "PATH=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"

if not exist "%DL%" mkdir "%DL%"

echo === source ===
if not exist "%TARBALL%" (
  curl.exe -sSL -o "%TARBALL%" "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/%TJ_VER%.tar.gz"
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
"%CMAKE%" -S "%SRC%" -B "%BLD%" -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DENABLE_SHARED=ON -DENABLE_STATIC=OFF ^
  -DWITH_JPEG8=ON -DWITH_TOOLS=OFF -DWITH_TESTS=OFF ^
  -DWITH_SIMD=1 ^
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

if not exist "%BLD%\turbojpeg.dll" (
  echo NO turbojpeg.dll PRODUCED
  exit /b 1
)

echo === install ===
if not exist "%LIBDIR%" mkdir "%LIBDIR%"
copy /y "%BLD%\turbojpeg.dll" "%LIBDIR%\turbojpeg.dll" >nul
if errorlevel 1 (
  echo INSTALL FAILED
  exit /b 1
)

rem jpeg.zig refuses the library unless this exact line is in the file bytes.
findstr /m /c:"libjpeg-turbo version %TJ_VER%" "%LIBDIR%\turbojpeg.dll" >nul
if errorlevel 1 (
  echo VERSION STRING NOT FOUND -- the server will refuse this library
  exit /b 1
)

echo JPEG BUILD OK
echo installed turbojpeg.dll into %LIBDIR%
echo serve with --vision to use it
dir "%LIBDIR%\*.dll"
