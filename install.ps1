<#
.SYNOPSIS
Install dsh-romeo natively on Windows, without administrator rights.
.EXAMPLE
.\install.ps1 -Project r123456 -Yes
.EXAMPLE
.\install.ps1 -SshHost romeo -BinDir "$HOME\.local\bin" -Search
#>
[CmdletBinding()]
param(
    [string]$Project,
    [Alias('Host')][string]$SshHost,
    [string]$BinDir = (Join-Path $HOME '.local\bin'),
    [switch]$Search,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bin/dsh-romeo.ps1')

function Read-DshAnswer([string]$Question, [string]$Default) {
    if ($Yes -or [Console]::IsInputRedirected) { return $Default }
    $answer = Read-Host "$Question [$Default]"
    if ($answer) { $answer } else { $Default }
}

function Install-DshWindows {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Use install.sh on Linux, WSL or macOS.' }
    $choices = @{}
    if ($SshHost) { $choices.ROMEO_SSH_HOST = $SshHost }
    if ($Project) { $choices.ROMEO_PROJECT = $Project }
    Initialize-Dsh -Overrides $choices
    if ($script:DshSettings.DSH_ROMEO_FICHE -eq 'dsh-deepseek-v4.1-flash-1m') {
        $script:DshSettings.DSH_ROMEO_FICHE = 'dsh-deepseek-v4.1-flash-1017-1m'
    }
    Get-DshSshPath | Out-Null
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Install Node.js 20 or later: https://nodejs.org' }
    $nodeMajor = & node -p 'parseInt(process.versions.node)'
    if ($LASTEXITCODE -ne 0 -or [int]$nodeMajor -lt 20) { throw 'Node.js 20 or later is required.' }
    $nodePlatform = & node -p 'process.platform'
    if ($nodePlatform -ne 'win32') { throw 'Use Windows Node.js with install.ps1, or Linux Node.js with install.sh inside WSL.' }

    $dsh = $script:DshSettings.DSH_ROMEO_DSH
    $privateDsh = Join-Path $script:DshConfigDir 'npm/dsh.cmd'
    if (-not (Get-Command $dsh -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $privateDsh) { $dsh = $privateDsh }
        else {
            if ((Read-DshAnswer 'Install DeepSeek Harness with npm into your user directory? (y/n)' 'y') -ne 'y') { throw 'Install dsh first or rerun install.ps1 -Yes.' }
            if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm is missing; install Node.js with npm.' }
            & npm install --global --prefix (Join-Path $script:DshConfigDir 'npm') '@deepseek-ai/dsh'
            if ($LASTEXITCODE -ne 0) { throw 'npm install failed.' }
            if (-not (Test-Path -LiteralPath $privateDsh)) { throw "npm did not create $privateDsh" }
            $dsh = $privateDsh
        }
    }
    $script:DshSettings.DSH_ROMEO_DSH = $dsh
    Write-DshMessage "dsh executable: $dsh"
    Connect-Dsh
    $remoteTool = ConvertTo-DshPosixQuote $script:DshSettings.ROMEOLLMTOOL
    $remote = Invoke-DshSsh ("test -x $remoteTool && echo rlt=yes; " +
        'sacctmgr -n -P show assoc user="$USER" format=account 2>/dev/null | sort -u')
    if ($remote -notmatch '(?m)^rlt=yes') { throw "romeollmtool is not available at $($script:DshSettings.ROMEOLLMTOOL) on ROMEO." }
    $accounts = @($remote -split '\r?\n' | ForEach-Object { $_.Trim().TrimEnd('|') } |
        Where-Object { $_ -and $_ -ne 'default' -and $_ -ne 'rlt=yes' })
    if (-not $script:DshSettings.ROMEO_PROJECT) {
        if (-not $accounts.Count) { throw 'No Slurm project found. Give one with -Project.' }
        if ($accounts.Count -gt 1) { Write-DshMessage "your projects: $($accounts -join ', ')" }
        $script:DshSettings.ROMEO_PROJECT = Read-DshAnswer 'Project code to charge for model jobs (GPU hours)' $accounts[0]
    }
    if ($script:DshSettings.ROMEO_PROJECT -notin $accounts) { Write-DshMessage 'warning: the chosen project is not among your Slurm accounts' }
    if ($script:DshSettings.ROMEO_PROJECT -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'invalid ROMEO_PROJECT' }
    if ($Search) { $script:DshSettings.DSH_ROMEO_SEARXNG_URL = 'http://127.0.0.1:8888' }
    $configFile = Join-Path $script:DshConfigDir 'config.json'
    Write-DshFile $configFile ($script:DshSettings | ConvertTo-Json)
    Set-DshFiches

    $resolvedBin = [IO.Path]::GetFullPath($BinDir)
    [IO.Directory]::CreateDirectory($resolvedBin) | Out-Null
    $entry = Join-Path $PSScriptRoot 'bin/dsh-romeo.ps1'
    $wrappers = @{
        'dsh-romeo.ps1' = "# Installed by dsh-romeo`n& '" + $entry.Replace("'", "''") + "' @args`nexit `$LASTEXITCODE`n"
        'dsh-romeo.cmd' = "@echo off`r`nrem Installed by dsh-romeo`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$entry`" %*`r`nexit /b %errorlevel%`r`n"
    }
    foreach ($name in $wrappers.Keys) {
        $target = Join-Path $resolvedBin $name
        if ((Test-Path -LiteralPath $target) -and (Get-Content -LiteralPath $target -Raw -Encoding UTF8) -notmatch 'Installed by dsh-romeo') {
            $backup = "$target.before-dsh-romeo-$([Guid]::NewGuid().ToString('N'))"
            Copy-Item -LiteralPath $target -Destination $backup
            Write-DshMessage "previous command kept at $backup"
        }
        Write-DshFile $target $wrappers[$name]
    }
    Add-DshUserPath $resolvedBin
    if ($Search) { Install-DshSearch }
    Write-DshMessage "installed. In a new terminal: dsh-romeo.cmd --launch. Stop jobs with dsh-romeo.cmd --stop."
    Write-DshMessage ("In this terminal: & '" + (Join-Path $resolvedBin 'dsh-romeo.cmd').Replace("'", "''") + "' --launch")
    Write-DshMessage "Settings: $configFile. New terminals get the updated PATH."
}

function Add-DshUserPath([string]$ResolvedBin) {
    $userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    if ($resolvedBin -notin ($userPath -split ';')) {
        [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';') + ';' + $resolvedBin).TrimStart(';')), 'User')
    }
    if ($resolvedBin -notin ($env:Path -split ';')) { $env:Path = "$resolvedBin;$env:Path" }
}

function Install-DshSearch {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Install Docker Desktop for -Search.' }
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Start Docker Desktop and rerun install.ps1 -Search.' }
    $dir = Join-Path $script:DshConfigDir 'searxng'
    $settings = Join-Path $dir 'settings.yml'
    if (-not (Test-Path -LiteralPath $settings)) {
        $bytes = New-Object byte[] 32; $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $secret = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
        Write-DshFile $settings ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'share/searxng/settings.yml') -Raw -Encoding UTF8).Replace('__SECRET__', $secret))
    }
    & docker rm -f dsh-romeo-searxng *> $null
    & docker run -d --name dsh-romeo-searxng --restart unless-stopped -p 127.0.0.1:8888:8080 -v "${dir}:/etc/searxng" searxng/searxng
    if ($LASTEXITCODE -ne 0) { throw 'SearXNG container failed to start.' }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Install-DshWindows } catch { [Console]::Error.WriteLine("dsh-romeo install: $_"); exit 1 }
}
