# Adds this Windows machine to the DevNet Whiteboard.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Orca-DevNet/devnet-agent-releases/main/install.ps1))) -Code <join code>"
#
# The join code comes from an admin (Whiteboard, Admin, Machines). It works once and expires.
#
# What this does, in order, and nothing else:
#   1. checks git is installed, and offers to install it with winget if not (the agent needs git; it needs nothing else);
#   2. downloads the agent for Windows from this repository's latest release and SHA256SUMS, and REFUSES to go on
#      if the checksum does not match;
#   3. runs `devnet-agent join`, which gets this machine its own key and writes its config;
#   4. installs a scheduled task that starts the agent at every logon with no window (the agent only reports in;
#      jobs stay off until you turn them on).
# It puts everything in one folder of your own (default %USERPROFILE%\devnet-agent). It does not need administrator
# rights, does not touch your own Tailscale, and does not add anything to your PATH.
#
# Options: -Dir <folder>   -Version <tag>   -Yes (do not ask before installing git)   -Force (replace an existing join)
#          -NoService (join but do not install the logon task)
param(
	[Parameter(Mandatory = $true)][string]$Code,
	[string]$Dir = (Join-Path $env:USERPROFILE 'devnet-agent'),
	[string]$Version = 'latest',
	[switch]$Yes,
	[switch]$Force,
	[switch]$NoService
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest very slow in Windows PowerShell
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# Where releases come from. DEVNET_RELEASES_BASE is for testing this script against a local server.
$Repo = 'Orca-DevNet/devnet-agent-releases'
$Base = $env:DEVNET_RELEASES_BASE
if (-not $Base) {
	$Base = if ($Version -eq 'latest') { "https://github.com/$Repo/releases/latest/download" } else { "https://github.com/$Repo/releases/download/$Version" }
}
$Asset = 'devnet-agent-windows-amd64.exe'

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not [Environment]::Is64BitOperatingSystem) { Die 'This needs 64-bit Windows.' }
if (-not $Code.StartsWith('dnj1_')) { Die 'That is not a join code: it should start dnj1_ (copy the whole line from the Whiteboard).' }

# ---- 1. git ----------------------------------------------------------------------------------------------
function Refresh-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
	Say 'git is not installed (the agent needs it to do jobs).'
	$winget = Get-Command winget -ErrorAction SilentlyContinue
	if (-not $winget) { Die 'git is missing and winget is not available to install it. Install Git for Windows from https://git-scm.com/download/win, then run this again.' }
	if (-not $Yes) {
		$a = Read-Host 'Install Git for Windows with winget now? [Y/n]'
		if ($a -match '^(n|no)$') { Die 'git is needed. Install it, then run this again.' }
	}
	Say 'Installing git with winget...'
	& winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
	Refresh-Path
	if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git was installed but is not on the PATH yet: close this window, open a new one, and run this again.' }
}
Say ('git: ' + (& git --version))

# ---- 2. the agent, checked ---------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$Exe = Join-Path $Dir 'devnet-agent.exe'
$Cfg = Join-Path $Dir 'config.json'
$New = Join-Path $Dir 'devnet-agent.exe.new'
Say "Downloading the agent ($Version) from $Base"
try {
	# To files, then read as text: a release asset is served as application/octet-stream, so .Content would be bytes.
	$SumsFile = Join-Path $Dir 'SHA256SUMS.new'
	Invoke-WebRequest -UseBasicParsing -Uri "$Base/SHA256SUMS" -OutFile $SumsFile
	$sums = [IO.File]::ReadAllText($SumsFile)
	Remove-Item $SumsFile -Force -ErrorAction SilentlyContinue
	Invoke-WebRequest -UseBasicParsing -Uri "$Base/$Asset" -OutFile $New
} catch { Die "Could not download the agent: $($_.Exception.Message)" }
$line = ($sums -split '\r?\n') | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($Asset) + '\s*$') } | Select-Object -First 1
if (-not $line) { Remove-Item $New -Force -ErrorAction SilentlyContinue; Die "SHA256SUMS has no entry for $Asset." }
$want = ($line.Trim() -split '\s+')[0].ToLower()
$got = (Get-FileHash -Algorithm SHA256 -Path $New).Hash.ToLower()
if ($got -ne $want) {
	Remove-Item $New -Force -ErrorAction SilentlyContinue
	Die "The downloaded agent's SHA256 ($got) does not match SHA256SUMS ($want). It was NOT installed. Do not run it; tell an admin."
}
Say 'Checksum matches.'

# A running agent (a rejoin) has to stop before its file is replaced.
if ((Test-Path $Exe) -and (Test-Path $Cfg)) { try { & $Exe --config $Cfg stop 2>&1 | Out-Null } catch { } }
Move-Item -Force -Path $New -Destination $Exe

# ---- 3. join ---------------------------------------------------------------------------------------------
# The code goes in the environment, not on a command line, so it is not in any process list.
Say 'Joining the Whiteboard...'
$env:DEVNET_JOIN_CODE = $Code
try {
	$joinArgs = @('--config', $Cfg, 'join')
	if ($Force) { $joinArgs += '--force' }
	& $Exe @joinArgs
	if ($LASTEXITCODE -ne 0) { Die 'The join did not work (see above).' }
} finally { Remove-Item Env:\DEVNET_JOIN_CODE -ErrorAction SilentlyContinue }

# ---- 4. start at every logon -------------------------------------------------------------------------------
if (-not $NoService) {
	Say 'Installing the logon task...'
	& $Exe --config $Cfg service install
	if ($LASTEXITCODE -ne 0) { Die ('The agent joined but the logon task could not be installed (see above). Run:  & "' + $Exe + '" --config "' + $Cfg + '" service install') }
	Start-Sleep -Seconds 8
	& $Exe --config $Cfg service status
}

Write-Host ''
Write-Host 'Done. This machine is on the Whiteboard (Machines). It only reports in until you turn jobs on.' -ForegroundColor Green
Write-Host "  Agent:  $Exe"
Write-Host "  Config: $Cfg   (private to you; it holds this machine's key)"
Write-Host "  Log:    $(Join-Path $Dir 'agent.log')"
Write-Host "  Stop:   & `"$Exe`" --config `"$Cfg`" stop"
Write-Host "  Remove: & `"$Exe`" --config `"$Cfg`" service uninstall"
