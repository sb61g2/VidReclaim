from __future__ import annotations

import base64
import hashlib
import json
import re
import subprocess
import tempfile
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


def _sftp_base(config: RemoteConfig, batch_path: Path) -> list[str]:
    args = [
        "/usr/bin/sftp",
        "-P", str(config.port),
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=8",
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=accept-new",
    ]
    if config.identity_file:
        args += ["-i", str(config.identity_file)]
    return [*args, "-b", str(batch_path), config.target]


def _sftp_quote(value: str) -> str:
    if "\n" in value or "\r" in value:
        raise CommandError("SFTP paths cannot contain line breaks")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _powershell_encoded(script: str) -> list[str]:
    script = (
        "$ProgressPreference='SilentlyContinue'\n"
        "$InformationPreference='SilentlyContinue'\n"
        + script
    )
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
    completed: subprocess.CompletedProcess[str] | None = None
    for attempt in range(2):
        completed = subprocess.run(
            [*_ssh_base(config), *_powershell_encoded(script)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        detail = (completed.stderr or completed.stdout).strip()
        first_use_noise = (
            completed.returncode != 0
            and "Preparing modules for first use." in detail
            and "<S S=\"Error\">" not in detail
        )
        if first_use_noise and attempt == 0:
            continue
        break
    assert completed is not None
    if check and completed.returncode:
        detail = (completed.stderr or completed.stdout).strip()
        raise CommandError(
            f"Could not reach Windows worker at {config.target}: {detail}"
        )
    return completed.stdout.strip()


def _remote_size(config: RemoteConfig, remote_path: str) -> int:
    raw = _ssh_text(
        config,
        f"""
$path = Join-Path $HOME '{remote_path}'
if (Test-Path $path) {{ (Get-Item $path).Length }} else {{ -1 }}
""",
    )
    try:
        return int(raw or -1)
    except ValueError as error:
        raise CommandError(f"Windows returned an invalid file size: {raw}") from error


def _remote_transfer_state(
    config: RemoteConfig,
    remote_path: str,
) -> tuple[int, str]:
    parent = remote_path.rsplit("/", 1)[0]
    raw = _ssh_text(
        config,
        f"""
$path = Join-Path $HOME '{remote_path}'
$control = Join-Path $HOME '{parent}/control.txt'
$lease = Join-Path $HOME '{parent}/client.lease'
if (Test-Path (Split-Path -Parent $lease)) {{
    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
        Set-Content -Encoding ASCII $lease
}}
[ordered]@{{
    size = $(if (Test-Path $path) {{ (Get-Item $path).Length }} else {{ -1 }})
    action = $(if (Test-Path $control) {{ (Get-Content -Raw $control).Trim().ToLowerInvariant() }} else {{ '' }})
}} | ConvertTo-Json -Compress
""",
    )
    try:
        state = json.loads(raw)
        return int(state.get("size", -1)), str(state.get("action") or "")
    except (json.JSONDecodeError, TypeError, ValueError) as error:
        raise CommandError(
            f"Windows returned invalid transfer status: {raw}"
        ) from error


def _clear_remote_control(config: RemoteConfig, job_root: str) -> None:
    _ssh_text(
        config,
        f"""
$path = Join-Path $HOME '{job_root}/control.txt'
if (Test-Path $path) {{ Remove-Item -Force $path }}
$cleanup = Join-Path $HOME '{job_root}/cleanup.txt'
if (Test-Path $cleanup) {{ Remove-Item -Force $cleanup }}
""",
    )


def _clear_remote_status(config: RemoteConfig, job_root: str) -> None:
    _ssh_text(
        config,
        f"""
$path = Join-Path $HOME '{job_root}/status.json'
if (Test-Path $path) {{ Remove-Item -Force $path }}
""",
    )


def _claim_remote_job(config: RemoteConfig, job_root: str) -> None:
    _ssh_text(
        config,
        f"""
$job = Join-Path $HOME '{job_root}'
New-Item -ItemType Directory -Force -Path $job | Out-Null
$removed = Join-Path $HOME (
    'VidReclaim Working\\removed\\' + (Split-Path -Leaf $job) + '.txt'
)
if (Test-Path $removed) {{ Remove-Item -Force $removed }}
$cleanup = Join-Path $job 'cleanup.txt'
if (Test-Path $cleanup) {{ Remove-Item -Force $cleanup }}
Set-Content -Encoding ASCII (Join-Path $job 'client.protocol') -Value '3'
[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
    Set-Content -Encoding ASCII (Join-Path $job 'client.lease')
""",
    )


def _release_remote_job(config: RemoteConfig, job_root: str) -> None:
    _ssh_text(
        config,
        f"""
$lease = Join-Path $HOME '{job_root}/client.lease'
if (Test-Path $lease) {{ Remove-Item -Force $lease }}
""",
        check=False,
    )


def _stop_transfer(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _upload(
    config: RemoteConfig,
    data_path: Path,
    remote_path: str,
    *,
    offset: int = 0,
    stage: StageCallback | None = None,
    control: ControlCallback | None = None,
) -> None:
    total = data_path.stat().st_size
    if stage:
        remaining = total - offset
        verb = "Resuming upload" if offset else "Uploading"
        stage(f"{verb} {data_path.name} ({remaining:,} bytes remaining)")
    parent = remote_path.rsplit("/", 1)[0]
    _ssh_text(
        config,
        f"""
$path = Join-Path $HOME '{parent}'
New-Item -ItemType Directory -Force -Path $path | Out-Null
""",
    )
    command = "put -a" if offset else "put"
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        prefix="vidreclaim-sftp-",
        suffix=".txt",
    ) as batch:
        batch.write(
            f"{command} {_sftp_quote(str(data_path))} "
            f"{_sftp_quote(remote_path)}\n"
        )
        batch.flush()
        process = subprocess.Popen(
            _sftp_base(config, Path(batch.name)),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        last_reported = -1
        try:
            while process.poll() is None:
                action = control() if control else "run"
                if action in {"pause", "cancel", "skip"}:
                    raise RemoteEncodeControl(action)
                try:
                    sent, remote_action = _remote_transfer_state(
                        config, remote_path,
                    )
                except (CommandError, ValueError):
                    pass
                else:
                    if remote_action in {"pause", "cancel", "skip"}:
                        raise RemoteEncodeControl(remote_action)
                    if stage:
                        percent = round(sent / max(total, 1) * 100)
                        if percent != last_reported:
                            stage(f"Uploading {data_path.name} ({percent}%)")
                            last_reported = percent
                time.sleep(1)
            output = process.communicate()[0]
        except BaseException:
            _stop_transfer(process)
            raise
    if process.returncode:
        raise CommandError(f"Remote upload failed: {output.strip()}")
    remote_size = _remote_size(config, remote_path)
    if remote_size != total:
        raise CommandError(
            f"Remote upload size mismatch: expected {total}, got {remote_size}"
        )


def _download(
    config: RemoteConfig,
    remote_path: str,
    destination: Path,
    *,
    stage: StageCallback | None = None,
    control: ControlCallback | None = None,
) -> None:
    offset = destination.stat().st_size if destination.exists() else 0
    remote_size = _remote_size(config, remote_path)
    if remote_size < 0:
        raise CommandError("Remote output is missing")
    if offset > remote_size:
        destination.unlink(missing_ok=True)
        offset = 0
    if stage:
        verb = "Resuming download" if offset else "Downloading result"
        stage(f"{verb} ({offset / max(remote_size, 1):.0%})")
    command = "get -a" if offset else "get"
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        prefix="vidreclaim-sftp-",
        suffix=".txt",
    ) as batch:
        batch.write(
            f"{command} {_sftp_quote(remote_path)} "
            f"{_sftp_quote(str(destination))}\n"
        )
        batch.flush()
        process = subprocess.Popen(
            _sftp_base(config, Path(batch.name)),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        last_reported = -1
        try:
            while process.poll() is None:
                action = control() if control else "run"
                if action in {"pause", "cancel", "skip"}:
                    raise RemoteEncodeControl(action)
                try:
                    _, remote_action = _remote_transfer_state(
                        config, remote_path,
                    )
                except (CommandError, ValueError):
                    pass
                else:
                    if remote_action in {"pause", "cancel", "skip"}:
                        raise RemoteEncodeControl(remote_action)
                if stage and destination.exists():
                    received = destination.stat().st_size
                    percent = round(received / max(remote_size, 1) * 100)
                    if percent != last_reported:
                        stage(f"Downloading result ({percent}%)")
                        last_reported = percent
                time.sleep(1)
            output = process.communicate()[0]
        except BaseException:
            _stop_transfer(process)
            raise
    if process.returncode:
        raise CommandError(f"Remote download failed: {output.strip()}")
    received = destination.stat().st_size if destination.exists() else -1
    if received != remote_size:
        raise CommandError(
            f"Remote download size mismatch: expected {remote_size}, got {received}"
        )


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
        "schema": 2,
        "duration": media.duration,
        "arguments": arguments,
        "encoder": config.encoder,
        "source_display_name": media.source.path.name,
        "source_bytes": media.source.path.stat().st_size,
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
$path = Join-Path $HOME 'VidReclaim Working\\jobs\\{job_id}\\status.json'
$lease = Join-Path $HOME 'VidReclaim Working\\jobs\\{job_id}\\client.lease'
if (Test-Path (Split-Path -Parent $lease)) {{
    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
        Set-Content -Encoding ASCII $lease
}}
if (Test-Path $path) {{
    $status = Get-Content -Raw $path | ConvertFrom-Json
    $workerAlive = $false
    if ($status.worker_pid) {{
        $workerAlive = $null -ne (
            Get-Process -Id $status.worker_pid -ErrorAction SilentlyContinue
        )
    }}
    $status |
        Add-Member -NotePropertyName worker_alive -NotePropertyValue $workerAlive -Force
    $status | ConvertTo-Json -Compress
}} else {{
    '{{"state":"missing","worker_alive":false}}'
}}
""",
    )
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise CommandError(f"Windows worker returned invalid status: {raw}") from error


def _launch_job(
    config: RemoteConfig,
    job_id: str,
) -> subprocess.Popen[str]:
    script = f"""
$job = Join-Path $HOME 'VidReclaim Working\\jobs\\{job_id}'
$statusPath = Join-Path $job 'status.json'
$running = $false
if (Test-Path $statusPath) {{
    try {{
        $status = Get-Content -Raw $statusPath | ConvertFrom-Json
        if (
            $status.state -in @('starting', 'running') -and
            $status.worker_pid
        ) {{
            $running = $null -ne (Get-Process -Id $status.worker_pid -ErrorAction SilentlyContinue)
        }}
        if ($status.state -eq 'complete' -and (Test-Path (Join-Path $job 'output.part.mkv'))) {{
            exit 0
        }}
    }} catch {{}}
}}
if (-not $running) {{
    $control = Join-Path $job 'control.txt'
    if (Test-Path $control) {{ Remove-Item -Force $control }}
    $worker = Join-Path $job 'worker.ps1'
    & $worker -JobDir $job
    exit $LASTEXITCODE
}}
"""
    return subprocess.Popen(
        [*_ssh_base(config), *_powershell_encoded(script)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def _send_control(config: RemoteConfig, job_id: str, action: str) -> None:
    _ssh_text(
        config,
        f"""
$path = Join-Path $HOME 'VidReclaim Working\\jobs\\{job_id}\\control.txt'
Set-Content -Encoding ASCII -Path $path -Value '{action}'
""",
        check=False,
    )


def remote_cleanup(config: RemoteConfig, job_id: str) -> None:
    _ssh_text(
        config,
        f"""
$job = Join-Path $HOME 'VidReclaim Working\\jobs\\{job_id}'
$removedRoot = Join-Path $HOME 'VidReclaim Working\\removed'
$removed = Join-Path $removedRoot '{job_id}.txt'
New-Item -ItemType Directory -Force -Path $removedRoot | Out-Null
[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() |
    Set-Content -Encoding ASCII $removed
if (Test-Path $job) {{
    Set-Content -Encoding ASCII (Join-Path $job 'cleanup.txt') -Value 'client'
    Remove-Item -Recurse -Force $job -ErrorAction SilentlyContinue
}}
if (-not (Test-Path $job)) {{
    Remove-Item -Force $removed -ErrorAction SilentlyContinue
}}
$jobsRoot = Split-Path -Parent $job
$workingRoot = Split-Path -Parent $jobsRoot
foreach ($path in @($removedRoot, $jobsRoot, $workingRoot)) {{
    if (
        (Test-Path $path) -and
        -not (Get-ChildItem -Force $path -ErrorAction SilentlyContinue)
    ) {{
        Remove-Item -Force $path -ErrorAction SilentlyContinue
    }}
}}
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


def _remote_encode_claimed(
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
    job_id, job_root = _stage_remote_job_claimed(
        plan,
        config=config,
        profile=profile,
        preset=preset,
        stage=stage,
        control=control,
    )
    state = _job_state(config, job_id)
    runner: subprocess.Popen[str] | None = None
    if state.get("state") != "complete":
        if stage:
            stage(f"Encoding on {config.host}")
        if state.get("state") not in {"running", "complete", "missing"}:
            _clear_remote_status(config, job_root)
        runner = _launch_job(config, job_id)

    failures = 0
    last_action = "run"
    runner_output = ""
    try:
        while True:
            action = control() if control else "run"
            if action in {"pause", "cancel", "skip"} and action != last_action:
                _send_control(config, job_id, action)
                last_action = action
            if runner is not None and runner.poll() is not None:
                runner_output = runner.communicate()[0].strip()
                runner = None
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
                raise RemoteEncodeControl(
                    "pause" if status == "paused" else status
                )
            if status == "error":
                raise CommandError(
                    "Windows encode failed: "
                    f"{state.get('message') or 'unknown error'}"
                )
            if status == "missing" and runner is None:
                if runner_output:
                    raise CommandError(
                        f"Windows worker did not start: {runner_output}"
                    )
                runner = _launch_job(config, job_id)
            elif (
                status in {"starting", "running"}
                and runner is None
                and state.get("worker_alive") is False
            ):
                runner = _launch_job(config, job_id)
            time.sleep(0.75)
    finally:
        if runner is not None:
            try:
                runner.wait(timeout=5)
            except subprocess.TimeoutExpired:
                _stop_transfer(runner)

    download_partial = temporary.with_name(
        f"{temporary.stem} Downloading {job_id}.mkv"
    )
    try:
        _download(
            config,
            f"{job_root}/output.part.mkv",
            download_partial,
            stage=stage,
            control=control,
        )
    except BaseException:
        download_partial.unlink(missing_ok=True)
        raise
    download_partial.replace(temporary)
    return job_id


def _stage_remote_job_claimed(
    plan: Plan,
    *,
    config: RemoteConfig,
    profile: Profile,
    preset: str,
    stage: StageCallback | None = None,
    control: ControlCallback | None = None,
) -> tuple[str, str]:
    if plan.media.source.kind != "file":
        raise CommandError("Remote encoding currently supports regular video files only")
    config.target
    job_id = remote_job_id(plan, config)
    job_root = f"VidReclaim Working/jobs/{job_id}"
    source_suffix = plan.media.source.path.suffix.lower()
    if re.fullmatch(r"\.[a-z0-9]{1,8}", source_suffix) is None:
        source_suffix = ".media"
    source_name = f"source{source_suffix}"
    state = _job_state(config, job_id)
    if state.get("state") != "complete":
        if (
            state.get("state") != "running"
            and (control() if control else "run") == "run"
        ):
            _clear_remote_control(config, job_root)
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
        source_size = plan.media.source.path.stat().st_size
        staged_size = _remote_size(
            config, f"{job_root}/{source_name}",
        )
        if staged_size != source_size:
            offset = staged_size if 0 <= staged_size < source_size else 0
            _upload(
                config,
                plan.media.source.path,
                f"{job_root}/{source_name}",
                offset=offset,
                stage=stage,
                control=control,
            )
    return job_id, job_root


def remote_stage(
    plan: Plan,
    *,
    config: RemoteConfig,
    profile: Profile,
    preset: str,
    stage: StageCallback | None = None,
    control: ControlCallback | None = None,
) -> str:
    """Upload one upcoming job without starting its encode."""
    job_id = remote_job_id(plan, config)
    job_root = f"VidReclaim Working/jobs/{job_id}"
    _claim_remote_job(config, job_root)
    try:
        try:
            _stage_remote_job_claimed(
                plan,
                config=config,
                profile=profile,
                preset=preset,
                stage=stage,
                control=control,
            )
        except RemoteEncodeControl as error:
            if error.action in {"cancel", "skip"}:
                remote_cleanup(config, job_id)
            raise
        return job_id
    finally:
        _release_remote_job(config, job_root)


def remote_run_staged(
    plan: Plan,
    *,
    config: RemoteConfig,
    control: ControlCallback | None = None,
) -> str:
    """Start a staged job so its encode can overlap the prior download."""
    job_id = remote_job_id(plan, config)
    job_root = f"VidReclaim Working/jobs/{job_id}"
    _claim_remote_job(config, job_root)
    runner: subprocess.Popen[str] | None = None
    last_action = "run"
    try:
        state = _job_state(config, job_id)
        if state.get("state") != "complete":
            initial_action = control() if control else "run"
            if initial_action in {"pause", "cancel", "skip"}:
                if initial_action in {"cancel", "skip"}:
                    remote_cleanup(config, job_id)
                raise RemoteEncodeControl(initial_action)
            runner = _launch_job(config, job_id)
        while True:
            action = control() if control else "run"
            if action in {"pause", "cancel", "skip"} and action != last_action:
                _send_control(config, job_id, action)
                last_action = action
            state = _job_state(config, job_id)
            status = str(state.get("state") or "missing")
            if status == "complete":
                return job_id
            if (
                status == "missing"
                and runner is not None
                and runner.poll() is not None
            ):
                return job_id
            if status in {"paused", "cancelled", "skipped"}:
                if status in {"cancelled", "skipped"}:
                    remote_cleanup(config, job_id)
                raise RemoteEncodeControl(
                    "pause" if status == "paused" else status
                )
            if status == "error":
                raise CommandError(
                    "Windows encode failed: "
                    f"{state.get('message') or 'unknown error'}"
                )
            time.sleep(0.75)
    finally:
        if runner is not None:
            try:
                runner.wait(timeout=5)
            except subprocess.TimeoutExpired:
                _stop_transfer(runner)
        _release_remote_job(config, job_root)


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
    job_id = remote_job_id(plan, config)
    job_root = f"VidReclaim Working/jobs/{job_id}"
    _claim_remote_job(config, job_root)
    try:
        try:
            return _remote_encode_claimed(
                plan,
                temporary,
                config=config,
                profile=profile,
                preset=preset,
                progress=progress,
                control=control,
                stage=stage,
            )
        except RemoteEncodeControl as error:
            if error.action in {"cancel", "skip"}:
                remote_cleanup(config, job_id)
            raise
    finally:
        _release_remote_job(config, job_root)
