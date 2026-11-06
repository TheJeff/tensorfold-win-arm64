@echo off
setlocal
rem Build TensorFold 1.1.6 + the Bolt recipe's libbolt as bolt.dll for Windows ARM64 (sm_121).
rem Mirrors docs/windows.md in MiaAI-Lab/Nemotron-3.5-Bolt-TensorFold-DGX-Spark (PR #7).

call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" arm64
if errorlevel 1 (
  echo VCVARSALL FAILED
  exit /b 1
)

set "CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4"
set "PATH=%CUDA_PATH%\bin;%PATH%"

cd /d C:\Projects\tensorfold-win-arm64\tensorfold

echo === nvcc ===
nvcc --version
echo === zig ===
C:\Projects\tensorfold-win-arm64\tools\zig-aarch64-windows-0.17.0\zig.exe version
echo === build ===
C:\Projects\tensorfold-win-arm64\tools\zig-aarch64-windows-0.17.0\zig.exe build native bolt install -Dsm=121 -Dstrip=true -Dnvcc="%CUDA_PATH%\bin\nvcc.exe" -Dbolt-src="C:\Projects\tensorfold-win-arm64\bolt-recipe\engine"
if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
echo BUILD OK
dir zig-out\native\bin\*.exe zig-out\native\lib\*
