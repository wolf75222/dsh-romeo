# Native Windows entry point. Windows PowerShell 5.1 and PowerShell 7.
# Dot-source to load functions without running a command.
$script:DshRoot = Split-Path -Parent $PSScriptRoot
$script:DshVersion = '0.1.0'

function Write-DshMessage([string]$Message) { [Console]::Error.WriteLine("dsh-romeo $Message") }
function Write-DshFile([string]$Path, [string]$Text) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Initialize-Dsh([hashtable]$Overrides = @{}) {
    $script:DshExitCode = 0
    $script:DshConfigDir = $env:DSH_ROMEO_CONFIG_DIR
    if (-not $script:DshConfigDir) {
        $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
        $script:DshConfigDir = Join-Path $base 'dsh-romeo'
    }
    $script:DshConfigDir = [IO.Path]::GetFullPath($script:DshConfigDir)
    $script:DshSettings = [ordered]@{
        ROMEO_SSH_HOST = 'romeo'; ROMEO_PROJECT = ''
        DSH_ROMEO_FICHE = 'dsh-deepseek-v4.1-flash-1017-1m'; DSH_ROMEO_TIME = '08:00:00'
        DSH_ROMEO_PORT = '11318'; DSH_ROMEO_EFFORT = 'max'; DSH_ROMEO_SEARXNG_URL = ''
        DSH_ROMEO_GATEWAY = 'standard'; DSH_ROMEO_FAST_PORT = '11320'; DSH_ROMEO_FAST_PROCS = '4'
        ROMEOLLMTOOL = '/apps/romeotools/romeollmtool/romeollmtool'; DSH_ROMEO_DSH = 'dsh'
        DSH_ROMEO_POLL = '15'
    }
    $file = Join-Path $script:DshConfigDir 'config.json'
    $saved = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json }
    foreach ($key in @($script:DshSettings.Keys)) {
        if ($saved -and $saved.PSObject.Properties[$key]) { $script:DshSettings[$key] = [string]$saved.$key }
        $value = [Environment]::GetEnvironmentVariable($key)
        if ($null -ne $value) { $script:DshSettings[$key] = $value }
        if ($Overrides.ContainsKey($key)) { $script:DshSettings[$key] = [string]$Overrides[$key] }
    }
    $s = $script:DshSettings
    if ($s.ROMEO_SSH_HOST -notmatch '^(?!-)[a-zA-Z0-9_.@:-]+$') { throw 'invalid ROMEO_SSH_HOST' }
    if ($s.DSH_ROMEO_FICHE -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'invalid DSH_ROMEO_FICHE' }
    if ($s.ROMEO_PROJECT -and $s.ROMEO_PROJECT -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'invalid ROMEO_PROJECT' }
    foreach ($key in @('DSH_ROMEO_PORT', 'DSH_ROMEO_FAST_PORT')) {
        if ($s[$key] -notmatch '^\d{1,5}$' -or [int]$s[$key] -lt 1 -or [int]$s[$key] -gt 65535) { throw "invalid $key" }
    }
    if ($s.DSH_ROMEO_FAST_PROCS -notmatch '^[1-9][0-9]*$') { throw 'invalid DSH_ROMEO_FAST_PROCS' }
    if ($s.DSH_ROMEO_POLL -notmatch '^\d+(\.\d+)?$' -or [double]$s.DSH_ROMEO_POLL -le 0) { throw 'invalid DSH_ROMEO_POLL' }
    if ($s.DSH_ROMEO_EFFORT -notin @('none', 'low', 'high', 'max')) { throw 'invalid DSH_ROMEO_EFFORT' }
    if ($s.DSH_ROMEO_GATEWAY -notin @('standard', 'fast')) { throw 'invalid DSH_ROMEO_GATEWAY' }
    if ($s.DSH_ROMEO_TIME -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$|^24:00:00$') { throw 'invalid DSH_ROMEO_TIME' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $id = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($s.ROMEO_SSH_HOST):$($s.DSH_ROMEO_PORT)"))).Replace('-', '').Substring(0, 16) }
    finally { $hash.Dispose() }
    $script:DshTunnelFile = Join-Path $script:DshConfigDir "tunnel-$id.json"
}
function ConvertTo-DshPosixQuote([string]$Value) { "'" + $Value.Replace("'", "'\''") + "'" }

# Preserve each argument, including embedded quotes and trailing backslashes.
function ConvertTo-DshWindowsArgument([AllowEmptyString()][string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Get-DshSshPath {
    $command = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw 'OpenSSH Client is missing. Install it in Windows Optional Features.' }
    $command.Source
}
function Invoke-DshSsh([string]$Command, [string]$InputText = '') {
    $arguments = @('-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20')
    if (-not $InputText) { $arguments += '-n' }
    $arguments += @($script:DshSettings.ROMEO_SSH_HOST, $Command)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Get-DshSshPath
    $info.Arguments = ($arguments | ForEach-Object { ConvertTo-DshWindowsArgument $_ }) -join ' '
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8; $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $stdinEncoding = New-Object Text.UTF8Encoding($false)
    $hasStdinEncoding = $null -ne $info.PSObject.Properties['StandardInputEncoding']
    if ($hasStdinEncoding) { $info.StandardInputEncoding = $stdinEncoding }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if ($hasStdinEncoding) { [void]$process.Start() }
        else {
            # .NET Framework has no StandardInputEncoding property. It constructs
            # its stdin writer from Console.InputEncoding, including any BOM.
            $previousEncoding = [Console]::InputEncoding
            try { [Console]::InputEncoding = $stdinEncoding; [void]$process.Start() }
            finally { [Console]::InputEncoding = $previousEncoding }
        }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close(); $process.WaitForExit()
        $outputText = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $failure = New-Object InvalidOperationException("SSH command failed on '$($script:DshSettings.ROMEO_SSH_HOST)' (exit $($process.ExitCode)): $errorText")
            $failure.Data['ExitCode'] = $process.ExitCode
            throw $failure
        }
        $outputText.TrimEnd()
    } finally { $process.Dispose() }
}
function Connect-Dsh {
    try { Invoke-DshSsh 'true' | Out-Null }
    catch { throw "cannot connect to '$($script:DshSettings.ROMEO_SSH_HOST)' over SSH. Check: ssh $($script:DshSettings.ROMEO_SSH_HOST) hostname. $_" }
}
function Invoke-DshRlt([string[]]$Arguments) {
    $parts = @($script:DshSettings.ROMEOLLMTOOL) + $Arguments
    Invoke-DshSsh (($parts | ForEach-Object { ConvertTo-DshPosixQuote $_ }) -join ' ')
}
function Get-DshGatewayUrl {
    try { $text = Invoke-DshRlt @('gateway', 'status') }
    catch {
        # romeollmtool returns 1 when no gateway is running. SSH transport errors
        # (notably 255) must still propagate instead of looking like a stopped gateway.
        if ($_.Exception.Data['ExitCode'] -eq 1) { return }
        throw
    }
    if ($text -match 'https?://[^\s]+:\d+/v1') { $Matches[0] }
}
function Get-DshJobs {
    $name = ConvertTo-DshPosixQuote "romeollmtool-$($script:DshSettings.DSH_ROMEO_FICHE)"
    $text = Invoke-DshSsh ('squeue -u "$USER" -h -n ' + $name + " -o '%i %T %M %L %r'")
    @($text -split '\r?\n' | Where-Object { $_.Trim() })
}
function Read-DshFiche {
    $fiche = $script:DshSettings.DSH_ROMEO_FICHE
    try { $show = Invoke-DshRlt @('catalog', 'show', $fiche) } catch { $show = '' }
    if ($show -notmatch '(?m)^vllm:') { throw "fiche '$fiche' not found on ROMEO. Run: dsh-romeo --setup" }
    $section = ''; $served = ''; $model = ''; $context = 262144; $tokens = 65536; $nextContext = $false
    foreach ($line in ($show -split '\r?\n')) {
        if ($line -match '^([^\s#][^:]*):') { $section = $Matches[1]; $nextContext = $false }
        if ($section -eq 'vllm') {
            if ($line -match '^  served_model_name:\s*(.+?)\s*$') { $served = $Matches[1].Trim("'`"") }
            if ($line -match '^  model:\s*(.+?)\s*$') { $model = $Matches[1].Trim("'`"") }
            if ($nextContext -and $line -match '^\s*-?\s*[''"]?(\d+)') { $context = [int]$Matches[1]; $nextContext = $false }
            if ($line -match '--max-model-len') { $nextContext = $true }
        }
        if ($section -eq 'generation' -and $line -match '^  max_tokens:\s*[''"]?(\d+)') { $tokens = [int]$Matches[1] }
    }
    $script:DshModel = if ($served) { $served } else { $model }
    if (-not $script:DshModel) { throw "cannot read the served model name of fiche '$fiche'" }
    $script:DshContext = $context; $script:DshMaxTokens = $tokens
}
function Send-DshFile([string]$LocalPath, [string]$RemotePath, [switch]$Executable) {
    # ASCII transport avoids Windows PowerShell's legacy stdin encodings.
    $command = "base64 -d > $RemotePath"
    if ($Executable) { $command += " && chmod +x $RemotePath" }
    Invoke-DshSsh $command ([Convert]::ToBase64String([IO.File]::ReadAllBytes($LocalPath))) | Out-Null
}
function Set-DshFiches {
    Connect-Dsh
    Invoke-DshSsh 'mkdir -p ~/.romeollmtool/configs' | Out-Null
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:DshRoot 'share/fiches') -Filter '*.yaml')) {
        Send-DshFile $file.FullName ("~/.romeollmtool/configs/" + (ConvertTo-DshPosixQuote $file.Name))
        Write-DshMessage "fiche $($file.BaseName) installed in ~/.romeollmtool/configs on ROMEO"
    }
    Invoke-DshRlt @('version') | Out-Null
}
function Set-DshFastGateway {
    $dir = '~/.dsh-romeo/gateway'
    Invoke-DshSsh "mkdir -p $dir" | Out-Null
    Send-DshFile (Join-Path $script:DshRoot 'share/gateway/sitecustomize.py') "$dir/sitecustomize.py"
    Send-DshFile (Join-Path $script:DshRoot 'share/gateway/start.sh') "$dir/start.sh" -Executable
    try {
        $tool = ConvertTo-DshPosixQuote $script:DshSettings.ROMEOLLMTOOL
        Invoke-DshSsh "ROMEOLLMTOOL=$tool $dir/start.sh $($script:DshSettings.DSH_ROMEO_FAST_PORT) $($script:DshSettings.DSH_ROMEO_FAST_PROCS)" | Out-Null
        $script:DshGateway = "http://localhost:$($script:DshSettings.DSH_ROMEO_FAST_PORT)/v1"
        Write-DshMessage 'fast gateway running'
    } catch { Write-DshMessage "fast gateway unavailable, using the standard gateway: $_" }
}
function Test-DshPort([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try { $task = $client.ConnectAsync('127.0.0.1', $Port); [void]$task.Wait(500); $client.Connected }
    catch { $false } finally { $client.Dispose() }
}
function Get-DshTunnelState {
    if (Test-Path -LiteralPath $script:DshTunnelFile) { Get-Content -LiteralPath $script:DshTunnelFile -Raw -Encoding UTF8 | ConvertFrom-Json }
}
function Get-DshTunnelProcess($State) {
    $process = Get-Process -Id $State.Id -ErrorAction SilentlyContinue
    if (-not $process) { return }
    # A PID alone is insufficient: never terminate an unrelated or reused process.
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
    if ($State.Version -ne 1 -or $process.StartTime.ToUniversalTime().Ticks.ToString() -ne $State.StartTicks -or
        $process.Path -ne $State.Executable -or $cim.CommandLine -cne $State.CommandLine -or
        [IO.Path]::GetFileName($process.Path) -ine 'ssh.exe') {
        throw "tunnel process identity changed; refusing to stop PID $($process.Id). State: $script:DshTunnelFile"
    }
    $process
}
function Invoke-DshTunnelLocked([scriptblock]$Action) {
    $name = 'Local\dsh-romeo-' + [IO.Path]::GetFileNameWithoutExtension($script:DshTunnelFile)
    $mutex = New-Object Threading.Mutex($false, $name)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'another dsh-romeo command is changing this tunnel; try again' }
        & $Action
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Stop-DshTunnel { Invoke-DshTunnelLocked { Stop-DshTunnelCore } }
function Stop-DshTunnelCore {
    $state = Get-DshTunnelState
    if (-not $state) { return }
    $process = Get-DshTunnelProcess $state
    if ($process) { Stop-Process -InputObject $process -ErrorAction Stop; $process.WaitForExit() }
    Remove-Item -LiteralPath $script:DshTunnelFile -ErrorAction SilentlyContinue
}
function Open-DshTunnel { Invoke-DshTunnelLocked { Open-DshTunnelCore } }
function Open-DshTunnelCore {
    $uri = [Uri]$script:DshGateway
    if ($uri.Scheme -ne 'http' -or $uri.AbsolutePath -ne '/v1') { throw "unsupported gateway URL: $script:DshGateway" }
    $targetHost = $uri.DnsSafeHost
    if ($targetHost.Contains(':')) { $targetHost = "[$targetHost]" }
    $target = "${targetHost}:$($uri.Port)"
    $state = Get-DshTunnelState
    if ($state) {
        $process = Get-DshTunnelProcess $state
        if ($process -and $state.Target -eq $target -and (Test-DshPort ([int]$script:DshSettings.DSH_ROMEO_PORT))) { return }
        Stop-DshTunnelCore
    }
    $port = [int]$script:DshSettings.DSH_ROMEO_PORT
    if (Test-DshPort $port) { throw "cannot forward 127.0.0.1:$port (another program uses it? set DSH_ROMEO_PORT)" }
    [IO.Directory]::CreateDirectory($script:DshConfigDir) | Out-Null
    $arguments = @('-N', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=4', '-L', "127.0.0.1:${port}:$target", $script:DshSettings.ROMEO_SSH_HOST)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-DshWindowsArgument $_ }) -join ' '
    $log = "$script:DshTunnelFile.log"
    $process = Start-Process -FilePath (Get-DshSshPath) -ArgumentList $argumentLine -WindowStyle Hidden -PassThru -RedirectStandardError $log
    $recorded = $false
    try {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
        if (-not $cim.CommandLine -or $process.HasExited) { throw 'SSH tunnel exited before it could be recorded' }
        $state = [ordered]@{ Version = 1; Id = $process.Id; StartTicks = $process.StartTime.ToUniversalTime().Ticks.ToString()
            Executable = $process.Path; CommandLine = $cim.CommandLine; Target = $target }
        Write-DshFile $script:DshTunnelFile ($state | ConvertTo-Json)
        $recorded = $true
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($process.HasExited) { throw 'SSH tunnel exited' }
            if (Test-DshPort $port) { return }
            Start-Sleep -Milliseconds 100
        }
        throw 'SSH tunnel did not open within 25 seconds'
    } catch {
        if ($recorded) { Stop-DshTunnelCore } elseif (-not $process.HasExited) { Stop-Process -InputObject $process }
        $details = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw -Encoding UTF8 }
        throw "cannot forward 127.0.0.1:${port}: $_ $details"
    }
}
function Invoke-DshHttp([string]$Path, $Body = $null) {
    $request = [Net.WebRequest]::Create("http://127.0.0.1:$($script:DshSettings.DSH_ROMEO_PORT)/v1/$Path")
    $request.Proxy = $null; $request.Timeout = 60000
    $request.Headers['Authorization'] = "Bearer $script:DshKey"
    if ($null -ne $Body) {
        $request.Method = 'POST'; $request.ContentType = 'application/json'
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
        $request.ContentLength = $bytes.Length; $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $response = $null
    try { $response = $request.GetResponse(); [int]$response.StatusCode -eq 200 }
    catch [Net.WebException] { if ($_.Exception.Response) { $_.Exception.Response.Dispose() }; $false }
    finally { if ($response) { $response.Dispose() } }
}
function Test-DshModel {
    Invoke-DshHttp 'chat/completions' @{ model = $script:DshModel; messages = @(@{ role = 'user'; content = 'hi' }); max_tokens = 1; reasoning_effort = 'none' }
}
function Initialize-DshEndpoint([int]$Launch = 0) {
    Connect-Dsh
    $script:DshGateway = Get-DshGatewayUrl
    if (-not $script:DshGateway) {
        Write-DshMessage 'starting the romeollmtool gateway on ROMEO'
        Invoke-DshRlt @('gateway', 'start', '--hours', '24') | Out-Null
        $script:DshGateway = Get-DshGatewayUrl
        if (-not $script:DshGateway) { throw 'the gateway did not start' }
    } else { try { Invoke-DshRlt @('gateway', 'extend', '--hours', '24') | Out-Null } catch { Write-DshMessage "gateway extend failed: $_" } }
    Read-DshFiche
    if ($Launch -gt 0) {
        if (-not $script:DshSettings.ROMEO_PROJECT) { throw "no project code: set ROMEO_PROJECT in $script:DshConfigDir/config.json (rerun install.ps1)" }
        for ($i = 0; $i -lt $Launch; $i++) {
            $outputText = Invoke-DshRlt @('launch', $script:DshSettings.DSH_ROMEO_FICHE, '--project-code', $script:DshSettings.ROMEO_PROJECT, '--time', $script:DshSettings.DSH_ROMEO_TIME, '--no-wait')
            $jobLabel = 'model job'
            if ($outputText -match '(?i)\bjob\s+(\d+)\b') { $jobLabel += " $($Matches[1])" }
            Write-DshMessage "$jobLabel submitted ($($script:DshSettings.DSH_ROMEO_FICHE), $($script:DshSettings.DSH_ROMEO_TIME))"
        }
    }
    $script:DshKey = (Invoke-DshRlt @('gateway', 'show-key')).Trim()
    if (-not $script:DshKey) { throw 'cannot read the gateway key' }
    if ($script:DshSettings.DSH_ROMEO_GATEWAY -eq 'fast') { Set-DshFastGateway }
    Open-DshTunnel
    while (-not (Test-DshModel)) {
        $jobs = @(Get-DshJobs)
        if (-not $jobs.Count) { throw "no $($script:DshSettings.DSH_ROMEO_FICHE) model job on ROMEO. Start one with: dsh-romeo --launch" }
        Write-DshMessage "waiting for the model: $($jobs -join ', '). Ctrl-C stops waiting, not the job."
        Start-Sleep -Milliseconds ([int]([double]$script:DshSettings.DSH_ROMEO_POLL * 1000))
    }
    Write-DshMessage "DeepSeek-V4.1-Flash-1017 ready ($script:DshModel, http://127.0.0.1:$($script:DshSettings.DSH_ROMEO_PORT)/v1)"
}
function Write-DshOverlay {
    # JSON scalars are valid YAML and preserve Windows paths, quotes and spaces.
    $model = ConvertTo-Json -InputObject $script:DshModel -Compress
    $effort = $script:DshSettings.DSH_ROMEO_EFFORT
    # dsh's internal effort IDs differ from the API value for disabled thinking.
    if ($effort -eq 'none') { $effort = 'off' }
    $text = @"
# Written by dsh-romeo at every start: edit config.json instead.
- id: llm-pi-ai
  config:
    providers:
      romeo:
        displayName: ROMEO
        apiKeyEnv: ROMEO_LLM_KEY
        api: openai-completions
        baseURL: http://127.0.0.1:$($script:DshSettings.DSH_ROMEO_PORT)/v1
        compat:
          supportsDeveloperRole: false
          supportsStore: false
          maxTokensField: max_tokens
        reasoning: $effort
        streamIdleTimeoutMs: 600000
        models:
          - id: $model
            name: DeepSeek-V4.1-Flash-1017 (ROMEO)
            contextWindow: $script:DshContext
            maxTokens: $script:DshMaxTokens
            input: [ text ]
            reasoningEfforts: { off: none, low: low, high: high, max: max }
- id: agent-default-model
  config:
    provider: romeo
    model: $model
    reasoningEffort: $effort
"@
    if ($script:DshSettings.DSH_ROMEO_SEARXNG_URL) {
        $plugin = ConvertTo-Json -InputObject ((Join-Path $script:DshRoot 'share/web-search-searxng.mjs').Replace('\', '/')) -Compress
        $url = ConvertTo-Json -InputObject $script:DshSettings.DSH_ROMEO_SEARXNG_URL -Compress
        $text += @"

- id: web
  config:
    searchProvider: dsh-romeo-searxng
    fetchProvider: http
- id: tool-web
  disabled: false
- insert:
    - id: dsh-romeo-searxng
      name: $plugin
      config:
        providerId: dsh-romeo-searxng
        baseURL: $url
"@
    }
    $script:DshOverlay = Join-Path $script:DshConfigDir 'dsh.patch.yml'
    Write-DshFile $script:DshOverlay ($text + "`n")
}
function Get-DshEndpointEnvironment {
    $url = "http://127.0.0.1:$($script:DshSettings.DSH_ROMEO_PORT)/v1"; $oc = Join-Path $script:DshConfigDir 'opencode.json'
    $models = @{}; $models[$script:DshModel] = @{ name = 'DeepSeek-V4.1-Flash-1017 (ROMEO)'; reasoning = $true; tool_call = $true; limit = @{ context = $script:DshContext; output = $script:DshMaxTokens } }
    $config = @{ '$schema' = 'https://opencode.ai/config.json'; provider = @{ romeo = @{ npm = '@ai-sdk/openai-compatible'; name = 'ROMEO'; options = @{ baseURL = $url; apiKey = '{env:ROMEO_LLM_KEY}' }; models = $models } }; model = "romeo/$script:DshModel" }
    Write-DshFile $oc ($config | ConvertTo-Json -Depth 12)
    [ordered]@{ ROMEO_LLM_KEY = $script:DshKey; DSH_ROMEO_MODEL = $script:DshModel; DSH_ROMEO_BASE_URL = $url
        OPENAI_BASE_URL = $url; OPENAI_API_BASE = $url; OPENAI_API_KEY = $script:DshKey
        ANTHROPIC_BASE_URL = "http://127.0.0.1:$($script:DshSettings.DSH_ROMEO_PORT)"; ANTHROPIC_AUTH_TOKEN = $script:DshKey
        ANTHROPIC_MODEL = $script:DshModel; ANTHROPIC_DEFAULT_OPUS_MODEL = $script:DshModel
        ANTHROPIC_DEFAULT_SONNET_MODEL = $script:DshModel; ANTHROPIC_DEFAULT_HAIKU_MODEL = $script:DshModel
        ANTHROPIC_SMALL_FAST_MODEL = $script:DshModel; CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
        AIDER_MODEL = "openai/$script:DshModel"; OPENCODE_CONFIG = $oc }
}
function Invoke-DshClient([string]$Command, [string[]]$Arguments, $Environment) {
    $resolved = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $resolved) { throw "${Command}: command not found" }
    # npm's Windows shims otherwise send arguments through cmd.exe or legacy
    # PowerShell native quoting. Invoke their JS entry point directly with node.
    if ($resolved.Source -match '\.(cmd|ps1)$') {
        $shim = Get-Content -LiteralPath $resolved.Source -Raw -Encoding UTF8
        if ($shim -match '"(?:%dp0%[\\/]|[$]basedir[\\/])(?<entry>node_modules[\\/][^"]+\.[cm]?js)"') {
            $entry = Join-Path (Split-Path -Parent $resolved.Source) $Matches.entry
            if (Test-Path -LiteralPath $entry) {
                $node = Join-Path (Split-Path -Parent $resolved.Source) 'node.exe'
                if (-not (Test-Path -LiteralPath $node)) { $node = 'node.exe' }
                $resolved = Get-Command $node -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $Arguments = @($entry) + $Arguments
            }
        }
    }
    $previous = @{}
    try {
        foreach ($key in $Environment.Keys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, $Environment[$key]) }
        if ($resolved.CommandType -eq 'Application' -and $resolved.Source -match '\.exe$') {
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = $resolved.Source; $info.UseShellExecute = $false
            $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-DshWindowsArgument $_ }) -join ' '
            $process = [Diagnostics.Process]::Start($info)
            try { $process.WaitForExit(); $script:DshExitCode = $process.ExitCode } finally { $process.Dispose() }
        } else {
            $global:LASTEXITCODE = 0
            & $resolved @Arguments
            $script:DshExitCode = $LASTEXITCODE
        }
    } finally { foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) } }
}
function Show-DshStatus {
    Connect-Dsh; $url = Get-DshGatewayUrl
    if ($url) { Write-DshMessage "gateway running $url" } else { Write-DshMessage 'gateway stopped' }
    if ($script:DshSettings.DSH_ROMEO_GATEWAY -eq 'fast') {
        $pattern = ConvertTo-DshPosixQuote "^[^ ]*python[^ ]* -m [r]omeollmtool.gateway.server --host 0.0.0.0 --port $($script:DshSettings.DSH_ROMEO_FAST_PORT)"
        $count = (Invoke-DshSsh ('pgrep -u "$USER" -f ' + $pattern + ' | wc -l')).Trim()
        Write-DshMessage "fast gateway processes: $count"
    }
    $jobs = @(Get-DshJobs)
    if ($jobs.Count) { foreach ($job in $jobs) { Write-DshMessage "model job $job" } }
    else { Write-DshMessage "no model job of $($script:DshSettings.DSH_ROMEO_FICHE) (dsh-romeo --launch)" }
    $state = Get-DshTunnelState
    if ($state -and (Get-DshTunnelProcess $state) -and (Test-DshPort ([int]$script:DshSettings.DSH_ROMEO_PORT))) { Write-DshMessage 'tunnel open' }
    else { Write-DshMessage 'tunnel closed' }
}
function Stop-Dsh {
    Connect-Dsh
    foreach ($job in @(Get-DshJobs)) {
        if ($job -notmatch '^(\d+)\s') { throw "unexpected squeue output: $job" }
        $jobId = $Matches[1]
        try { Invoke-DshRlt @('stop', $jobId) | Out-Null } catch { Invoke-DshSsh "scancel $jobId" | Out-Null }
        Write-DshMessage "model job $jobId stopped"
    }
    if ($script:DshSettings.DSH_ROMEO_GATEWAY -eq 'fast') {
        $pattern = ConvertTo-DshPosixQuote "[r]omeollmtool.gateway.server --host 0.0.0.0 --port $($script:DshSettings.DSH_ROMEO_FAST_PORT)"
        Invoke-DshSsh ('pkill -u "$USER" -f ' + $pattern + ' || test $? = 1') | Out-Null
    }
    Stop-DshTunnel; Write-DshMessage 'tunnel closed (the standard gateway stops by itself)'
}
function Invoke-DshMain([string[]]$Arguments) {
    $launch = 0
    if (-not $Arguments) { $Arguments = @() }
    $first = if ($Arguments.Count) { $Arguments[0] } else { '' }
    switch ($first) {
        { $_ -in '-h', '--help' } {
            @'
dsh-romeo [--launch [1..8]] [web | headless "task" | --serve | --env | --run CMD [ARGS]]
dsh-romeo --status | --stop | --setup | --version | --help
--env prints PowerShell assignments: dsh-romeo --env | Invoke-Expression
Settings: ~/.config/dsh-romeo/config.json (environment variables override the file).
'@
            return
        }
        { $_ -in '-V', '--version' } { "dsh-romeo $script:DshVersion"; return }
        '--status' { Show-DshStatus; return }
        '--stop' { Stop-Dsh; return }
        '--setup' { Set-DshFiches; return }
        '--launch' {
            $launch = 1; $Arguments = @($Arguments | Select-Object -Skip 1)
            if ($Arguments.Count -and $Arguments[0] -match '^\d+$') {
                if ($Arguments[0] -notmatch '^[1-8]$') { throw '--launch takes 1 to 8 jobs' }
                $launch = [int]$Arguments[0]; $Arguments = @($Arguments | Select-Object -Skip 1)
            }
            $first = if ($Arguments.Count) { $Arguments[0] } else { '' }
        }
    }
    if ($first -eq '--desktop') { throw '--desktop is available on macOS; use the dsh Web UI on Windows/WSL' }
    if ($first -eq '--run' -and $Arguments.Count -lt 2) { throw '--run needs a command, e.g. dsh-romeo --run opencode' }
    Initialize-DshEndpoint $launch
    switch ($first) {
        '--serve' {
            'DeepSeek-V4.1-Flash-1017 on ROMEO, an OpenAI-compatible endpoint:'
            "  base URL   http://127.0.0.1:$($script:DshSettings.DSH_ROMEO_PORT)/v1"
            "  model      $script:DshModel"
            '  API key    dsh-romeo --env | Invoke-Expression sets OPENAI_API_KEY and ROMEO_LLM_KEY'
            'The tunnel stays open until dsh-romeo --stop. After sleep, run --serve again.'
        }
        '--env' {
            $environment = Get-DshEndpointEnvironment
            foreach ($key in $environment.Keys) { '$env:' + $key + " = '" + $environment[$key].Replace("'", "''") + "'" }
        }
        '--run' {
            $command = $Arguments[1]; $clientArgs = @($Arguments | Select-Object -Skip 2)
            if ([IO.Path]::GetFileNameWithoutExtension($command) -eq 'codex') {
                $url = "http://127.0.0.1:$($script:DshSettings.DSH_ROMEO_PORT)/v1"
                $provider = 'model_providers.romeo={ name = "ROMEO", base_url = "' + $url + '", env_key = "ROMEO_LLM_KEY", wire_api = "responses" }'
                $clientArgs = @('-c', 'model_provider=romeo', '-c', "model=$script:DshModel", '-c', $provider) + $clientArgs
            }
            Invoke-DshClient $command $clientArgs (Get-DshEndpointEnvironment)
        }
        default {
            Write-DshOverlay
            $profile = if ($Arguments.Count) { $Arguments[0] } else { 'web' }
            $rest = @($Arguments | Select-Object -Skip 1)
            Invoke-DshClient $script:DshSettings.DSH_ROMEO_DSH (@($profile, '--patch', $script:DshOverlay) + $rest) @{ ROMEO_LLM_KEY = $script:DshKey }
        }
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try { Initialize-Dsh; Invoke-DshMain -Arguments $args; exit $script:DshExitCode }
    catch { [Console]::Error.WriteLine("dsh-romeo: $_"); exit 1 }
}
