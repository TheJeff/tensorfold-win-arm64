@echo off
setlocal
rem P1 host gates for win-arm64/v1.2.7 (no GPU): codec diagnostics (12/12 baseline),
rem the vision-weights host tests (now incl. mia 0001's quant tests), and Mia's compile
rem gate for the 0005 video wiring. Run before build-bolt-127.bat.

call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" arm64
if errorlevel 1 (
  echo VCVARSALL FAILED
  exit /b 1
)

set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4"
set "PATH=%CUDA_PATH%\bin;%PATH%"
set "ROOT=C:\Projects\tensorfold-win-arm64"
set "ZIG=%ROOT%\tools\zig-aarch64-windows-0.17.0\zig.exe"

cd /d %ROOT%\tensorfold

echo === branch ===
git rev-parse --abbrev-ref HEAD
git log --oneline -1
echo === zig ===
%ZIG% version

echo === gate 1/3: test-codec-diagnostics-host ===
%ZIG% build test-codec-diagnostics-host --summary all
if errorlevel 1 (
  echo GATE 1 FAILED
  exit /b 1
)

echo === gate 2/3: test-qwen-vision-weights-host (incl. mia 0001 quant tests) ===
%ZIG% build test-qwen-vision-weights-host --summary all
if errorlevel 1 (
  echo GATE 2 FAILED
  exit /b 1
)

echo === gate 3/3: check-native-cuda-host (mia 0005 compile gate) ===
%ZIG% build check-native-cuda-host -Dsm=121 -Dnvcc="%CUDA_PATH%\bin\nvcc.exe"
if errorlevel 1 (
  echo GATE 3 FAILED
  exit /b 1
)

echo GATES OK
exit /b 0
