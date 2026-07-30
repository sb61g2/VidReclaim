from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import time
from dataclasses import asdict, dataclass
from importlib.resources import files
from pathlib import Path
from typing import Callable

from .model import Plan, Profile
from .planner import ffmpeg_video_args
from .util import CommandError


ProgressCallback = Callable[[float, float | None], None]
ControlCallback = Callable[[], str]
StageCallback = Callable[[str], None]


@dataclass(frozen=True)
class RemoteConfig:
    host: str
    user: str
    port: int = 22
    encoder: str = "x265"
    identity_file: Path | None = None

    @property
    def target(self) -> str:
        _validate_component("remote user", self.user, r"[A-Za-z0-9_.-]+")
        _validate_component("remote host", self.host, r"[A-Za-z0-9_.:-]+")
        if not 1 <= self.port <= 65535:
            raise CommandError("Remote SSH port must be between 1 and 65535")
        if self.encoder not in {"nvenc", "x265"}:
            raise CommandError("Remote encoder must be nvenc or x265")
        return f"{self.user}@{self.host}"


class RemoteEncodeControl(CommandError):
    def __init__(self, action: str) -> None:
        self.action = action
        super().__init__(f"remote encode {action} by user")


def config_from_settings(settings: dict[str, object]) -> RemoteConfig | None:
    host = str(settings.get("remote_host") or "").strip()
    if not host:
        return None
    identity = str(settings.get("remote_identity_file") or "").strip()
    return RemoteConfig(
        host=host,
        user=str(settings.get("remote_user") or "").strip(),
        port=int(settings.get("remote_port") or 22),
        encoder=str(settings.get("remote_encoder") or "x265"),
        identity_file=Path(identity).expanduser() if identity else None,
    )


def _validate_component(label: str, value: str, pattern: str) -> None:
    if not value or value.startswith("-") or re.fullmatch(pattern, value) is None:
        raise CommandError(f"Invalid {label}: {value!r}")


def _ssh_base(config: RemoteConfig) -> list[str]:
    args = [
        "/usr/bin/ssh",
        "-p", str(config.port),
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=accept-new",
    ]
    if config.identity_file:
        args += ["-i", str(config.identity_file)]
    return [*args, config.target]


def _powershell_encoded(script: str) -> list[str]:
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    return [
        "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded,
    ]


def _ssh_text(
    config: RemoteConfig,
    script: str,
    *,
    check: bool = True,
) -> str:
    completed = subprocess.run(
        [*_ssh_base(config), *_powershell_encoded(script)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if check and completed.returncode:
        detail = (completed.stderr or completed.stdout).strip()
        raise CommandError(
            f"Could not reach Windows worker at {config.target}: {detail}"
        )
    return completed.stdout.strip()


def _upload(
    config: RemoteConfig,
    data_path: Path,
    remote_path: str,
    *,
    offset: int = 0,
    stage: StageCallback | None = None,
) -> None:
    if stage:
        remaining = data_path.stat().st_size - offset
        verb = "Resuming upload" if offset else "Uploading"
        stage(f"{verb} {data_path.name} ({remaining:,} bytes remaining)")
    script = f"""
$path = Join-Path $HOME '{remote_path}'
$parent = Split-Path -Parent $path
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$source = [Console]::OpenStandardInput()
$target = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {{
    $target.SetLength({offset})
    [void]$target.Seek({offset}, [IO.SeekOrigin]::Begin)
    $source.CopyTo($target)
}} finally {{ $target.Dispose() }}
"""
    process = subprocess.Popen(
        [*_ssh_base(config), *_powershell_encoded(script)],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    assert process.stdin is not None
    try:
        total = data_path.stat().st_size
        sent = offset
        next_report = sent + 64 * 1024 * 1024
        with data_path.open("rb") as source:
            source.seek(offset)
            while chunk := source.read(4 * 1024 * 1024):
                process.stdin.write(chunk)
                sent += len(chunk)
                if stage and (sent >= next_report or sent == total):
                    stage(
                        f"Uploading {data_path.name} "
                        f"({sent / max(total, 1):.0%})"
                    )
                    next_report = sent + 64 * 1024 * 1024
        process.stdin.close()
        error = process.stderr.read().decode("utf-8", errors="replace")
        return_code = process.wait()
    except BaseException:
        process.kill()
        process.wait()
        raise
    if return_code:
        raise CommandError(f"Remote upload failed: {error.strip()}")


def _download(
    config: RemoteConfig,
    remote_path: str,
    destination: Path,
    *,
    stage: StageCallback | None = None,
) -> None:
    offset = destination.stat().st_size if destination.exists() else 0
    remote_size = int(_ssh_text(
        config,
        f"""
$path = Join-Path $HOME '{remote_path}'
if (Test-Path $path) {{ (Get-Item $path).Length }} else {{ -1 }}
""",
    ) or -1)
    if remote_size < 0:
        raise CommandError("Remote output is missing")
    if offset > remote_size:
        destination.unlink(missing_ok=True)
        offset = 0
    if stage:
        verb = "Resuming download" if offset else "Downloading result"
        stage(f"{verb} ({offset / max(remote_size, 1):.0%})")
    script = f"""
$path = Join-Path $HOME '{remote_path}'
$source = [IO.File]::OpenRead($path)
$target = [Console]::OpenStandardOutput()
try {{
    if ({offset} -gt $source.Length) {{ exit 9 }}
    [void]$source.Seek({offset}, [IO.SeekOrigin]::Begin)
    $source.CopyTo($target)
}} finally {{ $source.Dispose() }}
"""
    process = subprocess.Popen(
        [*_ssh_base(config), *_powershell_encoded(script)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    try:
        received = offset
        next_report = received + 64 * 1024 * 1024
        with destination.open("ab") as target:
            while chunk := process.stdout.read(4 * 1024 * 1024):
                target.write(chunk)
                received += len(chunk)
                if stage and (
                    received >= next_report or received == remote_size
                ):
                    stage(
                        f"Downloading result "
                        f"({received / max(remote_size, 1):.0%})"
                    )
                    next_report = received + 64 * 1024 * 1024
        error = process.stderr.read().decode("utf-8", errors="replace")
        return_code = process.wait()
    except BaseException:
        process.kill()
        process.wait()
        raise
    if return_code:
        if return_code == 9:
            destination.unlink(missing_ok=True)
        raise CommandError(f"Remote download failed: {error.strip()}")


def remote_job_id(plan: Plan, config: RemoteConfig) -> str:
    source = plan.media.source.path
    stat = source.stat()
    identity = {
        "source": str(source.resolve()),
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "candidate": asdict(plan.candidate) if plan.candidate else None,
        "encoder": config.encoder,
        "protocol": 2,
    }
    payload = json.dumps(identity, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:24]


def _remote_video_args(plan: Plan, config: RemoteConfig, profile: Profile, preset: str) -> list[str]:
    assert plan.candidate is not None
    return ffmpeg_video_args(
        plan.media,
        plan.candidate,
        encoder="nvenc" if config.encoder == "nvenc" else "x265",
        preset=preset,
        profile=profile,
    )


def _job_manifest(
    plan: Plan,
    config: RemoteConfig,
    profile: Profile,
    preset: str,
    source_name: str,
) -> dict[str, object]:
    media = plan.media
    arguments = [
        "-hide_banner", "-loglevel", "warning", "-nostats", "-y",
        "-i", source_name,
        "-map", f"0:{media.video_stream_index}",
        "-map", "0:a?", "-map", "0:s?", "-map", "0:t?",
        *_remote_video_args(plan, config, profile, preset),
        "-c:a", "copy", "-c:s", "copy", "-c:t", "copy",
        "-map_metadata", "0", "-map_chapters", "0",
        "-max_interleave_delta", "0",
        "-progress", "pipe:1", "output.part.mkv",
    ]
    return {
        "schema": 1,
        "duration": media.duration,
        "arguments": arguments,
        "encoder": config.encoder,
    }


def _write_temp(path: Path, content: str | bytes) -> None:
    if isinstance(content, str):
        path.write_text(content, encoding="utf-8")
    else:
        path.write_bytes(content)


def _job_state(config: RemoteConfig, job_id: str) -> dict[str, object]:
    raw = _ssh_text(
        config,
        f"""
$path = Join-Path $HOME '.vidreclaim\\jobs\\{job_id}\\status.json'
if (Test-Path $path) {{ Get-Content -Raw $path }} else {{ '{{"state":"missing"}}' }}
""",
    )
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise CommandError(f"Windows worker returned invalid status: {raw}") from error


def _start_job(config: RemoteConfig, job_id: str) -> None:
    _ssh_text(
        config,
        f"""
$job = Join-Path $HOME '.vidreclaim\\jobs\\{job_id}'
$statusPath = Join-Path $job 'status.json'
$running = $false
if (Test-Path $statusPath) {{
    try {{
        $status = Get-Content -Raw $statusPath | ConvertFrom-Json
        if ($status.state -eq 'running' -and $status.worker_pid) {{
            $running = $null -ne (Get-Process -Id $status.worker_pid -ErrorAction SilentlyContinue)
        }}
        if ($status.state -eq 'complete' -and (Test-Path (Join-Path $job 'output.part.mkv'))) {{
            exit 0
        }}
    }} catch {{}}
}}
if (-not $running) {{
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $job 'control.txt')
    $worker = Join-Path $job 'worker.ps1'
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$worker,'-JobDir',$job)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}}
""",
    )


def _send_control(config: RemoteConfig, job_id: str, action: str) -> None:
    _ssh_text(
        config,
        f"""
$path = Join-Path $HOME '.vidreclaim\\jobs\\{job_id}\\control.txt'
Set-Content -Encoding ASCII -Path $path -Value '{action}'
""",
        check=False,
    )


def remote_cleanup(config: RemoteConfig, job_id: str) -> None:
    _ssh_text(
        config,
        f"""
$path = Join-Path $HOME '.vidreclaim\\jobs\\{job_id}'
if (Test-Path $path) {{ Remove-Item -Recurse -Force $path }}
""",
        check=False,
    )


def remote_doctor(config: RemoteConfig) -> dict[str, object]:
    raw = _ssh_text(
        config,
        """
$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
$gpu = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
$encoders = ''
if ($ffmpeg) { $encoders = (& $ffmpeg.Source -hide_banner -encoders 2>&1 | Out-String) }
$gpuName = ''
if ($gpu) { $gpuName = (& $gpu.Source --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1) }
[ordered]@{
    computer = $env:COMPUTERNAME
    ffmpeg = [bool]$ffmpeg
    x265 = $encoders.Contains('libx265')
    nvenc = $encoders.Contains('hevc_nvenc')
    gpu = $gpuName.Trim()
} | ConvertTo-Json -Compress
""",
    )
    try:
        result = json.loads(raw)
    except json.JSONDecodeError as error:
        raise CommandError(f"Windows worker check returned invalid data: {raw}") from error
    required = "nvenc" if config.encoder == "nvenc" else "x265"
    if not result.get("ffmpeg") or not result.get(required):
        raise CommandError(
            f"Windows worker is reachable but FFmpeg {required} support is missing"
        )
    return result


def remote_encode(
    plan: Plan,
    temporary: Path,
    *,
    config: RemoteConfig,
    profile: Profile,
    preset: str,
    progress: ProgressCallback | None = None,
    control: ControlCallback | None = None,
    stage: StageCallback | None = None,
) -> str:
    if plan.media.source.kind != "file":
        raise CommandError("Remote encoding currently supports regular video files only")
    config.target
    job_id = remote_job_id(plan, config)
    job_root = f".vidreclaim/jobs/{job_id}"
    source_suffix = plan.media.source.path.suffix.lower()
    if re.fullmatch(r"\.[a-z0-9]{1,8}", source_suffix) is None:
        source_suffix = ".media"
    source_name = f"source{source_suffix}"
    state = _job_state(config, job_id)
    if state.get("state") != "complete":
        remote_size = _ssh_text(
            config,
            f"""
$path = Join-Path $HOME '{job_root}/{source_name}'
if (Test-Path $path) {{ (Get-Item $path).Length }} else {{ -1 }}
""",
        )
        source_size = plan.media.source.path.stat().st_size
        staged_size = int(remote_size or -1)
        if staged_size != source_size:
            offset = staged_size if 0 <= staged_size < source_size else 0
            _upload(
                config,
                plan.media.source.path,
                f"{job_root}/{source_name}",
                offset=offset,
                stage=stage,
            )
        import tempfile

        with tempfile.TemporaryDirectory(prefix="vidreclaim-remote-") as folder:
            root = Path(folder)
            manifest = root / "manifest.json"
            worker = root / "worker.ps1"
            _write_temp(
                manifest,
                json.dumps(
                    _job_manifest(plan, config, profile, preset, source_name),
                    separators=(",", ":"),
                ),
            )
            worker_source = files("vidreclaim").joinpath("windows_worker.ps1")
            _write_temp(worker, worker_source.read_bytes())
            _upload(config, manifest, f"{job_root}/manifest.json")
            _upload(config, worker, f"{job_root}/worker.ps1")
        if stage:
            stage(f"Encoding on {config.host}")
        _start_job(config, job_id)

    failures = 0
    last_action = "run"
    while True:
        action = control() if control else "run"
        if action in {"pause", "cancel", "skip"} and action != last_action:
            _send_control(config, job_id, action)
            last_action = action
        try:
            state = _job_state(config, job_id)
            failures = 0
        except CommandError:
            failures += 1
            if failures >= 8:
                raise
            time.sleep(1)
            continue
        status = str(state.get("state") or "missing")
        if progress and status == "running":
            progress(
                float(state.get("fraction") or 0.0),
                (
                    float(state["speed_x"])
                    if state.get("speed_x") is not None else None
                ),
            )
        if status == "complete":
            break
        if status in {"paused", "cancelled", "skipped"}:
            raise RemoteEncodeControl("pause" if status == "paused" else status)
        if status == "error":
            raise CommandError(
                f"Windows encode failed: {state.get('message') or 'unknown error'}"
            )
        if status == "missing":
            _start_job(config, job_id)
        time.sleep(0.75)

    download_partial = temporary.with_name(
        f".{temporary.stem}.remote-{job_id}.download"
    )
    _download(
        config,
        f"{job_root}/output.part.mkv",
        download_partial,
        stage=stage,
    )
    download_partial.replace(temporary)
    return job_id
