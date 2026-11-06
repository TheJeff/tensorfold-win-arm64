@echo off
setlocal
rem Build the native TensorFold control GUI (Windows ARM64, Zig 0.17 from tools/).
rem Output: gui\zig-out\bin\tensorfold-gui.exe

cd /d "%~dp0"
set "ZIG=%~dp0..\tools\zig-aarch64-windows-0.17.0\zig.exe"
if not exist "%ZIG%" (
  echo zig not found at "%ZIG%"
  exit /b 1
)

"%ZIG%" run -O ReleaseFast src\make_icon.zig
if errorlevel 1 exit /b 1
powershell -NoProfile -Command "(Get-Item '%~dp0assets\tensorfold.rc').LastWriteTime = Get-Date" >nul

"%ZIG%" build -Drelease=true
if errorlevel 1 exit /b 1
echo built: %~dp0zig-out\bin\tensorfold-gui.exe
