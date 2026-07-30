[CmdletBinding()]
param(
    [string]$PublicKey = "",
    [switch]$SkipFFmpeg,
    [switch]$SkipTray,
    [ValidateSet("Ask", "Yes", "No")]
    [string]$StartWithWindows = "Ask"
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n$Message" -ForegroundColor Cyan
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdministrator) {
    throw "Run this script from PowerShell as Administrator."
}

if (-not $PSBoundParameters.ContainsKey("PublicKey")) {
    $PublicKey = Read-Host "Paste the Mac public SSH key, or press Enter to skip"
}
if ($StartWithWindows -eq "Ask") {
    $answer = Read-Host "Start VidReclaim with Windows? [Y/n]"
    $StartWithWindows = $(if ($answer -match "^[Nn]") { "No" } else { "Yes" })
}

Write-Step "Installing the Windows SSH server"
$capability = Get-WindowsCapability -Online |
    Where-Object Name -Like "OpenSSH.Server*"
if ($capability.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}
Set-Service `
    -Name sshd `
    -StartupType $(if ($StartWithWindows -eq "Yes") { "Automatic" } else { "Manual" })
Start-Service sshd
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH SSH Server (sshd)" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort 22 | Out-Null
}

if (-not $SkipFFmpeg -and -not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
    Write-Step "Installing FFmpeg"
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "FFmpeg is missing and winget is unavailable. Install an FFmpeg build with libx265 and hevc_nvenc, then run this script again with -SkipFFmpeg."
    }
    & $winget.Source install `
        --id Gyan.FFmpeg.Shared `
        --exact `
        --accept-package-agreements `
        --accept-source-agreements
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

if ($PublicKey) {
    Write-Step "Adding the Mac SSH key"
    $key = $PublicKey.Trim()
    if ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        $keyPath = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
        New-Item -ItemType File -Force -Path $keyPath | Out-Null
        if (-not (Select-String -SimpleMatch $key -Path $keyPath -Quiet)) {
            Add-Content -Encoding ASCII -Path $keyPath -Value $key
        }
        & icacls.exe $keyPath /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
    }
    else {
        $sshDirectory = Join-Path $HOME ".ssh"
        New-Item -ItemType Directory -Force -Path $sshDirectory | Out-Null
        $keyPath = Join-Path $sshDirectory "authorized_keys"
        New-Item -ItemType File -Force -Path $keyPath | Out-Null
        if (-not (Select-String -SimpleMatch $key -Path $keyPath -Quiet)) {
            Add-Content -Encoding ASCII -Path $keyPath -Value $key
        }
    }
}

Write-Step "Checking encoders"
$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
    throw "FFmpeg is not visible yet. Open a new PowerShell window and run this script again with -SkipFFmpeg."
}
$encoders = (& $ffmpeg.Source -hide_banner -encoders 2>&1 | Out-String)
$x265 = $encoders.Contains("libx265")
$nvenc = $encoders.Contains("hevc_nvenc")

if (-not $SkipTray) {
    Write-Step "Installing VidReclaim"
    $traySource = Join-Path $PSScriptRoot "VidReclaimTray.ps1"
    $iconSource = Join-Path $PSScriptRoot "VidReclaimIcon.png"
    if (-not (Test-Path $traySource)) {
        throw "VidReclaimTray.ps1 is missing from the setup folder."
    }
    $trayRoot = Join-Path $env:LOCALAPPDATA "VidReclaim"
    New-Item -ItemType Directory -Force -Path $trayRoot | Out-Null
    $pidPath = Join-Path $trayRoot "tray.pid"
    if (Test-Path $pidPath) {
        $oldPid = [int](Get-Content -Raw $pidPath)
        $oldProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" `
            -ErrorAction SilentlyContinue
        if (
            $oldProcess -and
            $oldProcess.Name -eq "powershell.exe" -and
            $oldProcess.CommandLine -like "*VidReclaimTray.ps1*"
        ) {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }
    $legacyWorking = Join-Path $HOME ".vidreclaim"
    if (Test-Path $legacyWorking) {
        Remove-Item -Recurse -Force $legacyWorking
    }
    $trayDestination = Join-Path $trayRoot "VidReclaimTray.ps1"
    Copy-Item -Force $traySource $trayDestination
    if (Test-Path $iconSource) {
        Copy-Item -Force $iconSource (Join-Path $trayRoot "VidReclaimIcon.png")
    }

    function New-TrayShortcut {
        param(
            [string]$Path,
            [switch]$StartService
        )
        New-Item `
            -ItemType Directory `
            -Force `
            -Path (Split-Path -Parent $Path) | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = (
            "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass " +
            "-WindowStyle Hidden -File `"$trayDestination`"" +
            $(if ($StartService) { " -StartService" } else { "" })
        )
        $shortcut.WorkingDirectory = $trayRoot
        $shortcut.Save()
    }

    $programShortcut = Join-Path $env:APPDATA (
        "Microsoft\Windows\Start Menu\Programs\VidReclaim.lnk"
    )
    $oldProgramShortcut = Join-Path $env:APPDATA (
        "Microsoft\Windows\Start Menu\Programs\VidReclaim Remote Monitor.lnk"
    )
    $startupShortcut = Join-Path $env:APPDATA (
        "Microsoft\Windows\Start Menu\Programs\Startup\VidReclaim.lnk"
    )
    $oldStartupShortcut = Join-Path $env:APPDATA (
        "Microsoft\Windows\Start Menu\Programs\Startup\VidReclaim Remote Monitor.lnk"
    )
    Remove-Item -Force $oldProgramShortcut -ErrorAction SilentlyContinue
    Remove-Item -Force $oldStartupShortcut -ErrorAction SilentlyContinue
    New-TrayShortcut $programShortcut -StartService
    if ($StartWithWindows -eq "Yes") {
        New-TrayShortcut $startupShortcut
    }
    else {
        Remove-Item -Force $startupShortcut -ErrorAction SilentlyContinue
    }
    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList (
            "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass " +
            "-WindowStyle Hidden -File `"$trayDestination`""
        ) | Out-Null
}

Write-Host ""
Write-Host "Windows PC: $env:COMPUTERNAME"
Write-Host "Windows user: $env:USERNAME"
Write-Host "CPU x265: $(if ($x265) { 'ready' } else { 'missing' })"
Write-Host "NVIDIA HEVC: $(if ($nvenc) { 'ready' } else { 'missing' })"
Write-Host "SSH service: $((Get-Service sshd).Status)"
Write-Host "Start with Windows: $StartWithWindows"
if (-not $PublicKey) {
    Write-Host ""
    Write-Host "Run again with the Mac public key:"
    Write-Host ".\Install-VidReclaimWorker.ps1 -PublicKey 'ssh-ed25519 AAAA...'"
}
