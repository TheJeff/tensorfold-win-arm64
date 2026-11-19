# Bolt lane + tfgrammar check on the promoted v127 install: boot serve-bolt.bat,
# prove a chat reply and a strict json_schema reply, stop. Keep-awake (GPU load).
$root = 'C:\Projects\tensorfold-win-arm64'
$log = Join-Path $root 'logs\bolt-check-127.log'
Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(int esFlags);
'@
$code = 1
try {
    [Win32.Power]::SetThreadExecutionState(0x80000001) | Out-Null
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$root\serve-bolt.bat`"" -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 2
        if ($p.HasExited) { break }
        # /v1/models answers before the load finishes; the engine's own serving line is ready.
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'serving Nemotron-3.5-Bolt' -Quiet)) { $ready = $true; break }
    }
    if (-not $ready) { Write-Output "BOLT BOOT FAILED (see $log)"; Get-Content $log -Tail 12; $code = 1 }
    else {
        Write-Output "bolt ready after ~$(2*$i)s"
        $id = (Invoke-RestMethod 'http://127.0.0.1:8082/v1/models').data[0].id
        $body = @{ model = $id; messages = @(@{ role='user'; content='Say hello in one sentence.' }); max_tokens = 128; temperature = 0;
                   chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 6
        $r = Invoke-RestMethod 'http://127.0.0.1:8082/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 120
        Write-Output ("chat: " + $r.choices[0].message.content)
        $schema = @{ type='object'; properties=@{ answer=@{ type='integer' } }; required=@('answer'); additionalProperties=$false }
        $body2 = @{ model = $id; messages = @(@{ role='user'; content='What is 2+2? Respond in JSON.' }); max_tokens = 128; temperature = 0;
                    chat_template_kwargs = @{ enable_thinking = $false };
                    response_format = @{ type='json_schema'; json_schema = @{ name='sum'; strict=$true; schema=$schema } } } | ConvertTo-Json -Depth 8
        $r2 = Invoke-RestMethod 'http://127.0.0.1:8082/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $body2 -TimeoutSec 120
        $j = $r2.choices[0].message.content | ConvertFrom-Json
        if ($j.answer -eq 4) { Write-Output "json_schema: PASS (answer=4)"; $code = 0 }
        else { Write-Output "json_schema: FAIL ($($r2.choices[0].message.content))"; $code = 1 }
    }
} finally {
    [Win32.Power]::SetThreadExecutionState(0x80000000) | Out-Null
    Stop-Process -Name tensorfold-native -Force -ErrorAction SilentlyContinue
    Write-Output 'bolt server stopped'
}
exit $code
