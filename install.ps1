# Adds this Windows machine to the DevNet Board.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Orca-DevNet/devnet-agent-releases/main/install.ps1))) -Code <join code>"
#
# The join code comes from an admin (Board, Admin, Machines). It works once and expires. To keep it off the command
# line altogether, set it in the environment first and leave -Code off:
#   $env:DEVNET_JOIN_CODE = '<join code>'; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Orca-DevNet/devnet-agent-releases/main/install.ps1)))
# Either way, the agent itself is given the code only through its environment, never as an argument.
#
# What this does, in order, and nothing else:
#   1. checks git is installed, and offers to install it with winget if not (the agent needs git; it needs nothing else);
#   2. downloads the agent for Windows from this repository's latest release and SHA256SUMS, and REFUSES to go on
#      if SHA256SUMS.sig is not a signature of it by one of the admin keys listed in this script (needs ssh-keygen,
#      the OpenSSH client that ships with Windows), or if the checksum does not match;
#   3. runs `devnet-agent join`, which gets this machine its own key and writes its config;
#   4. installs a scheduled task that starts the agent at every logon with no window (the agent only reports in;
#      jobs stay off until you turn them on).
# It puts everything in one folder of your own (default %USERPROFILE%\devnet-agent). It does not need administrator
# rights, does not touch your own Tailscale, and does not add anything to your PATH.
#
# Options: -Dir <folder>   -Version <tag>   -Yes (do not ask before installing git)   -Force (replace an existing join)
#          -NoService (join but do not install the logon task)   -Boot (start when the PC starts, before anyone logs on, for a
#          PC that is on all the time with nobody at it: needs an administrator PowerShell, and also adds the firewall rule)
#          -NoTray (do not install the tray icon. By default it is installed and starts at logon from your Startup folder: a dot that is
#          green when all is well and shows a red X, a ! or a green tick when something wants you; Pause now / Pause after this job /
#          Resume / Open the Board, usage, Game mode. -Tray is still accepted and means the default.)
# Run from an administrator PowerShell the installer also adds a Windows Firewall rule for the agent (so a PC nobody sits at does
# not leave the firewall's question unanswered, which would put the agent on a slower relay); otherwise it prints the one command.
param(
	[string]$Code = $env:DEVNET_JOIN_CODE,   # or set $env:DEVNET_JOIN_CODE first and leave -Code off: then it is on no command line
	[string]$Dir = (Join-Path $env:USERPROFILE 'devnet-agent'),
	[string]$Version = 'latest',
	[switch]$Yes,
	[switch]$Force,
	[switch]$NoService,
	[switch]$Boot,
	[switch]$Tray,     # the default now; kept so older commands still work
	[switch]$NoTray
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
if (-not $Code) { Die 'This needs the join code an admin made on the Board: -Code <code> (or set $env:DEVNET_JOIN_CODE first).' }
if (-not $Code.StartsWith('dnj1_')) { Die 'That is not a join code: it should start dnj1_ (copy the whole line from the Board).' }

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
    [IO.File]::WriteAllText((Join-Path $Dir 'SHA256SUMS.check'), $sums, (New-Object Text.UTF8Encoding($false)))
    try { Invoke-WebRequest -UseBasicParsing -Uri "$Base/SHA256SUMS.sig" -OutFile (Join-Path $Dir 'SHA256SUMS.sig.check') } catch { Die "Could not download SHA256SUMS.sig ($($_.Exception.Message)): this release is not signed, so it is not installed." }
} catch { Die "Could not download the agent: $($_.Exception.Message)" }

# The release must be signed by an admin key listed here (the same list is built into the agent). DEVNET_ALLOWED_SIGNERS_FILE is for testing this script.
$SumsPath = Join-Path $Dir 'SHA256SUMS.check'
$SigPath = Join-Path $Dir 'SHA256SUMS.sig.check'
$AllowedPath = Join-Path $Dir 'allowed_signers.check'
if ($env:DEVNET_ALLOWED_SIGNERS_FILE) { Copy-Item -Force $env:DEVNET_ALLOWED_SIGNERS_FILE $AllowedPath } else {
    $allowedText = @'
# BEGIN allowed_signers
admin namespaces="devnet-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKkiyZsc3h3tSKkMhE6qxp+UaMRVtDV8S1OP4A8Ptyku
# END allowed_signers
'@
    [IO.File]::WriteAllText($AllowedPath, ($allowedText -replace "`r", '') + "`n", (New-Object Text.UTF8Encoding($false)))
}
$sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
$verified = $false
if ($sshKeygen) {
    # cmd handles the "< file" so SHA256SUMS goes in byte for byte
    & cmd.exe /c ('""{0}" -Y verify -f "{1}" -I admin -n devnet-release -s "{2}" < "{3}" > nul 2>&1"' -f $sshKeygen.Source, $AllowedPath, $SigPath, $SumsPath)
    $verified = ($LASTEXITCODE -eq 0)
}
Remove-Item $SumsPath, $SigPath, $AllowedPath -Force -ErrorAction SilentlyContinue
if (-not $sshKeygen) { Remove-Item $New -Force -ErrorAction SilentlyContinue; Die 'This needs ssh-keygen (the OpenSSH client: Settings, Apps, Optional features) to check the release''s signature.' }
if (-not $verified) { Remove-Item $New -Force -ErrorAction SilentlyContinue; Die 'SHA256SUMS is not signed by a trusted admin key (or is not signed at all). Nothing was installed. Do not run it; tell an admin.' }
Say 'Signature is by a trusted admin key.'
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
Say 'Joining the Board...'
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
	$svcArgs = @('--config', $Cfg, 'service', 'install')
	if ($Boot) { $svcArgs += '--boot' }
	& $Exe @svcArgs
	if ($LASTEXITCODE -ne 0) { Die ('The agent joined but the logon task could not be installed (see above). Run:  & "' + $Exe + '" --config "' + $Cfg + '" service install') }
	Start-Sleep -Seconds 8
	& $Exe --config $Cfg service status
}

# ---- 5. the tray icon, if asked for ---------------------------------------------------------------------------
if (-not $NoTray) {
	$TrayAsset = 'devnet-tray-windows-amd64.exe'
	$TrayExe = Join-Path $Dir 'devnet-tray.exe'
	$TrayNew = Join-Path $Dir 'devnet-tray.exe.new'
	try {
		Say 'Downloading the tray icon'
		Invoke-WebRequest -UseBasicParsing -Uri "$Base/$TrayAsset" -OutFile $TrayNew
		$tline = ($sums -split '\r?\n') | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($TrayAsset) + '\s*$') } | Select-Object -First 1
		if (-not $tline) { throw "SHA256SUMS has no entry for $TrayAsset (this release has no tray icon)." }
		$twant = ($tline.Trim() -split '\s+')[0].ToLower()
		$tgot = (Get-FileHash -Algorithm SHA256 -Path $TrayNew).Hash.ToLower()
		if ($tgot -ne $twant) { throw "The tray icon's SHA256 ($tgot) does not match SHA256SUMS ($twant). It was NOT installed." }
		Get-Process devnet-tray -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
		Move-Item -Force -Path $TrayNew -Destination $TrayExe
		$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DevNet tray.lnk'
		$sh = New-Object -ComObject WScript.Shell
		$sc = $sh.CreateShortcut($lnk)
		$sc.TargetPath = $TrayExe
		$sc.Arguments = '--config "' + $Cfg + '"'
		$sc.WorkingDirectory = $Dir
		$sc.Description = 'DevNet agent tray icon'
		$sc.Save()
		Start-Process -FilePath $TrayExe -ArgumentList ('--config "' + $Cfg + '"') -WorkingDirectory $Dir
		Say "Tray icon installed: it starts at logon from $lnk (look for the dot in the notification area; it may be under the ^ arrow)."
	} catch {
		Remove-Item $TrayNew -Force -ErrorAction SilentlyContinue
		Write-Host "The tray icon was not installed: $($_.Exception.Message)  (The agent itself is fine; `devnet-agent pause` and `resume` work from any window.)" -ForegroundColor Yellow
	}
}

Write-Host ''
Write-Host 'Done. This machine is on the Board (Machines). It takes jobs within its budgets until paused (tray, Board, or devnet-agent pause).' -ForegroundColor Green
Write-Host "  Agent:  $Exe"
Write-Host "  Config: $Cfg   (private to you; it holds this machine's key)"
Write-Host "  Log:    $(Join-Path $Dir 'agent.log')"
Write-Host "  Stop:   & `"$Exe`" --config `"$Cfg`" stop"
Write-Host "  Remove: & `"$Exe`" --config `"$Cfg`" service uninstall"
