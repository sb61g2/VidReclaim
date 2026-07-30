# VidReclaim

VidReclaim scans video libraries, estimates useful savings, and encodes only
files that meet the selected thresholds. It supports regular video files,
`VIDEO_TS` folders, persistent queues, clip combining, and remote Windows
encoding.

For personal, casual-viewing libraries. Keep archival sources elsewhere.

## Install

Mac installer:

```text
outputs/VidReclaim-<version>-macOS26+-arm64-unsigned.pkg
```

The package installs `/Applications/VidReclaim.app` and the `vidreclaim`
command. It is unsigned and intended for local installation.

Source install:

```bash
brew install ffmpeg handbrake
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -e .
vidreclaim doctor
```

## App

- **Reclaim:** choose locations and prepare a queue.
- **Combine:** join clips in order.
- **Activity:** filter, sort, control, and resume queues.

Thresholds, sorting, selection, and folder controls are in the queue.
Verified outputs return to their source folders. `VidReclaim Working` is
temporary and removed when empty. Sources are kept by default.

DVD menus, trailers, and extras are excluded by default. Enable DVD extras for
unusual discs.

## Windows encoding

Extract the Windows setup archive and run:

```text
Install VidReclaim Worker.cmd
```

The setup installs the SSH worker, FFmpeg, and tray monitor. It can start with
Windows. Closing the window keeps the tray active. Quit stops jobs, remote
access, and the tray.

Remote transfers resume after interruption. Upcoming files upload while the
current file encodes; the next encode can start during the prior download.
CPU x265 is the default. NVIDIA NVENC is optional. DVD and Combine jobs run on
the Mac.

## CLI

Prepare without encoding:

```bash
vidreclaim queue-start "/Volumes/Media" --plan-only
```

Start a queue:

```bash
vidreclaim queue-start "/Volumes/Media"
```

Add visual review:

```bash
vidreclaim queue-start "/Volumes/Media" --review
```

Combine clips:

```bash
vidreclaim stitch combined.mkv clip-1.mov clip-2.mp4
```

Map disk use:

```bash
vidreclaim space "/Volumes/Media"
```

Queue controls:

```bash
vidreclaim queue-control SESSION.json pause --item ITEM_ID
vidreclaim queue-control SESSION.json resume --item ITEM_ID
vidreclaim queue-control SESSION.json cancel --item ITEM_ID
vidreclaim queue-control SESSION.json clear-completed
vidreclaim queue-resume SESSION.json
```

Use `vidreclaim --help` for all options.

## Defaults

- Balanced quality
- x265 Medium
- 20% minimum estimated savings
- 100 MiB minimum estimated reclaim
- Fast metadata analysis
- Three-point output verification
- Source files kept

Lossy transcoding discards information. Review important HDR, Dolby Vision, and
unusual DVD material before deleting sources.

## Build the Mac installer

```bash
python3 -m venv .installer-venv
. .installer-venv/bin/activate
python3 -m pip install pyinstaller
python3 packaging/macos/build_installer.py \
  --python .installer-venv/bin/python
```

The package is written to `outputs/`.
