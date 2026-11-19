# P4: v1.2.6 vs v1.2.7(+mia 0001-0005) A/B, warm-cache method per docs/receipts/BENCH-1.2.6.md.
# Alternate builds, discard the first pair, score the second. Then the 0004
# isolation run (TF_FLASHNEXT_PROMPT_MX128=0), the bf16x3 admission refusal probe,
# the fp8x3 bench+needle, and a bf16 single-stream needle baseline.
# Holds ES_SYSTEM_REQUIRED for the whole sequence (GPU loads; WoA standby hazard).
$root = 'C:\Projects\tensorfold-win-arm64'
$log = Join-Path $root 'logs\ab-127.log'
$bash = 'C:\Program Files\Git\bin\bash.exe'
# bash eats backslashes as escapes: script and exe arguments go forward-slashed.
$rootF = 'C:/Projects/tensorfold-win-arm64'
$exe126 = "$rootF/tensorfold/zig-out-v126/native/bin/tensorfold-native.exe"
$exe127 = "$rootF/tensorfold/zig-out-v127/native/bin/tensorfold-native.exe"

Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(int esFlags);
'@

function Stamp { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function Clear-RunEnv {
    foreach ($n in 'KV_CACHE','PARALLEL','STREAMS','NEEDLE','TF_FLASHNEXT_PROMPT_MX128','PORT') {
        if (Test-Path "Env:$n") { Remove-Item "Env:$n" }
    }
}
function Run($label, $script, $exe, $extra) {
    Clear-RunEnv
    foreach ($k in $extra.Keys) { Set-Item -Path "Env:$k" -Value $extra[$k] }
    Write-Output "=== $(Stamp) : $label ==="
    & $bash "$rootF/bench/$script" $label $exe 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log -Append
    Write-Output "=== $label rc=$LASTEXITCODE ==="
}

try {
    [Win32.Power]::SetThreadExecutionState(0x80000001) | Out-Null
    Run '1.2.6a'        'run-ab.sh'     $exe126 @{}
    Run '1.2.7a'        'run-ab.sh'     $exe127 @{}
    Run '1.2.6b'        'run-ab.sh'     $exe126 @{}
    Run '1.2.7b'        'run-ab.sh'     $exe127 @{}
    Run '1.2.7-mx0'     'run-ab.sh'     $exe127 @{ TF_FLASHNEXT_PROMPT_MX128 = '0' }
    Run '1.2.7-bf16x3'  'boot-probe.sh' $exe127 @{ KV_CACHE = 'bf16'; PARALLEL = '3' }   # expect rc=2 (refused)
    Run '1.2.7-fp8x3'   'run-ab.sh'     $exe127 @{ KV_CACHE = 'fp8'; PARALLEL = '3'; STREAMS = '1,3'; NEEDLE = '1' }
    Run '1.2.7-bf16n'   'run-ab.sh'     $exe127 @{ PARALLEL = '1'; STREAMS = '1'; NEEDLE = '1' }
    Write-Output "=== $(Stamp) : P4 SEQUENCE DONE ==="
} finally {
    [Win32.Power]::SetThreadExecutionState(0x80000000) | Out-Null
    Clear-RunEnv
}
