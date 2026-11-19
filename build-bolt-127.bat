@echo off
setlocal
rem Build TensorFold v1.2.7 + mia 0001-0005 + the Bolt recipe's libbolt as bolt.dll for
rem Windows ARM64 (sm_121). Same toolchain as build-bolt-126.bat, but installs to
rem zig-out-v127 so the working 1.2.6 install in zig-out-v126 stays intact for A/B.
rem Branch: win-arm64/v1.2.7 (re-port + five Mia patch commits). Plan: UPSTREAM-1.2.7.md.

call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" arm64
if errorlevel 1 (
  echo VCVARSALL FAILED
  exit /b 1
)

set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4"
set "PATH=%CUDA_PATH%\bin;%PATH%"
set "ROOT=C:\Projects\tensorfold-win-arm64"

cd /d %ROOT%\tensorfold

echo === branch ===
git rev-parse --abbrev-ref HEAD
git log --oneline -1
echo === nvcc ===
nvcc --version
echo === zig ===
%ROOT%\tools\zig-aarch64-windows-0.17.0\zig.exe version
echo === build ===
%ROOT%\tools\zig-aarch64-windows-0.17.0\zig.exe build native bolt install -Dsm=121 -Dstrip=true -Dnvcc="%CUDA_PATH%\bin\nvcc.exe" -Dbolt-src="%ROOT%\bolt-recipe\engine" --prefix zig-out-v127
if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
echo BUILD OK
dir zig-out-v127\native\bin\*.exe zig-out-v127\native\lib\*
