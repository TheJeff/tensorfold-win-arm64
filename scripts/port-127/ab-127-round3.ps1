# P4 confirmation: the 8-stream decode cell at the historical 384-token reply
# length (docs/receipts/BENCH-1.2.6.md's method). The 128-token runs read -10% at 8 streams
# with huge per-stream spread; this pair decides whether that is real or a
# short-reply MTP-acceptance artifact. Keep-awake.
$root = 'C:\Projects\tensorfold-win-arm64'
$log = Join-Path $root 'logs\ab-127-round3.log'
$bash = 'C:\Program Files\Git\bin\bash.exe'
$rootF = 'C:/Projects/tensorfold-win-arm64'
$exe126 = "$rootF/tensorfold/zig-out-v126/native/bin/tensorfold-native.exe"
$exe127 = "$rootF/tensorfold/zig-out-v127/native/bin/tensorfold-native.exe"

Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(int esFlags);
'@
function Stamp { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function Run($label, $exe) {
    foreach ($n in 'KV_CACHE','PARALLEL','STREAMS','NEEDLE','TF_FLASHNEXT_PROMPT_MX128','PORT') {
        if (Test-Path "Env:$n") { Remove-Item "Env:$n" }
    }
    $env:STREAM_TOKENS = '384'
    Write-Output "=== $(Stamp) : $label (384-token replies) ==="
    & $bash "$rootF/bench/run-ab.sh" $label $exe 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log -Append
    Write-Output "=== $label rc=$LASTEXITCODE ==="
}
try {
    [Win32.Power]::SetThreadExecutionState(0x80000001) | Out-Null
    Run '1.2.6d' $exe126
    Run '1.2.7d' $exe127
    Write-Output "=== $(Stamp) : ROUND 3 DONE ==="
} finally {
    [Win32.Power]::SetThreadExecutionState(0x80000000) | Out-Null
    if (Test-Path Env:STREAM_TOKENS) { Remove-Item Env:STREAM_TOKENS }
}
