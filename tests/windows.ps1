# Offline tests: fake SSH commands, real loopback HTTP, and a real detached
# fake ssh.exe process. No ROMEO connection, Slurm job or model request.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ("dsh-romeo windows " + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$savedEnvironment = @{}
foreach ($entry in Get-ChildItem Env:) {
    if ($entry.Name -match '^(DSH_ROMEO_|ROMEO_|ROMEOLLMTOOL$|FAKE_)') {
        $savedEnvironment[$entry.Name] = $entry.Value
        [Environment]::SetEnvironmentVariable($entry.Name, $null)
    }
}
$env:DSH_ROMEO_CONFIG_DIR = Join-Path $temp ('config with spaces ' + [char]0x00e9)
$env:ROMEO_PROJECT = 'r000000'
$env:FAKE_ROMEO_STATE = Join-Path $temp 'state'
$env:FAKE_LOAD_SECONDS = '0'
[IO.Directory]::CreateDirectory($env:FAKE_ROMEO_STATE) | Out-Null
. (Join-Path $root 'bin/dsh-romeo.ps1')
$script:passed = 0
$script:failed = 0
function Assert-Dsh([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:passed++; Write-Output "  ok    $Name" }
    else { $script:failed++; Write-Output "  FAIL  $Name" }
}
function Assert-DshThrows([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    $errorText = ''
    try { & $Action | Out-Null } catch { $errorText = "$_" }
    Assert-Dsh $Name ($errorText -match $Pattern)
    if ($errorText -and $errorText -notmatch $Pattern) { Write-Output "        $errorText" }
}
function Get-FreeDshPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}
$gatewayProcess = $null
try {
    Initialize-Dsh
    Assert-Dsh 'version without ssh' ((Invoke-DshMain @('--version')) -eq 'dsh-romeo 0.1.0')
    Assert-Dsh 'help without ssh' ((Invoke-DshMain @('--help')) -match 'PowerShell')
    Assert-DshThrows 'launch range checked before network' { Invoke-DshMain @('--launch', '9') } '1 to 8'
    Assert-DshThrows 'launch huge integer rejected' { Invoke-DshMain @('--launch', '999999999999999') } '1 to 8'
    Assert-DshThrows 'missing client rejected before network' { Invoke-DshMain @('--run') } 'needs a command'
    Assert-DshThrows 'desktop fails before network' { Invoke-DshMain @('--desktop') } 'Web UI'
    Write-DshFile (Join-Path $script:DshConfigDir 'config.json') '{"DSH_ROMEO_PORT":"12345","DSH_ROMEO_EFFORT":"low","ROMEO_PROJECT":"saved"}'
    Initialize-Dsh
    Assert-Dsh 'saved settings loaded' ($script:DshSettings.DSH_ROMEO_PORT -eq '12345')
    Assert-Dsh 'environment overrides settings' ($script:DshSettings.ROMEO_PROJECT -eq 'r000000')
    $env:DSH_ROMEO_PORT = '70000'
    Assert-DshThrows 'invalid local port rejected' { Initialize-Dsh } 'invalid DSH_ROMEO_PORT'
    $env:DSH_ROMEO_PORT = [string](Get-FreeDshPort)
    Initialize-Dsh

    # Compile with the .NET Framework compiler so the executable runs in both PS 5.1 and 7.
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $script:fakeSsh = Join-Path $temp 'ssh.exe'
    & $compiler /nologo "/out:$script:fakeSsh" (Join-Path $PSScriptRoot 'fake-windows-ssh.cs')
    if ($LASTEXITCODE -ne 0) { throw 'failed to build fake ssh.exe' }
    function Get-DshSshPath { $script:fakeSsh }
    $command = 'printf "%s" ''a b''; echo "$USER"; # & | < >'
    $inputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = New-Object Text.UTF8Encoding($true)
        $reported = (Invoke-DshSsh $command 'SGVsbG8=') -split '\r?\n'
    } finally { [Console]::InputEncoding = $inputEncoding }
    $received = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($reported[-2]))
    Assert-Dsh 'ssh remote quoting survives native argv' ($received -ceq $command)
    Assert-Dsh 'ssh stdin reaches remote without console BOM' ($reported[-1] -eq 'stdin:U0dWc2JHOD0=')

    # Real tunnel process lifecycle, using an unused local port.
    $script:DshGateway = 'http://romeo.example:11318/v1'
    Open-DshTunnel
    $state = Get-DshTunnelState
    Assert-Dsh 'native tunnel opens on loopback' (Test-DshPort ([int]$env:DSH_ROMEO_PORT))
    Assert-Dsh 'native tunnel identity persisted' ($state.Id -gt 0 -and $state.CommandLine -match '127.0.0.1:')
    Open-DshTunnel
    Assert-Dsh 'native tunnel reused' ((Get-DshTunnelState).Id -eq $state.Id)
    $badState = $state | ConvertTo-Json | ConvertFrom-Json
    $badState.StartTicks = '0'
    Assert-DshThrows 'PID reuse rejected' { Get-DshTunnelProcess $badState } 'identity changed'
    Assert-Dsh 'unverified process kept alive' ($null -ne (Get-Process -Id $state.Id -ErrorAction SilentlyContinue))
    Stop-DshTunnel
    Assert-Dsh 'owned tunnel stopped' (-not (Test-DshPort ([int]$env:DSH_ROMEO_PORT)))
    Assert-Dsh 'receipt removed' (-not (Test-Path -LiteralPath $script:DshTunnelFile))
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, [int]$env:DSH_ROMEO_PORT)
    $listener.Start()
    try { Assert-DshThrows 'occupied port not hijacked' { Open-DshTunnel } 'another program' }
    finally { $listener.Stop() }
    $env:FAKE_SSH_FAIL = '1'
    Assert-DshThrows 'failed tunnel reports error' { Open-DshTunnel } 'cannot forward'
    Assert-Dsh 'failed tunnel leaves no receipt' (-not (Test-Path -LiteralPath $script:DshTunnelFile))
    Remove-Item Env:FAKE_SSH_FAIL

    # Fake ROMEO remote commands; a real HTTP gateway tests the readiness request.
    $script:gatewayStarted = $false; $script:ficheInstalled = $false; $script:launches = 0
    $script:remoteUnavailable = $false
    $script:remoteCalls = New-Object 'Collections.Generic.List[string]'
    function Invoke-DshSsh([string]$Command, [string]$InputText = '') {
        $script:remoteCalls.Add($Command)
        if ($script:remoteUnavailable) {
            $failure = New-Object InvalidOperationException('SSH transport unavailable')
            $failure.Data['ExitCode'] = 255
            throw $failure
        }
        switch -Regex ($Command) {
            '^true$' { return '' }
            'sacctmgr ' { return "rlt=yes`nr999999|`n" }
            '^mkdir ' { return '' }
            '^base64 -d ' {
                $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($InputText))
                if ($Command -match 'configs/' -and $decoded -match 'vllm:') { $script:ficheInstalled = $true }
                return ''
            }
            "'gateway' 'status'$" {
                if ($script:gatewayStarted) { return 'Gateway active: http://romeo.example:11318/v1' }
                $failure = New-Object InvalidOperationException('Gateway stopped')
                $failure.Data['ExitCode'] = 1
                throw $failure
            }
            "'gateway' 'start'" { $script:gatewayStarted = $true; return 'started' }
            "'gateway' 'extend'" { return 'extended' }
            "'gateway' 'show-key'$" { return 'test-key' }
            "'catalog' 'show'" {
                if (-not $script:ficheInstalled) { throw 'fiche missing' }
                return Get-Content -LiteralPath (Join-Path $root 'share/fiches/dsh-deepseek-v4.1-flash-1017-1m.yaml') -Raw -Encoding UTF8
            }
            "'launch' " {
                $script:launches++
                $stamp = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 10)
                Add-Content -LiteralPath (Join-Path $env:FAKE_ROMEO_STATE 'jobs') -Value "900001 model $stamp"
                return 'Job 900001 submitted'
            }
            '^squeue ' {
                if (Test-Path -LiteralPath (Join-Path $env:FAKE_ROMEO_STATE 'jobs')) {
                    if ((Get-Content -LiteralPath (Join-Path $env:FAKE_ROMEO_STATE 'jobs') -Raw -Encoding UTF8).Trim()) { return '900001 RUNNING 00:01 07:59:59 None' }
                }
                return ''
            }
            "'stop' '900001'$" { Write-DshFile (Join-Path $env:FAKE_ROMEO_STATE 'jobs') ''; return '' }
            "'version'$" { return 'romeollmtool test' }
            'start.sh ' { throw 'fast gateway unavailable in test' }
            default { throw "unexpected remote command: $Command" }
        }
    }
    function Open-DshTunnel {} # HTTP test server already occupies the endpoint port.
    $port = Get-FreeDshPort
    $env:DSH_ROMEO_PORT = [string]$port
    Initialize-Dsh
    $python = (Get-Command python.exe -CommandType Application | Select-Object -First 1).Source
    $gatewayScript = Join-Path $root 'tests/fake-romeo/bin/gateway.py'
    $gatewayArgs = (ConvertTo-DshWindowsArgument $gatewayScript) + " $port"
    $gatewayProcess = Start-Process -FilePath $python -ArgumentList $gatewayArgs -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $temp 'gateway.log')
    for ($i = 0; $i -lt 100; $i++) { if (Test-DshPort $port) { break }; Start-Sleep -Milliseconds 50 }
    if ($gatewayProcess.HasExited) { throw 'fake HTTP gateway exited' }
    Invoke-DshMain @('--status')
    Assert-Dsh 'stopped gateway status accepts real CLI exit 1' (-not $script:gatewayStarted)
    $script:remoteUnavailable = $true
    Assert-DshThrows 'gateway status preserves SSH transport errors' { Get-DshGatewayUrl } 'transport unavailable'
    $script:remoteUnavailable = $false
    Assert-DshThrows 'missing fiche has setup guidance' { Invoke-DshMain @('--serve') } 'not found on ROMEO'
    Invoke-DshMain @('--setup')
    Assert-Dsh 'setup uploads fiche with bytes preserved' $script:ficheInstalled
    Assert-DshThrows 'no job has launch guidance' { Invoke-DshMain @('--serve') } 'Start one with'
    Assert-DshThrows 'missing project rejected' {
        $old = $script:DshSettings.ROMEO_PROJECT; $script:DshSettings.ROMEO_PROJECT = ''
        try { Invoke-DshMain @('--launch', '--serve') } finally { $script:DshSettings.ROMEO_PROJECT = $old }
    } 'no project code'
    $serve = Invoke-DshMain @('--launch', '--serve')
    Assert-Dsh 'launch submits one job' ($script:launches -eq 1)
    Assert-Dsh 'serve shows endpoint without key' (($serve -join "`n") -match "127.0.0.1:$port/v1" -and ($serve -join "`n") -notmatch 'test-key')
    Assert-Dsh 'HTTP readiness succeeds with gateway key' (Test-DshModel)
    $oldKey = $script:DshKey; $script:DshKey = 'wrong'
    Assert-Dsh 'HTTP readiness rejects wrong key' (-not (Test-DshModel))
    $script:DshKey = $oldKey
    $script:DshSettings.DSH_ROMEO_SEARXNG_URL = 'http://127.0.0.1:8888'
    Write-DshOverlay
    $overlay = Get-Content -LiteralPath $script:DshOverlay -Raw -Encoding UTF8
    Assert-Dsh 'overlay reads 1M context from fiche' ($overlay -match 'contextWindow: 1048576')
    Assert-Dsh 'overlay reads output limit' ($overlay -match 'maxTokens: 262144')
    Assert-Dsh 'overlay quotes Windows plugin path' ($overlay -match 'name: "[^"]+web-search-searxng.mjs"')
    Assert-Dsh 'overlay never stores key' ($overlay -notmatch 'test-key')
    $previousEffort = $script:DshSettings.DSH_ROMEO_EFFORT
    $script:DshSettings.DSH_ROMEO_EFFORT = 'none'
    Write-DshOverlay
    $disabledThinking = Get-Content -LiteralPath $script:DshOverlay -Raw -Encoding UTF8
    Assert-Dsh 'none uses dsh off provider effort' ($disabledThinking -match '(?m)^\s+reasoning: off$')
    Assert-Dsh 'none uses dsh off agent effort' ($disabledThinking -match 'reasoningEffort: off')
    $script:DshSettings.DSH_ROMEO_EFFORT = $previousEffort
    $environment = Get-DshEndpointEnvironment
    $opencode = Get-Content -LiteralPath $environment.OPENCODE_CONFIG -Raw -Encoding UTF8
    Assert-Dsh 'opencode JSON parses' (($opencode | ConvertFrom-Json).model -eq "romeo/$script:DshModel")
    Assert-Dsh 'opencode never stores key' ($opencode -notmatch 'test-key')
    $exports = Invoke-DshMain @('--env')
    Assert-Dsh 'env stdout only PowerShell assignments' (@($exports | Where-Object { $_ -notmatch '^\$env:' }).Count -eq 0)
    $beforeKey = $env:OPENAI_API_KEY
    try {
        $exports | Invoke-Expression
        Assert-Dsh 'PowerShell env can be imported' ($env:OPENAI_API_KEY -eq 'test-key')
    } finally { [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $beforeKey) }

    # Real client process: check spaces/quotes/metacharacters and its exit code.
    $recorder = Join-Path $temp 'record argv.py'
    $record = Join-Path $temp 'client.json'
    Write-DshFile $recorder 'import json,os,sys; json.dump({"args":sys.argv[2:],"key":os.environ.get("ROMEO_LLM_KEY")},open(sys.argv[1],"w")); sys.exit(7)'
    $tricky = 'a "quoted" task & echo no | < > trailing\'
    $keyBefore = $env:ROMEO_LLM_KEY
    Invoke-DshMain @('--run', $python, $recorder, $record, $tricky, '')
    $call = Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Dsh 'client receives quotes and metacharacters intact' ($call.args[0] -ceq $tricky)
    Assert-Dsh 'client receives empty argument' ($call.args.Count -eq 2 -and $call.args[1] -eq '')
    Assert-Dsh 'client receives key in environment' ($call.key -eq 'test-key')
    Assert-Dsh 'client environment restored' ($env:ROMEO_LLM_KEY -ceq $keyBefore)
    Assert-Dsh 'client exit code propagated' ($script:DshExitCode -eq 7)

    # npm shims must retain embedded quotes in both Windows PowerShell and PS 7.
    $js = Join-Path $temp 'node_modules/test/cli.js'
    Write-DshFile $js 'require("fs").writeFileSync(process.argv[2],JSON.stringify({args:process.argv.slice(3),key:process.env.ROMEO_LLM_KEY}));process.exit(7)'
    $cmdShim = Join-Path $temp 'test-client.cmd'
    Write-DshFile $cmdShim '@node "%dp0%\node_modules\test\cli.js" %*'
    Invoke-DshMain @('--run', $cmdShim, $record, $tricky, '')
    $call = Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Dsh 'npm cmd shim preserves quoted and empty args' ($call.args[0] -ceq $tricky -and $call.args.Count -eq 2 -and $call.args[1] -eq '')
    Assert-Dsh 'npm cmd shim preserves exit code' ($script:DshExitCode -eq 7)
    $psShim = Join-Path $temp 'test-client.ps1'
    Write-DshFile $psShim '$basedir=Split-Path $MyInvocation.MyCommand.Definition -Parent; & node "$basedir/node_modules/test/cli.js" @args; exit $LASTEXITCODE'
    Invoke-DshMain @('--run', $psShim, $record, $tricky, '')
    $call = Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Dsh 'npm ps1 shim preserves quoted and empty args' ($call.args[0] -ceq $tricky -and $call.args.Count -eq 2 -and $call.args[1] -eq '')

    # PowerShell/.cmd client adapter and Codex provider arguments.
    $script:capturedCommand = ''; $script:capturedArguments = @()
    function Invoke-DshClient([string]$Command, [string[]]$Arguments, $Environment) {
        $script:capturedCommand = $Command; $script:capturedArguments = $Arguments
    }
    Invoke-DshMain @('headless', 'fix tests')
    Assert-Dsh 'headless profile and task forwarded' ($script:capturedArguments[0] -eq 'headless' -and $script:capturedArguments[-1] -eq 'fix tests')
    Invoke-DshMain @('--run', 'codex.cmd', 'exec', 'hello')
    Assert-Dsh 'Codex Windows shim recognized' ($script:capturedArguments -contains 'model_provider=romeo')
    Assert-Dsh 'Codex uses Responses API' (($script:capturedArguments -join ' ') -match 'wire_api = "responses"')
    Assert-Dsh 'Codex own arguments preserved' ($script:capturedArguments[-1] -eq 'hello')
    $script:DshSettings.DSH_ROMEO_GATEWAY = 'fast'
    Invoke-DshMain @('--serve') | Out-Null
    Assert-Dsh 'fast gateway failure falls back' ($script:DshGateway -eq 'http://romeo.example:11318/v1')
    $script:DshSettings.DSH_ROMEO_GATEWAY = 'standard'
    Invoke-DshMain @('--stop')
    Assert-Dsh 'stop cancels only fiche job' ((Get-Content -LiteralPath (Join-Path $env:FAKE_ROMEO_STATE 'jobs') -Raw -Encoding UTF8).Length -eq 0)

    # Exercise the actual Windows installer with fake npm/SSH, keeping PATH writes
    # in a test boundary. No persistent environment or npm configuration changes.
    $fakeRemote = (Get-Command Invoke-DshSsh).ScriptBlock
    . (Join-Path $root 'install.ps1') -Project r999999 -SshHost fake-romeo -BinDir (Join-Path $temp 'installed bin') -Yes
    Set-Item Function:\Invoke-DshSsh $fakeRemote
    function Get-DshSshPath { $script:fakeSsh }
    function Add-DshUserPath([string]$ResolvedBin) { $script:registeredPath = $ResolvedBin }
    $script:npmInstalls = 0
    function npm {
        $script:npmInstalls++
        if ($args[0] -ne 'install' -or $args[1] -ne '--global' -or $args[2] -ne '--prefix') { throw 'EACCES: system npm prefix' }
        $prefix = $args[3]
        Write-DshFile (Join-Path $prefix 'dsh.cmd') '@echo fake-dsh'
        $global:LASTEXITCODE = 0
    }
    $env:DSH_ROMEO_DSH = Join-Path $temp 'missing dsh'
    Write-DshFile (Join-Path $BinDir 'dsh-romeo.ps1') '# Existing user command'
    Install-DshWindows
    $saved = Get-Content -LiteralPath (Join-Path $script:DshConfigDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Dsh 'Windows installer uses private npm prefix' ($script:npmInstalls -eq 1 -and $saved.DSH_ROMEO_DSH -eq (Join-Path $script:DshConfigDir 'npm/dsh.cmd'))
    Assert-Dsh 'installer choices override environment' ($saved.ROMEO_PROJECT -eq 'r999999' -and $saved.ROMEO_SSH_HOST -eq 'fake-romeo')
    Assert-Dsh 'installer registers command directory' ($script:registeredPath -eq $BinDir)
    Assert-Dsh 'installer preserves existing command' (@(Get-ChildItem -LiteralPath $BinDir -Filter '*.before-dsh-romeo-*').Count -eq 1)
    $version = & (Join-Path $BinDir 'dsh-romeo.cmd') --version
    Assert-Dsh 'installed cmd launcher works from path with spaces' ($version -eq 'dsh-romeo 0.1.0')
    $version = & (Join-Path $BinDir 'dsh-romeo.ps1') --version
    Assert-Dsh 'installed PowerShell launcher works' ($version -eq 'dsh-romeo 0.1.0')
    Install-DshWindows
    Assert-Dsh 'Windows reinstall reuses private dsh' ($script:npmInstalls -eq 1)
    $SshHost = '-bad-host'
    Assert-DshThrows 'invalid install host rejected before network' { Install-DshWindows } 'invalid ROMEO_SSH_HOST'
    Write-Output "$script:passed passed, $script:failed failed"
    if ($script:failed) { throw "$script:failed assertions failed" }
} finally {
    if ($gatewayProcess -and -not $gatewayProcess.HasExited) { Stop-Process -InputObject $gatewayProcess }
    if (Test-Path -LiteralPath $script:DshTunnelFile) { Stop-DshTunnel }
    foreach ($entry in @(Get-ChildItem Env:)) {
        if ($entry.Name -match '^(DSH_ROMEO_|ROMEO_|ROMEOLLMTOOL$|FAKE_)') { [Environment]::SetEnvironmentVariable($entry.Name, $null) }
    }
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key]) }
    # Guard the recursive cleanup against an accidental path change.
    if ((Split-Path -Parent ([IO.Path]::GetFullPath($temp))) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'unexpected test temp path' }
    Remove-Item -LiteralPath $temp -Recurse -Force
}
