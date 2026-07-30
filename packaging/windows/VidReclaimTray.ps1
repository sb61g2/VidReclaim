[CmdletBinding()]
param(
    [switch]$StartService
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$jobRoot = Join-Path $HOME ".vidreclaim\jobs"
$scriptPath = $MyInvocation.MyCommand.Path
$installRoot = Split-Path -Parent $scriptPath
$pidPath = Join-Path $installRoot "tray.pid"
$startupDirectory = Join-Path $env:APPDATA (
    "Microsoft\Windows\Start Menu\Programs\Startup"
)
$startupShortcut = Join-Path $startupDirectory "VidReclaim Remote Monitor.lnk"
$created = $false
$mutex = New-Object `
    -TypeName Threading.Mutex `
    -ArgumentList $true, "Local\VidReclaimTray", ([ref]$created)
if (-not $created) {
    exit 0
}
Set-Content -Encoding ASCII -Path $pidPath -Value $PID

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    try {
        return Get-Content -Raw $Path | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Format-Bytes {
    param([long]$Value)
    if ($Value -ge 1TB) {
        return "{0:N1} TB" -f ($Value / 1TB)
    }
    if ($Value -ge 1GB) {
        return "{0:N1} GB" -f ($Value / 1GB)
    }
    if ($Value -ge 1MB) {
        return "{0:N1} MB" -f ($Value / 1MB)
    }
    if ($Value -ge 1KB) {
        return "{0:N1} KB" -f ($Value / 1KB)
    }
    return "$Value B"
}

function Get-RemoteJobs {
    $jobs = @()
    if (-not (Test-Path $jobRoot)) {
        return $jobs
    }
    foreach ($directory in Get-ChildItem $jobRoot -Directory -ErrorAction SilentlyContinue) {
        $manifest = Read-JsonFile (Join-Path $directory.FullName "manifest.json")
        $status = Read-JsonFile (Join-Path $directory.FullName "status.json")
        $source = Get-ChildItem `
            $directory.FullName `
            -Filter "source.*" `
            -File `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $sourceBytes = 0
        if ($source) {
            $sourceBytes = [long]$source.Length
        }
        $totalBytes = 0
        if ($manifest -and $manifest.source_bytes) {
            $totalBytes = [long]$manifest.source_bytes
        }
        $state = "Waiting"
        $fraction = 0.0
        $controlAction = ""
        $controlPath = Join-Path $directory.FullName "control.txt"
        if (Test-Path $controlPath) {
            try {
                $controlAction = (
                    Get-Content -Raw $controlPath
                ).Trim().ToLowerInvariant()
            }
            catch {}
        }
        if ($status -and $status.state) {
            $state = [string]$status.state
            if ($status.fraction -ne $null) {
                $fraction = [double]$status.fraction
            }
        }
        elseif ($controlAction -eq "cancel") {
            $state = "cancelled"
        }
        elseif ($controlAction -eq "pause") {
            $state = "paused"
        }
        elseif ($controlAction -eq "skip") {
            $state = "skipped"
        }
        elseif ($manifest -or $source) {
            $state = "uploading"
            if ($totalBytes -gt 0) {
                $fraction = [Math]::Min(1.0, $sourceBytes / $totalBytes)
            }
        }
        if (
            $controlAction -eq "cancel" -and
            $state -in @("starting", "running", "uploading", "waiting")
        ) {
            $state = "cancelling"
        }
        $name = $directory.Name
        if ($manifest -and $manifest.source_display_name) {
            $name = [string]$manifest.source_display_name
        }
        $encoder = ""
        if ($manifest -and $manifest.encoder) {
            $encoder = [string]$manifest.encoder
        }
        $workerPid = 0
        $encoderPid = 0
        if ($status -and $status.worker_pid) {
            $workerPid = [int]$status.worker_pid
        }
        if ($status -and $status.encoder_pid) {
            $encoderPid = [int]$status.encoder_pid
        }
        $updated = $directory.LastWriteTime
        if ($status -and $status.updated_at_unix) {
            $updated = [DateTimeOffset]::FromUnixTimeSeconds(
                [long]$status.updated_at_unix
            ).LocalDateTime
        }
        $jobs += [PSCustomObject]@{
            Id = $directory.Name
            Name = $name
            State = $state.ToLowerInvariant()
            Fraction = [Math]::Max(0.0, [Math]::Min(1.0, $fraction))
            Encoder = $encoder
            SourceBytes = $sourceBytes
            TotalBytes = $totalBytes
            WorkerPid = $workerPid
            EncoderPid = $encoderPid
            Updated = $updated
            Directory = $directory.FullName
        }
    }
    return @($jobs | Sort-Object Updated -Descending)
}

function Set-JobControl {
    param([string]$Action)
    foreach ($job in Get-RemoteJobs) {
        $canPause = $job.State -in @(
            "starting", "running", "uploading", "waiting"
        )
        $canCancel = $canPause -or $job.State -eq "paused"
        if (
            ($Action -eq "pause" -and $canPause) -or
            ($Action -eq "cancel" -and $canCancel)
        ) {
            Set-Content `
                -Encoding ASCII `
                -Path (Join-Path $job.Directory "control.txt") `
                -Value $Action
        }
    }
}

function Remove-FinishedStaging {
    foreach ($job in Get-RemoteJobs) {
        if ($job.State -in @("complete", "cancelled", "error", "skipped")) {
            Remove-Item -Recurse -Force $job.Directory -ErrorAction SilentlyContinue
        }
    }
}

function Open-JobFolder {
    New-Item -ItemType Directory -Force -Path $jobRoot | Out-Null
    Start-Process explorer.exe $jobRoot
}

function New-TrayShortcut {
    param([string]$Path)
    New-Item `
        -ItemType Directory `
        -Force `
        -Path (Split-Path -Parent $Path) | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = (
        "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass " +
        "-WindowStyle Hidden -File `"$scriptPath`""
    )
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Save()
}

function Invoke-ElevatedPowerShell {
    param([string]$Script)
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($Script)
    )
    try {
        $process = Start-Process `
            -FilePath "powershell.exe" `
            -Verb RunAs `
            -ArgumentList (
                "-NoLogo -NoProfile -ExecutionPolicy Bypass " +
                "-EncodedCommand $encoded"
            ) `
            -Wait `
            -PassThru
        return $process.ExitCode -eq 0
    }
    catch {
        return $false
    }
}

function Set-StartWithWindows {
    param([bool]$Enabled)
    $serviceCommand = "Set-Service sshd -StartupType Manual"
    if ($Enabled) {
        $serviceCommand = (
            "Set-Service sshd -StartupType Automatic; " +
            "Start-Service sshd"
        )
    }
    if (-not (Invoke-ElevatedPowerShell $serviceCommand)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The startup preference was not changed.",
            "Start with Windows",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }
    if ($Enabled) {
        New-TrayShortcut $startupShortcut
    }
    else {
        Remove-Item -Force $startupShortcut -ErrorAction SilentlyContinue
    }
}

function Set-SshServiceState {
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Windows SSH service is not installed.",
            "SSH service",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }
    $command = "Start-Service sshd"
    if ($service.Status -eq "Running") {
        $command = "Stop-Service sshd"
    }
    if (-not (Invoke-ElevatedPowerShell $command)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The SSH service was not changed.",
            "SSH service",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Stop-VidReclaimCompletely {
    $jobs = @(Get-RemoteJobs)
    Set-JobControl "cancel"
    Start-Sleep -Seconds 3
    foreach ($job in $jobs) {
        if ($job.EncoderPid -gt 0) {
            $encoderProcess = Get-CimInstance `
                Win32_Process `
                -Filter "ProcessId=$($job.EncoderPid)" `
                -ErrorAction SilentlyContinue
            if (
                $encoderProcess -and
                $encoderProcess.Name -eq "ffmpeg.exe" -and
                $encoderProcess.CommandLine -like "*output.part.mkv*"
            ) {
                Stop-Process `
                    -Id $job.EncoderPid `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        if (
            $job.WorkerPid -gt 0 -and
            $job.State -in @("starting", "running", "cancelling")
        ) {
            $workerProcess = Get-CimInstance `
                Win32_Process `
                -Filter "ProcessId=$($job.WorkerPid)" `
                -ErrorAction SilentlyContinue
            if (
                $workerProcess -and
                $workerProcess.Name -eq "powershell.exe"
            ) {
                Stop-Process `
                    -Id $job.WorkerPid `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    if (-not (Invoke-ElevatedPowerShell "Stop-Service sshd -Force")) {
        [System.Windows.Forms.MessageBox]::Show(
            "Remote access could not be stopped. The tray monitor will remain open.",
            "Stop VidReclaim completely",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

if ($StartService) {
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Running") {
        Invoke-ElevatedPowerShell "Start-Service sshd" | Out-Null
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "VidReclaim Remote Jobs"
$form.Size = New-Object Drawing.Size(780, 390)
$form.MinimumSize = New-Object Drawing.Size(650, 300)
$form.StartPosition = "CenterScreen"
$form.ShowInTaskbar = $true

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.AutoSize = $true
$summaryLabel.Location = New-Object Drawing.Point(12, 12)
$summaryLabel.Font = New-Object Drawing.Font(
    $summaryLabel.Font,
    [Drawing.FontStyle]::Bold
)
$form.Controls.Add($summaryLabel)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(12, 38)
$grid.Size = New-Object Drawing.Size(740, 260)
$grid.Anchor = "Top,Bottom,Left,Right"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoGenerateColumns = $false
$grid.Columns.Add("Name", "File") | Out-Null
$grid.Columns["Name"].AutoSizeMode = "Fill"
$grid.Columns.Add("State", "State") | Out-Null
$grid.Columns["State"].Width = 90
$grid.Columns.Add("Progress", "Progress") | Out-Null
$grid.Columns["Progress"].Width = 75
$grid.Columns.Add("Encoder", "Encoder") | Out-Null
$grid.Columns["Encoder"].Width = 70
$grid.Columns.Add("Staged", "Staged") | Out-Null
$grid.Columns["Staged"].Width = 90
$grid.Columns.Add("Updated", "Updated") | Out-Null
$grid.Columns["Updated"].Width = 125
$form.Controls.Add($grid)

$openButton = New-Object System.Windows.Forms.Button
$openButton.Text = "Open Folder"
$openButton.Location = New-Object Drawing.Point(12, 310)
$openButton.Anchor = "Bottom,Left"
$openButton.Add_Click({ Open-JobFolder })
$form.Controls.Add($openButton)

$pauseButton = New-Object System.Windows.Forms.Button
$pauseButton.Text = "Pause Active"
$pauseButton.Location = New-Object Drawing.Point(108, 310)
$pauseButton.Anchor = "Bottom,Left"
$pauseButton.Add_Click({ Set-JobControl "pause" })
$form.Controls.Add($pauseButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "Cancel Active"
$cancelButton.Location = New-Object Drawing.Point(212, 310)
$cancelButton.Anchor = "Bottom,Left"
$cancelButton.Add_Click({
    Set-JobControl "cancel"
})
$form.Controls.Add($cancelButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "Remove Finished"
$clearButton.Location = New-Object Drawing.Point(324, 310)
$clearButton.Size = New-Object Drawing.Size(112, 23)
$clearButton.Anchor = "Bottom,Left"
$clearButton.Add_Click({ Remove-FinishedStaging })
$form.Controls.Add($clearButton)

$shutdownButton = New-Object System.Windows.Forms.Button
$shutdownButton.Text = "Shut Down"
$shutdownButton.Location = New-Object Drawing.Point(640, 310)
$shutdownButton.Size = New-Object Drawing.Size(112, 23)
$shutdownButton.Anchor = "Bottom,Right"
$shutdownButton.Add_Click({ Stop-VidReclaimCompletely })
$form.Controls.Add($shutdownButton)

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$notify.Text = "VidReclaim"
$iconPath = Join-Path $installRoot "VidReclaimIcon.png"
$trayBitmap = $null
$trayIcon = $null
if (Test-Path $iconPath) {
    $trayBitmap = New-Object Drawing.Bitmap($iconPath)
    $trayIcon = [Drawing.Icon]::FromHandle($trayBitmap.GetHicon())
    $notify.Icon = $trayIcon
}
else {
    $notify.Icon = [Drawing.SystemIcons]::Application
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
$statusItem.Text = "No remote jobs"
$statusItem.Enabled = $false
$menu.Items.Add($statusItem) | Out-Null
$menu.Items.Add("-") | Out-Null
$showItem = $menu.Items.Add("Show Jobs")
$showItem.Add_Click({
    $form.Show()
    $form.Activate()
})
$openItem = $menu.Items.Add("Open Work Folder")
$openItem.Add_Click({ Open-JobFolder })
$pauseItem = $menu.Items.Add("Pause Active Jobs")
$pauseItem.Add_Click({ Set-JobControl "pause" })
$cancelItem = $menu.Items.Add("Cancel Active Jobs")
$cancelItem.Add_Click({
    Set-JobControl "cancel"
})
$clearItem = $menu.Items.Add("Remove Finished Staging...")
$clearItem.Add_Click({ Remove-FinishedStaging })
$menu.Items.Add("-") | Out-Null
$startItem = $menu.Items.Add("Start with Windows")
$startItem.CheckOnClick = $false
$startItem.Add_Click({
    Set-StartWithWindows (-not (Test-Path $startupShortcut))
})
$sshItem = $menu.Items.Add("Stop SSH Service...")
$sshItem.Add_Click({ Set-SshServiceState })
$menu.Items.Add("-") | Out-Null
$stopAllItem = $menu.Items.Add("Shut Down VidReclaim...")
$stopAllItem.Add_Click({ Stop-VidReclaimCompletely })
$exitItem = $menu.Items.Add("Close Monitor Only")
$exitItem.Add_Click({
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$notify.ContextMenuStrip = $menu
$notify.Add_DoubleClick({
    $form.Show()
    $form.Activate()
})

$knownStates = @{}
function Update-Display {
    $jobs = @(Get-RemoteJobs)
    $active = @($jobs | Where-Object {
        $_.State -in @(
            "starting", "running", "uploading", "waiting", "cancelling"
        )
    })
    $cancellable = @($jobs | Where-Object {
        $_.State -in @(
            "starting", "running", "uploading", "waiting", "paused"
        )
    })
    $summaryLabel.Text = (
        "{0} active - {1} staged job{2}" -f
        $active.Count,
        $jobs.Count,
        $(if ($jobs.Count -eq 1) { "" } else { "s" })
    )
    $statusItem.Text = "{0} active - {1} staged" -f $active.Count, $jobs.Count
    $notify.Text = (
        "VidReclaim: {0} active, {1} staged" -f $active.Count, $jobs.Count
    )
    $pauseItem.Enabled = $active.Count -gt 0
    $cancelItem.Enabled = $cancellable.Count -gt 0
    $pauseButton.Enabled = $active.Count -gt 0
    $cancelButton.Enabled = $cancellable.Count -gt 0
    $service = Get-Service sshd -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        $sshItem.Text = "Stop SSH Service..."
    }
    else {
        $sshItem.Text = "Start SSH Service..."
    }
    $startItem.Checked = Test-Path $startupShortcut

    $grid.Rows.Clear()
    foreach ($job in $jobs) {
        $staged = Format-Bytes $job.SourceBytes
        if ($job.TotalBytes -gt 0) {
            $staged = "{0} / {1}" -f (
                Format-Bytes $job.SourceBytes
            ), (
                Format-Bytes $job.TotalBytes
            )
        }
        $grid.Rows.Add(
            $job.Name,
            $job.State,
            ("{0:N0}%" -f ($job.Fraction * 100)),
            $job.Encoder,
            $staged,
            $job.Updated.ToString("g")
        ) | Out-Null
        $previous = $knownStates[$job.Id]
        if ($previous -and $previous -ne $job.State) {
            if ($job.State -eq "complete") {
                $notify.ShowBalloonTip(
                    4000,
                    "VidReclaim",
                    "$($job.Name) finished encoding.",
                    [System.Windows.Forms.ToolTipIcon]::Info
                )
            }
            elseif ($job.State -eq "error") {
                $notify.ShowBalloonTip(
                    5000,
                    "VidReclaim",
                    "$($job.Name) needs attention.",
                    [System.Windows.Forms.ToolTipIcon]::Error
                )
            }
        }
        $knownStates[$job.Id] = $job.State
    }
}

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
        $eventArgs.Cancel = $true
        $form.Hide()
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({ Update-Display })
$timer.Start()
Update-Display

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    if ($trayIcon) {
        $trayIcon.Dispose()
    }
    if ($trayBitmap) {
        $trayBitmap.Dispose()
    }
    Remove-Item -Force $pidPath -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
