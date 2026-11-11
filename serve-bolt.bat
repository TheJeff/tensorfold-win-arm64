@echo off
setlocal
rem Serve Nemotron 3.5 Bolt on this N1X (Windows 11 ARM64, sm_121) with the recipe's bolt.dll.
rem Settings mirror docs/windows.md in MiaAI-Lab/Nemotron-3.5-Bolt-TensorFold-DGX-Spark (PR #7);
rem PARALLEL / CONTEXT / PORT are overridable from the environment.

if "%PARALLEL%"=="" set "PARALLEL=4"
if "%CONTEXT%"=="" set "CONTEXT=131072"
if "%PROMPT_CACHE_GIB%"=="" set "PROMPT_CACHE_GIB=4"
if "%PORT%"=="" set "PORT=8082"

set "ROOT=C:\Projects\tensorfold-win-arm64"
set "BOLT_DRAFT=%ROOT%\models\Nemotron-3.5-Bolt-LiLiCorr"
set "BOLT_KV=bf16"
set "BOLT_KV_PIN=0"
set "BOLT_SSM_LAZY=1"
set "BOLT_DRAFT_Q8=1"
set "BOLT_NV4_FP4=1"
set "TENSORFOLD_NO_UPDATE_CHECK=1"

"%ROOT%\tensorfold\zig-out-v126\native\bin\tensorfold-native.exe" serve ^
  "%ROOT%\models\Nemotron-3.5-Bolt-74B-A9B-24GB" ^
  --name Nemotron-3.5-Bolt --host 127.0.0.1 --port %PORT% ^
  --parallel %PARALLEL% --context %CONTEXT% --prompt-cache-gib %PROMPT_CACHE_GIB%
