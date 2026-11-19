@echo off
setlocal
rem Build TensorFold v1.2.6 + the Bolt recipe's libbolt as bolt.dll for Windows ARM64 (sm_121).
rem Same toolchain as build-bolt.bat (v1.2.3), but installs to zig-out-v126 so the working
rem 1.2.3 install in zig-out stays intact for A/B benchmarking.

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
%ROOT%\tools\zig-aarch64-windows-0.17.0\zig.exe build native bolt install -Dsm=121 -Dstrip=true -Dnvcc="%CUDA_PATH%\bin\nvcc.exe" -Dbolt-src="%ROOT%\bolt-recipe\engine" --prefix zig-out-v126
if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
echo BUILD OK
dir zig-out-v126\native\bin\*.exe zig-out-v126\native\lib\*
