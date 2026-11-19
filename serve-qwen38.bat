@echo off
setlocal
rem Serve Qwen3.8 Flash Next (nvidia/Qwen3.8-Flash-Next-FP4-Local) on this N1X.
rem TensorFold 1.2.7 (win-arm64/v1.2.7 + MiaAI-Lab patches 0001-0005): the stock
rem checkpoint's quantised vision tower decodes to bf16 at load (0001), so --vision
rem works without the splice. KV stays bf16 by default; KV_CACHE=fp8 (0003) admits
rem 5 full 262k streams vs bf16's 3 — opt-in, lossy (~98.8% top-1 agreement).
rem Settings mirror MiaAI-Lab's single-Spark recipe, scaled to this 96 GiB box.

if "%PARALLEL%"=="" set "PARALLEL=2"
if "%CONTEXT%"=="" set "CONTEXT=262144"
if "%PROMPT_CACHE_GIB%"=="" set "PROMPT_CACHE_GIB=4"
if "%PORT%"=="" set "PORT=8083"
if "%KV_CACHE%"=="" set "KV_CACHE=bf16"

set "ROOT=C:\Projects\tensorfold-win-arm64"
set "TENSORFOLD_MEMORY_RESERVE_GIB=4"
set "TF_FLASHNEXT_DRAFTS=6"
set "TF_FLASHNEXT_GATHER_READ=pread"
set "TENSORFOLD_NO_UPDATE_CHECK=1"

"%ROOT%\tensorfold\zig-out-v127\native\bin\tensorfold-native.exe" serve ^
  "%ROOT%\models\Qwen3.8-Flash-Next-FP4-Local" ^
  --name Qwen3.8-Flash-Next --host 127.0.0.1 --port %PORT% ^
  --parallel %PARALLEL% --context %CONTEXT% --prompt-cache-gib %PROMPT_CACHE_GIB% ^
  --kv-cache %KV_CACHE% ^
  --dashboard --metrics-open
