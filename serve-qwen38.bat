@echo off
setlocal
rem Serve Qwen3.8 Flash Next (nvidia/Qwen3.8-Flash-Next-FP4-Local) on this N1X.
rem TensorFold 1.2.3 already registers the family (qwen4_exp) in the native CUDA
rem host, so this is a plain serve — no .cu DLL like Bolt needed.
rem Settings mirror MiaAI-Lab's single-Spark recipe (scripts/config.sh), scaled to
rem this box: 96 GiB framebuffer, one GPU, bf16 KV (the CUDA family refuses fp8),
rem n-gram table read with pread. Measured: 41 s load, 72.7 GiB resident, ~30 tok/s.

if "%PARALLEL%"=="" set "PARALLEL=2"
if "%CONTEXT%"=="" set "CONTEXT=262144"
if "%PROMPT_CACHE_GIB%"=="" set "PROMPT_CACHE_GIB=4"
if "%PORT%"=="" set "PORT=8083"

set "ROOT=C:\Projects\tensorfold-win-arm64"
set "TENSORFOLD_MEMORY_RESERVE_GIB=4"
set "TF_FLASHNEXT_DRAFTS=6"
set "TF_FLASHNEXT_GATHER_READ=pread"
set "TENSORFOLD_NO_UPDATE_CHECK=1"

"%ROOT%\tensorfold\zig-out\native\bin\tensorfold-native.exe" serve ^
  "%ROOT%\models\Qwen3.8-Flash-Next-FP4-Local" ^
  --name Qwen3.8-Flash-Next --host 127.0.0.1 --port %PORT% ^
  --parallel %PARALLEL% --context %CONTEXT% --prompt-cache-gib %PROMPT_CACHE_GIB% ^
  --dashboard --metrics-open
