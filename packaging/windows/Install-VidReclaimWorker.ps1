[CmdletBinding()]
param(
    [string]$PublicKey = "",
    [switch]$SkipFFmpeg
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

Write-Step "Installing the Windows SSH server"
$capability = Get-WindowsCapability -Online |
    Where-Object Name -Like "OpenSSH.Server*"
if ($capability.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
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
    $env:Path = (
        [Environment]::GetEnvironmentVariable("Path", "Machine")
        + ";"
        + [Environment]::GetEnvironmentVariable("Path", "User")
    )
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

Write-Host ""
Write-Host "Windows PC: $env:COMPUTERNAME"
Write-Host "Windows user: $env:USERNAME"
Write-Host "CPU x265: $(if ($x265) { 'ready' } else { 'missing' })"
Write-Host "NVIDIA HEVC: $(if ($nvenc) { 'ready' } else { 'missing' })"
Write-Host "SSH service: $((Get-Service sshd).Status)"
if (-not $PublicKey) {
    Write-Host ""
    Write-Host "Run again with the Mac public key:"
    Write-Host ".\Install-VidReclaimWorker.ps1 -PublicKey 'ssh-ed25519 AAAA...'"
}
