param(
    [Parameter(Mandatory = $true)]
    [string]$JobDir
)

$ErrorActionPreference = "Stop"
$statusPath = Join-Path $JobDir "status.json"
$manifestPath = Join-Path $JobDir "manifest.json"
$progressPath = Join-Path $JobDir "ffmpeg-progress.txt"
$errorPath = Join-Path $JobDir "ffmpeg-error.txt"
$controlPath = Join-Path $JobDir "control.txt"
$outputPath = Join-Path $JobDir "output.part.mkv"

function Write-Status {
    param([hashtable]$Value)
    $Value["updated_at_unix"] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $Value["worker_pid"] = $PID
    $temporary = "$statusPath.tmp"
    $Value | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 $temporary
    Move-Item -Force $temporary $statusPath
}

try {
    $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
    $ffmpeg = Get-Command ffmpeg.exe -ErrorAction Stop
    Remove-Item -Force -ErrorAction SilentlyContinue $progressPath, $errorPath, $outputPath
    Write-Status @{ state = "starting"; fraction = 0.0; speed_x = $null }
    $arguments = @()
    foreach ($argument in $manifest.arguments) {
        $arguments += [string]$argument
    }
    $process = Start-Process `
        -FilePath $ffmpeg.Source `
        -ArgumentList $arguments `
        -WorkingDirectory $JobDir `
        -RedirectStandardOutput $progressPath `
        -RedirectStandardError $errorPath `
        -PassThru `
        -NoNewWindow
    Write-Status @{
        state = "running"
        fraction = 0.0
        speed_x = $null
        encoder_pid = $process.Id
    }
    while (-not $process.HasExited) {
        if (Test-Path $controlPath) {
            $action = (Get-Content -Raw $controlPath).Trim().ToLowerInvariant()
            if ($action -in @("pause", "cancel", "skip")) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                $process.WaitForExit()
                Remove-Item -Force -ErrorAction SilentlyContinue $outputPath
                $state = @{
                    pause = "paused"
                    cancel = "cancelled"
                    skip = "skipped"
                }[$action]
                Write-Status @{ state = $state; fraction = 0.0; speed_x = $null }
                exit 0
            }
        }
        $fraction = 0.0
        $speed = $null
        if (Test-Path $progressPath) {
            $lines = Get-Content $progressPath -ErrorAction SilentlyContinue
            $timeLine = $lines | Where-Object { $_ -like "out_time_us=*" } |
                Select-Object -Last 1
            $speedLine = $lines | Where-Object { $_ -like "speed=*" } |
                Select-Object -Last 1
            if ($timeLine -and [double]$manifest.duration -gt 0) {
                $microseconds = [double]($timeLine.Split("=", 2)[1])
                $fraction = [Math]::Min(
                    0.999,
                    [Math]::Max(0.0, $microseconds / 1000000.0 / [double]$manifest.duration)
                )
            }
            if ($speedLine) {
                $rawSpeed = $speedLine.Split("=", 2)[1].Trim().TrimEnd("x")
                $parsedSpeed = 0.0
                if ([double]::TryParse(
                    $rawSpeed,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$parsedSpeed
                )) {
                    $speed = $parsedSpeed
                }
            }
        }
        Write-Status @{
            state = "running"
            fraction = $fraction
            speed_x = $speed
            encoder_pid = $process.Id
        }
        Start-Sleep -Milliseconds 750
        $process.Refresh()
    }
    $process.WaitForExit()
    $process.Refresh()
    $exitCode = $process.ExitCode
    $progressEnded = $false
    if (Test-Path $progressPath) {
        $progressEnded = [bool](
            Get-Content $progressPath -ErrorAction SilentlyContinue |
            Where-Object { $_ -eq "progress=end" } |
            Select-Object -First 1
        )
    }
    if (
        ($exitCode -ne $null -and $exitCode -ne 0) -or
        -not $progressEnded -or
        -not (Test-Path $outputPath)
    ) {
        $tail = ""
        if (Test-Path $errorPath) {
            $tail = (Get-Content $errorPath -Tail 30) -join "`n"
        }
        $exitText = $(if ($exitCode -eq $null) { "unknown" } else { $exitCode })
        Write-Status @{
            state = "error"
            fraction = 0.0
            speed_x = $null
            message = "ffmpeg exited ${exitText}: $tail"
        }
        exit 1
    }
    Write-Status @{
        state = "complete"
        fraction = 1.0
        speed_x = $null
        output_bytes = (Get-Item $outputPath).Length
    }
}
catch {
    Write-Status @{
        state = "error"
        fraction = 0.0
        speed_x = $null
        message = $_.Exception.Message
    }
    exit 1
}
