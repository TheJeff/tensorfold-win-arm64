<#
.SYNOPSIS
  Pre-flight check for a built tensorfold-native engine on this Windows ARM64 box.

.DESCRIPTION
  Run this against a CANDIDATE build before promoting it over the one you serve.
  It never touches a running server: point -Exe at a fresh tree and it checks that
  tree only.

  Four tiers, cheapest first:

    Probes  (~2 s, no GPU)   binary answers, capabilities --json parses, the chip and
                             backend are right, every optional library is where we
                             expect it, and the serve flags we depend on still exist.
    Decode  (~5 s, no GPU)   pixel-parity.py: the built decoders reproduce Pillow's
                             pixels byte for byte. This is what the version pins in
                             zig/src/core/picture exist to guarantee.
    Vision  (~20 s, no GPU)  ground-truth reading against a server that is already up:
                             five facts that exist only in the pixels, an image-vs-text
                             prompt-token delta, both decoders, and broken input
                             refused. Attached-only -- it never boots anything.
    Serve   (minutes, GPU)   boots a model and proves images survive the vision
                             tower into a reply, plus the negative cases: a JPEG with
                             no end marker and a CMYK JPEG must both be refused.
                             Holds the system awake while it runs (Modern Standby
                             mid-load bugchecks this box -- see NEXT-STEPS.md).

  FAILs are things that should stop a promotion. WARNs are known-absent optional
  pieces (video and PDF are not built) and do not fail the run.

.PARAMETER Exe
  Path to tensorfold-native.exe. Defaults to the installed 1.2.6 tree.

.PARAMETER Model
  Model directory to boot for -Tier Serve. Defaults to the spliced bf16-tower tree;
  the stock FP4-Local aborts the whole load when --vision is forced on it.

.EXAMPLE
  .\verify-engine.ps1
  Probes + Decode against the installed engine.

.EXAMPLE
  .\verify-engine.ps1 -Exe C:\...\zig-out-main\native\bin\tensorfold-native.exe -Tier All
  Full gate on a candidate build, including booting a model.

.EXAMPLE
  .\verify-engine.ps1 -Tier Serve -Model C:\...\models\Qwen3.8-Flash-Next-FP4-Local -KeepServing
  Boot it and leave it up for manual poking. Ctrl-C, then stop it yourself.

.NOTES
  Exit code is the number of FAILs, so this drops straight into a script or CI step.
#>
[CmdletBinding()]
param(
    [string] $Exe = 'C:\Projects\tensorfold-win-arm64\tensorfold\zig-out-v126\native\bin\tensorfold-native.exe',
    [string] $Model = 'C:\Projects\tensorfold-win-arm64\models\Qwen3.8-Flash-Next-FP4-Local-vision',
    [string] $Name = 'verify-engine',
    [int]    $Port = 8099,
    [ValidateSet('Probes', 'Decode', 'Serve', 'Vision', 'All')] [string] $Tier = 'Probes',
    [string] $Python = 'C:\Users\imkoa\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe',
    [string] $Config = 'C:\Projects\tensorfold-win-arm64\gui\models.json',
    [switch] $KeepServing,
    [switch] $Force,
    [string] $Attach = ''
)

$ErrorActionPreference = 'Stop'
# Keep the box awake while a model loads or a probe runs: an idle-timeout Modern
# Standby entry mid-load bugchecks this machine (0x19C WIN32K_POWER_WATCHDOG_TIMEOUT,
# the NVIDIA display-power watchdog -- observed 2026-11-18). Run on AC as well.
Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(int esFlags);
'@
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$logdir = Join-Path $root 'logs'
if (-not (Test-Path $logdir)) { New-Item -ItemType Directory -Path $logdir | Out-Null }

$fails = 0
$warns = 0
$script:last = ''

function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Pass($m, $d = '') { Write-Host ("  PASS  {0}{1}" -f $m, $(if ($d) { "  [$d]" } else { '' })) -ForegroundColor Green }
function Fail($m, $d = '') { Write-Host ("  FAIL  {0}  {1}" -f $m, $d) -ForegroundColor Red; $script:fails++ }
function Warn($m, $d = '') { Write-Host ("  WARN  {0}  {1}" -f $m, $d) -ForegroundColor Yellow; $script:warns++ }

# Optional libraries we expect, and how strict each expectation is.
#   usable  : must report usable:true
#   found   : must at least be found (some report found:true, usable:null by design)
#   absent-ok: not built on this platform yet -> WARN, never FAIL
$Expected = @(
    @{ name = 'libjpeg-turbo';    want = 'usable'; why = 'JPEG input' }
    @{ name = 'libwebp';          want = 'usable'; why = 'WebP input' }
    @{ name = 'TensorFold grammar'; want = 'found';  why = 'tool-call grammars' }
    @{ name = 'cuBLASLt';         want = 'found';  why = 'CUDA projections and vision towers' }
    @{ name = 'TensorFold video'; want = 'absent-ok'; why = 'video input' }
    @{ name = 'PDFium';           want = 'absent-ok'; why = 'PDF input' }
)

# Serve flags the fork depends on. A rename or removal upstream would break the
# launchers in serve-*.bat and gui/src/serve.zig, and this catches it at build time
# rather than at first boot.
$RequiredFlags = @('--vision', '--vision-urls', '--vision-pdf', '--vision-max-images',
                   '--vision-image-tokens', '--context', '--parallel', '--prompt-cache-gib',
                   '--dashboard', '--metrics-open', '--drafter', '--backend', '--tp')

# ------------------------------------------------------------------ Launch config
# capabilities and serve have to run in the environment the GUI actually creates,
# or Probes reports a decoder as missing when models.json would have supplied it --
# and, worse, passes when the GUI would in fact fail to find it.
Step 'Launch environment'
$entry = $null
if (Test-Path $Config) {
    $cfg = Get-Content $Config -Raw | ConvertFrom-Json
    $want = ($Model -replace '\\', '/').TrimEnd('/')
    $entry = @($cfg.models | Where-Object { ($_.dir -replace '\\', '/') -eq $want }) | Select-Object -First 1
    if ($entry) {
        Pass 'models.json entry matches -Model' ("port " + $entry.port)
        if ($entry.env) {
            foreach ($pr in $entry.env.PSObject.Properties) { Set-Item -Path "Env:$($pr.Name)" -Value $pr.Value }
            Pass 'launch env applied' (($entry.env.PSObject.Properties.Name) -join ' ')
        }
        if (@($entry.extra_args) -contains '--vision') { Pass '--vision is in extra_args' }
        else { Warn '--vision is in extra_args' 'no images on this model. Do not just add it: with an FP8 vision tower the checkpoint refuses to load at all -- see NEXT-STEPS.md "How to make images work here"' }
        if (-not $env:TENSORFOLD_LIBWEBP) {
            Fail 'models.json sets TENSORFOLD_LIBWEBP' 'webp.zig:20 has no Windows name, so the env var is the only route'
        }
    } else {
        Warn 'models.json entry matches -Model' "no entry for $Model"
    }
} else {
    Warn 'models.json readable' "$Config not found"
}
if (-not $env:TENSORFOLD_LIBWEBP) {
    $guess = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $Exe)) 'lib') 'libwebpdecoder.dll'
    if (Test-Path $guess) { $env:TENSORFOLD_LIBWEBP = $guess; Warn 'TENSORFOLD_LIBWEBP inferred from libdir for this run only' $guess }
}

# --------------------------------------------------------------------------- Probes
if ($Tier -in 'Probes', 'All') {
    Step 'Probes'

    if (-not (Test-Path $Exe)) { Fail 'engine binary exists' $Exe; exit $fails }
    Pass 'engine binary exists' (Split-Path $Exe -Leaf)

    $vtxt = (& $Exe --version) -join ''
    if ($vtxt -match '(\d+\.\d+\.\d+)') { Pass 'engine --version answers' $Matches[1] }
    else { Fail 'engine --version answers' $vtxt }

    $cap = $null
    try { $cap = (& $Exe capabilities --json) | ConvertFrom-Json } catch { Fail 'capabilities --json parses' $_.Exception.Message }
    if ($cap) {
        Pass 'capabilities --json parses' ('schema ' + $cap.schema)

        if ($cap.chip -match 'sm121') { Pass 'chip reports sm_121' $cap.chip }
        else { Fail 'chip reports sm_121' $cap.chip }

        if ($cap.backends -contains 'cuda') { Pass 'cuda backend present' ($cap.backends -join ',') }
        else { Fail 'cuda backend present' ($cap.backends -join ',') }

        Step 'Optional libraries'
        foreach ($e in $Expected) {
            $o = $cap.optional_libraries | Where-Object { $_.name -eq $e.name } | Select-Object -First 1
            if (-not $o) { Warn "library '$($e.name)' listed" 'not reported by capabilities'; continue }
            switch ($e.want) {
                'usable'    { if ($o.usable -eq $true) { Pass "$($e.name) usable ($($e.why))" "soname $($o.soname)" }
                              else { Fail "$($e.name) usable ($($e.why))" ("found=" + $o.found + '  ' + $o.problem) } }
                'found'     { if ($o.found -eq $true) { Pass "$($e.name) found ($($e.why))" $o.soname }
                              else { Fail "$($e.name) found ($($e.why))" $o.problem } }
                'absent-ok' { if ($o.found -eq $true) { Pass "$($e.name) found ($($e.why))" $o.soname }
                              else { Warn "$($e.name) not built ($($e.why))" 'known gap -- see NEXT-STEPS.md' } }
            }
        }

        Step 'Serve flags'
        $have = @($cap.serve.flags.PSObject.Properties.Name)
        $missing = @($RequiredFlags | Where-Object { $_ -notin $have })
        if ($missing.Count -eq 0) { Pass 'every required serve flag exists' ($have.Count.ToString() + ' advertised') }
        else { Fail 'every required serve flag exists' ('missing ' + ($missing -join ' ')) }
    }
}

# --------------------------------------------------------------------------- Decode
if ($Tier -in 'Decode', 'All') {
    Step 'Decode (pixel parity vs Pillow)'
    $libdir = Join-Path (Split-Path -Parent (Split-Path -Parent $Exe)) 'lib'
    if (-not (Test-Path $Python)) { Warn 'python for pixel-parity' "$Python not found -- skipping" }
    elseif (-not (Test-Path (Join-Path $PSScriptRoot 'pixel-parity.py'))) { Fail 'pixel-parity.py present' }
    else {
        # -I isolates the interpreter from ambient PYTHONPATH: a foreign venv's broken
        # PIL otherwise hijacks the import and fails the tier for a non-engine reason.
        & $Python -I -u (Join-Path $PSScriptRoot 'pixel-parity.py') --libdir $libdir --fixtures $fixtures
        if ($LASTEXITCODE -eq 0) { Pass 'pixel parity' $libdir }
        else { Fail 'pixel parity' "exit $LASTEXITCODE" }
    }
}

# ---------------------------------------------------------------------------- Serve
if ($Tier -in 'Serve', 'Vision', 'All') {
    # -Attach runs the same assertions against a server someone else started -- the
    # GUI's, for instance. Useful and safer: it proves what is running without putting
    # the GPU through a reload. The GPU guards below only apply when we boot our own.
    $launched = $false
    $p = $null
    if ($Tier -eq 'Vision' -and -not $Attach) {
        Fail 'Vision tier needs a server to talk to' 'pass -Attach http://127.0.0.1:PORT, or use -Tier Serve to boot one'
        exit $fails
    }
    if ($Attach) {
        Step "$(if ($Tier -eq 'Vision') { 'Vision' } else { 'Serve' }) (attached to $Attach)"
    } else {
        Step 'Serve (needs the GPU and a few minutes)'
        if (-not (Test-Path $Model)) { Fail 'model directory exists' $Model; exit $fails }

    # An engine already holding the GPU makes this fail as CUDA_ERROR_OUT_OF_MEMORY
    # partway through loading, which reads like a broken build. On this 98 GiB box one
    # loaded Qwen takes ~80 GiB, so a second copy cannot fit. Refuse rather than
    # misreport -- -Force still allows a deliberate double-boot.
    $busy = @(Get-Process tensorfold-native -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0 -and -not $Force) {
        Warn 'no other engine on the GPU' ("pid(s) " + (($busy | ForEach-Object Id) -join ', ') + ' already running')
        Warn 'Serve tier skipped' 'stop the running server or pass -Force; Probes+Decode still cover the decoders'
        Step 'Result'
        Write-Host ("  {0} failed, {1} warned" -f $fails, $warns) -ForegroundColor $(if ($fails) { 'Red' } else { 'Green' })
        exit $fails
    }
    $free = $null
    try { $free = [int]((nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) | Select-Object -First 1) } catch {}
    if ($free -and $free -lt 32768 -and -not $Force) {
        Warn 'enough free VRAM to boot' ("only $free MiB free")
        Warn 'Serve tier skipped' 'pass -Force to try anyway'
        Step 'Result'
        Write-Host ("  {0} failed, {1} warned" -f $fails, $warns) -ForegroundColor $(if ($fails) { 'Red' } else { 'Green' })
        exit $fails
    }
    if ($free) { Pass 'enough free VRAM to boot' ("$free MiB free") }

    $env:TENSORFOLD_LIBWEBP = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $Exe)) 'lib') 'libwebpdecoder.dll'
    $env:TENSORFOLD_NO_UPDATE_CHECK = '1'
    $log = Join-Path $logdir ("verify-{0}-{1:yyyyMMdd-HHmmss}.log" -f $Name, (Get-Date))
    # Start-Process refuses when both redirects name the same file, so stderr gets its
    # own; the engine writes startup noise to stdout and real faults to stderr.
    $errlog = $log -replace '\.log$', '.err.log'

    # Start-Process joins -ArgumentList with spaces and does NOT quote elements that
    # contain spaces, so a model name like "Qwen3.8 Flash Next FP4 Local" arrives as
    # four arguments and argparse rejects it. Quote it ourselves.
    $p = Start-Process -FilePath $Exe -PassThru -WindowStyle Hidden `
        -ArgumentList @('serve', "`"$Model`"", '--name', "`"$Name`"", '--host', '127.0.0.1', '--port', $Port,
                        '--context', '8192', '--parallel', '1', '--prompt-cache-gib', '2', '--vision') `
        -RedirectStandardOutput $log -RedirectStandardError $errlog

    Write-Host "  waiting for :$Port (log $log)" -ForegroundColor DarkGray
    $ready = $false
    for ($i = 0; $i -lt 180; $i++) {
        Start-Sleep -Seconds 2
        if ($p.HasExited) { break }
        try {
            $m = Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 3
            if ($m.data.Count -ge 1) { $ready = $true; break }
        } catch {}
    }
    if (-not $ready) {
        Fail 'server became ready' $(if ($p.HasExited) { "exited code $($p.ExitCode)" } else { 'timeout after 360 s' })
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        Write-Host "`n  --- last 25 stdout lines ---" -ForegroundColor DarkGray
        Get-Content $log -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { "  $_" }
        Write-Host "  --- last 25 stderr lines ---" -ForegroundColor DarkGray
        Get-Content $errlog -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { "  $_" }
        exit $fails
    }
        Pass 'server became ready' ("{0}s" -f (2 * $i))
        $launched = $true
    }

    $baseUrl = if ($Attach) { $Attach.TrimEnd('/') } else { "http://127.0.0.1:$Port" }
    # Take the id from the server rather than trusting -Name: an attached server was
    # started by the GUI with whatever name models.json produced.
    $modelId = $Name
    try { $modelId = (Invoke-RestMethod "$baseUrl/v1/models" -TimeoutSec 10).data[0].id } catch {}
    Pass 'model id resolved' $modelId

    function Chat($content, $max = 48, $Extra = @{}) {
        $body = @{ model = $modelId; messages = @(@{ role = 'user'; content = $content }); max_tokens = $max; temperature = 0 }
        foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] }
        Invoke-RestMethod "$baseUrl/v1/chat/completions" -Method Post -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 8) -TimeoutSec 300
    }
    # This checkpoint thinks by default, and max_tokens counts reasoning *and* the
    # answer, so a small budget comes back with content empty and the text in
    # reasoning_content -- the server logs exactly this: "a reply reached max_tokens
    # while still thinking ... send chat_template_kwargs {"enable_thinking": false}".
    # Image assertions want the answer, so they ask for it without the detour.
    $NoThink = @{ chat_template_kwargs = @{ enable_thinking = $false } }
    function ImageContent($file, $mime, $prompt) {
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
        @(@{ type = 'text'; text = $prompt },
          @{ type = 'image_url'; image_url = @{ url = "data:$mime;base64,$b64" } })
    }

    try {
        # Hold the system and display awake for the whole assertion run (see Add-Type
        # above). Inside the try so any fault still reaches the finally's cleanup.
        # int, not uint: PowerShell wraps 0x80000003 to a negative Int32 literal.
        [Win32.Power]::SetThreadExecutionState(0x80000003) | Out-Null
        # A thinking model spends the budget on reasoning first, so content can come
        # back empty while the text is in reasoning_content. Assert against either.
        $r = Chat 'Reply with exactly the word READY.' 64
        $txt = [string]$r.choices[0].message.content
        if (-not $txt) { $txt = [string]$r.choices[0].message.reasoning_content }
        if ($txt -and $txt -match 'READY') { Pass 'text completion round-trips' (($txt -replace '\s+', ' ').Trim()) }
        else {
            $raw = (($r | ConvertTo-Json -Depth 6 -Compress) -replace '\s+', ' ')
            if ($raw.Length -gt 300) { $raw = $raw.Substring(0, 300) + '…' }
            Fail 'text completion round-trips' "no READY in content/reasoning_content; raw=$raw"
        }

        # Negative assertions below are only meaningful if a valid image actually
        # decoded. With --vision off every image request is a 400, which would make
        # the refusal tests "pass" for completely the wrong reason.
        $imagesWorked = $true
        foreach ($f in @(@{ file = 'photo.jpg'; mime = 'image/jpeg'; ask = 'What is the single most prominent colour? Answer in one word.' },
                        @{ file = 'photo.webp'; mime = 'image/webp'; ask = 'What is the single most prominent colour? Answer in one word.' },
                        @{ file = 'photo_lossless.webp'; mime = 'image/webp'; ask = 'What is the single most prominent colour? Answer in one word.' })) {
            $path = Join-Path $fixtures $f.file
            if (-not (Test-Path $path)) { Fail "$($f.file) fixture exists"; $imagesWorked = $false; continue }
            try {
                $r = Chat (ImageContent $path $f.mime $f.ask) 64 $NoThink
                $txt = ([string]$r.choices[0].message.content -replace '\s+', ' ').Trim()
                if ($txt.Length -gt 0) { Pass "$($f.file) decoded and answered" $txt }
                else {
                    # Content empty with thinking off is a genuine failure; if the text
                    # landed in reasoning_content anyway, say so rather than reporting a
                    # bare "empty reply" that looks like a decoder problem.
                    $rc = ([string]$r.choices[0].message.reasoning_content).Trim()
                    $hint = if ($rc) { "content empty but reasoning_content said: $rc" } else { 'empty reply' }
                    Fail "$($f.file) decoded and answered" $hint; $imagesWorked = $false
                }
            } catch { Fail "$($f.file) decoded and answered" $_.Exception.Message; $imagesWorked = $false }
        }

        # Negative cases: these must NOT be accepted. jpeg.zig refuses a JPEG with no
        # end marker (line 158) and a 4-component JPEG (line 157); webp.zig must reject
        # data WebPGetInfo will not parse. Silently decoding these is a real defect.
        foreach ($neg in @(@{ file = 'truncated.jpg'; mime = 'image/jpeg'; why = 'no EOI marker' },
                          @{ file = 'cmyk.jpg';        mime = 'image/jpeg'; why = 'CMYK, 4 components' },
                          @{ file = 'corrupt.webp';    mime = 'image/webp'; why = 'not a WebP' })) {
            $path = Join-Path $fixtures $neg.file
            if (-not (Test-Path $path)) { Fail "$($neg.file) fixture exists"; continue }
            if (-not $imagesWorked) {
                Warn "$($neg.file) refused ($($neg.why))" 'not assessed -- no valid image decoded, so a 400 here only proves vision is off'
                continue
            }
            try {
                $r = Chat (ImageContent $path $neg.mime 'Describe this.') 32 $NoThink
                Fail "$($neg.file) refused ($($neg.why))" ('accepted, said: ' + [string]$r.choices[0].message.content)
            } catch {
                # Only HTTP 400 counts as a refusal: a 500 or a timeout would mean the
                # decoder crashed or the server died -- a defect, not a pass.
                $sc = 0
                if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode }
                if ($sc -eq 400) { Pass "$($neg.file) refused ($($neg.why))" 'HTTP 400' }
                else { Fail "$($neg.file) refused with 400 ($($neg.why))" ("HTTP $sc " + ($_.Exception.Message -replace '\s+', ' ')) }
            }
        }
        # Ground truth. Fluent prose proves nothing -- a model that ignored the image
        # would still describe one -- so this asks questions whose answers exist only in
        # the pixels, drawn by the code that knows the answers, and asserts that an image
        # prompt actually costs more tokens than the same prompt without one.
        $probe = Join-Path $PSScriptRoot 'vision-probe.py'
        if (-not (Test-Path $probe)) { Fail 'vision-probe.py present' }
        elseif (-not (Test-Path $Python)) { Warn 'python for vision-probe' "$Python not found -- skipping" }
        elseif (-not $imagesWorked) { Warn 'vision probe' 'skipped -- no valid image decoded' }
        else {
            & $Python -I -u $probe --url $baseUrl --fixtures $fixtures `
                --card-out (Join-Path $logdir 'vision-card.png')
            if ($LASTEXITCODE -eq 0) { Pass 'vision probe (ground truth)' '5 facts, token delta, 3 refusals' }
            else { Fail 'vision probe (ground truth)' "exit $LASTEXITCODE -- see the lines above" }
        }
    } finally {
        [Win32.Power]::SetThreadExecutionState(0x80000000) | Out-Null
        if (-not $launched) { Write-Host '  attached server left running (we did not start it)' -ForegroundColor DarkGray }
        elseif ($KeepServing) { Write-Host "  left running on :$Port (pid $($p.Id))" -ForegroundColor Yellow }
        elseif (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Write-Host '  server stopped' -ForegroundColor DarkGray }
    }
}

# ------------------------------------------------------------------------------ end
Step 'Result'
Write-Host ("  {0} failed, {1} warned" -f $fails, $warns) -ForegroundColor $(if ($fails) { 'Red' } else { 'Green' })
if ($fails -and $Tier -ne 'Serve') { Write-Host '  note: Probes+Decode never boot a model; use -Tier Serve for the full gate.' -ForegroundColor DarkGray }
exit $fails
