# P4 round 2: the scored pairs (b, c) after the discarded warm-up pair (a), the
# 0004 isolation run, and the fp8 x5 full-window admission probe. run-ab.sh now
# waits out the stale LISTENING entry (the round-1 loss). Keep-awake throughout.
$root = 'C:\Projects\tensorfold-win-arm64'
$log = Join-Path $root 'logs\ab-127-round2.log'
$bash = 'C:\Program Files\Git\bin\bash.exe'
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
    Run '1.2.6b'       'run-ab.sh'     $exe126 @{}
    Run '1.2.7b'       'run-ab.sh'     $exe127 @{}
    Run '1.2.6c'       'run-ab.sh'     $exe126 @{}
    Run '1.2.7c'       'run-ab.sh'     $exe127 @{}
    Run '1.2.7-mx0'    'run-ab.sh'     $exe127 @{ TF_FLASHNEXT_PROMPT_MX128 = '0' }
    Run '1.2.7-fp8x5'  'boot-probe.sh' $exe127 @{ KV_CACHE = 'fp8'; PARALLEL = '5' }
    Write-Output "=== $(Stamp) : ROUND 2 DONE ==="
} finally {
    [Win32.Power]::SetThreadExecutionState(0x80000000) | Out-Null
    Clear-RunEnv
}
