@echo off
setlocal
rem Build tfgrammar.dll (structured output / required tool calls) for this Windows ARM64 tree.
rem TensorFold pins xgrammar v0.2.8; zig build grammar installs the DLL beside the server.

call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" arm64
if errorlevel 1 (
  echo VCVARSALL FAILED
  exit /b 1
)

set "ROOT=C:\Projects\tensorfold-win-arm64"
cd /d %ROOT%
if not exist "%ROOT%\xgrammar\.git" (
  git clone --branch v0.2.8 --recurse-submodules https://github.com/mlc-ai/xgrammar.git "%ROOT%\xgrammar"
  if errorlevel 1 (
    echo XGRAMMAR CLONE FAILED
    exit /b 1
  )
)

cd /d "%ROOT%\tensorfold"
rem --prefix is required: without it this installs into the old zig-out (v1.2.3) tree while
rem build-bolt-126.bat and the GUI use zig-out-v126, so a rebuilt grammar DLL silently never
rem reaches the server you actually run.
"%ROOT%\tools\zig-aarch64-windows-0.17.0\zig.exe" build grammar -Dxgrammar="%ROOT%\xgrammar" --prefix zig-out-v126
if errorlevel 1 (
  echo GRAMMAR BUILD FAILED
  exit /b 1
)
echo GRAMMAR BUILD OK
dir "%ROOT%\tensorfold\zig-out-v126\native\lib\*.dll"
