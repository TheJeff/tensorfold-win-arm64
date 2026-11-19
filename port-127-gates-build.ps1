# P1 host gates + P2 build for win-arm64/v1.2.7, in one keep-awake job.
# This WoA box bugchecks (0x19C) when idle-timeout Modern Standby lands mid-load, so
# hold ES_SYSTEM_REQUIRED for the whole run (the verify-engine.ps1 pattern: int, not
# uint - PowerShell wraps 0x80000001 to a negative Int32 that cannot marshal to UInt32).
# Gates first; the build only starts if all three pass. Log: logs\port-127-gates-build.log.
$root = 'C:\Projects\tensorfold-win-arm64'
$log = Join-Path $root 'logs\port-127-gates-build.log'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null

Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(int esFlags);
'@

function Stamp { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
$code = 1
try {
    # Inside the try so any fault still reaches the finally that restores the state.
    [Win32.Power]::SetThreadExecutionState(0x80000001) | Out-Null

    Write-Output "=== $(Stamp) : P1 host gates (win-arm64/v1.2.7) ==="
    & "$root\host-gates-127.bat" 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) {
        Write-Output "GATES FAILED ($LASTEXITCODE) - build not started"
        $code = $LASTEXITCODE
    } else {
        Write-Output "=== $(Stamp) : P2 build -> zig-out-v127 ==="
        & "$root\build-bolt-127.bat" 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log -Append
        $code = $LASTEXITCODE
        if ($code -eq 0) { Write-Output "=== $(Stamp) : BUILD OK ===" }
        else { Write-Output "=== $(Stamp) : BUILD FAILED ($code) ===" }
    }
} finally {
    [Win32.Power]::SetThreadExecutionState(0x80000000) | Out-Null
}
exit $code
