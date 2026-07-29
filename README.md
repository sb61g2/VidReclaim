# vidreclaim

`vidreclaim` is a cautious, sample-driven batch transcoder for a Mac video
archive. It recursively finds video files and `VIDEO_TS` folders, chooses an
adaptive HEVC plan, and schedules a full encode only when the estimated reclaim
clears both percentage and absolute storage-savings gates. The default fast
path uses stream metadata; optional thorough analysis adds short trial encodes,
XPSNR measurements, and side-by-side review images.

It is intended for personal, casual-viewing libraries—not masters or archival
preservation.

## Native Mac app

The self-contained installer adds `/Applications/VidReclaim.app`, a native
SwiftUI control center for the full toolkit. It provides Mac file and save
pickers, clearly explained source-handling modes, a destructive-action
confirmation for rolling deletion, live whole-job and current-file progress,
speed and ETA, safe cancellation, and a persistent activity log. Its
Transmission-inspired queue can pause, resume, skip, cancel, and reorder
individual videos. Sessions survive app restarts and reboots.

The app uses the same installed command-line engine described below. The
side-by-side screenshot reviewer and interactive treemap open locally in the
default browser, where their draggable and drill-down interfaces work best.

## What it does

- Recursively scans common video formats without treating the VOB pieces in a
  `VIDEO_TS` folder as independent videos.
- Probes unchanged regular files in parallel and caches the results, while
  rejecting files smaller than the absolute reclaim threshold before probing.
- Uses a fast metadata-driven quality and resolution decision by default.
- Can optionally sample the beginning, middle, and end-ish portions of each
  title and measure decoded trials against exact source frames with FFmpeg's
  XPSNR filter and loopback decoder.
- Tests native resolution and, for UHD sources, a 1080-class candidate. A
  genuinely sharp 4K source stays 4K when the scaled trial loses visible
  information.
- Uses resolution-aware constant quality and predicts the completed file size
  from real sample encodes.
- Skips work unless both the percentage and absolute reclaim thresholds pass.
- Copies regular-file audio, subtitle, attachment, chapter, and metadata
  streams into MKV.
- Uses DVD-aware HandBrake parsing for cells, angles, IFO metadata, and
  timestamp discontinuities.
- Strips DVD menus, trailers, and extras by default. Movie discs keep the
  dominant feature; episodic discs keep the cluster of similarly long titles.
- Verifies duration, stream counts, decodability, and the *actual* savings
  before an output is accepted.
- Tracks per-item and whole-queue progress, speed, and a continuously corrected
  ETA in an atomic session file.
- Can optionally open a local side-by-side review gallery before the full run.
- Persists queue order and item state. After a reboot, completed videos remain
  complete and the interrupted video restarts from its beginning; partially
  written MKV/HEVC output is not unsafely appended.
- Never touches a source by default.

## Install from source

On a Mac with Homebrew:

```bash
brew install ffmpeg handbrake
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -e .
vidreclaim doctor
```

You can also run it directly from this checkout:

```bash
python3 -m vidreclaim doctor
```

## Build the self-contained Mac installer

The package build requires Apple silicon, the Command Line Tools, Homebrew
FFmpeg and HandBrake, and PyInstaller:

```bash
python3 -m venv .installer-venv
. .installer-venv/bin/activate
python3 -m pip install pyinstaller
python3 packaging/macos/build_installer.py --python .installer-venv/bin/python
```

The resulting unsigned, ad-hoc-signed package is written to `outputs/`.
Distribution to other people should use an Apple Developer ID certificate and
notarization; this personal build deliberately does not claim either.

## Recommended first run

Create a fast metadata plan. This does not run any full encode or modify a
source:

```bash
vidreclaim queue-start "/Volumes/Media" --plan-only
```

Start a persistent queue using the fast defaults:

```bash
vidreclaim queue-start "/Volumes/Media"
```

Add `--thorough-analysis --review` when you specifically want trial encodes,
XPSNR scoring, and the before/after gallery:

```bash
vidreclaim queue-start "/Volumes/Media" --thorough-analysis --review
```

The browser UI is served only on `127.0.0.1`. Each proposed job has up to three
draggable source/new comparisons and an Encode checkbox. Submitting the page
continues only with the checked jobs.

Outputs go under `ROOT/.vidreclaim/output/`. Queue sessions live under
`~/Library/Application Support/VidReclaim/Sessions/`; probe metadata is cached
under `~/Library/Caches/VidReclaim/`.

## Queue controls and reboot resumption

The native Queue screen is the easiest way to manage work. The same controls
are automation-friendly:

```bash
vidreclaim queue-control SESSION.json pause --item ITEM_ID
vidreclaim queue-control SESSION.json resume --item ITEM_ID
vidreclaim queue-control SESSION.json skip --item ITEM_ID
vidreclaim queue-control SESSION.json cancel --item ITEM_ID
vidreclaim queue-control SESSION.json move-up --item ITEM_ID
vidreclaim queue-resume SESSION.json
```

Pause/resume uses macOS process suspension, so the encoder keeps its exact
place while the computer remains on. After a reboot, the session, completed
items, decisions, and order are restored; only an interrupted current encode
starts over because appending to a partial MKV is not safely supported.

## x265 versus the M4 hardware encoder

In plain English, VideoToolbox usually finishes about **4–8 times sooner** than
x265 Medium on an M4, but often needs **15–35% more space** for roughly similar
casual-viewing quality. x265 is the patient, storage-efficient choice;
VideoToolbox is the “finish tonight” choice. These are useful starting ranges,
not promises: source complexity, resolution, grain, and x265 preset matter.
VidReclaim replaces the initial estimate with measured speed as each real
encode progresses.

## Stitching clips

Join two or more clips in the order given:

```bash
vidreclaim stitch finished.mkv intro.mov part-1.mp4 part-2.mkv
```

Folders are expanded recursively in natural filename order, so `clip2` comes
before `clip10`:

```bash
vidreclaim stitch vacation.mkv "./Vacation Clips" --canvas 1080p
```

The stitcher accepts mismatched codecs, resolutions, frame rates, and audio
layouts. It scales each clip to a common canvas without cropping, adds
letterboxing where needed, inserts silence for clips with no audio, creates a
chapter named after each input file, and verifies the resulting duration and
audio stream. The default canvas follows the first clip; choose `largest`,
`1080p`, or `4k` with `--canvas`. Use `--encoder videotoolbox` for the fast M4
hardware path.

Mixed HDR and SDR clips are refused because joining them correctly requires an
explicit tone-mapping choice.

## Finding what uses the space

Scan a folder, disk, or mounted volume and open an interactive WinDirStat-style
treemap:

```bash
vidreclaim space "/Volumes/Media"
vidreclaim space "$HOME/Movies" "$HOME/Downloads"
```

The scan reports allocated disk blocks by default, de-duplicates hard links,
does not follow symlinks, and stays on each starting filesystem unless
`--cross-filesystems` is supplied. The browser report highlights video files,
supports directory drill-down and breadcrumbs, and lists the largest items at
each level. Use `--logical-size` when apparent file length is more useful than
allocated space, or `--output report.html --no-open` for automation.

APFS clone sharing and purgeable system storage cannot be measured exactly
through normal file metadata, so totals may differ somewhat from Disk Utility.

## Source handling

The default leaves every source untouched.

For a reversible in-place transition, verified originals can be moved to the
same-volume `.reclaim-originals` archive:

```bash
python3 -m vidreclaim run "/Volumes/Media" --review --replace
```

Review the new library before manually deleting `.reclaim-originals`. Because
that archive is on the same volume, this mode does not reclaim physical space
until the archive is deleted.

When the volume cannot hold the old and new libraries together, explicitly
enable irreversible rolling deletion:

```bash
python3 -m vidreclaim run "/Volumes/Media" \
  --review --delete-source-as-you-go --yes
```

A regular source is deleted only after its output passes verification and the
actual minimum-savings threshold. A `VIDEO_TS` folder is deleted only after
every selected main-content title from that disc succeeds. Failed jobs retain
their sources and partial outputs are left with a `.part.mkv` name for
diagnosis. Deleted sources are not recoverable by this tool; keep another
backup if the material matters.

## Quality and speed

The default is `--profile balanced --encoder x265 --preset medium`. This favors
compression efficiency and runs at macOS niceness 10, so ordinary desktop work
remains responsive.

Useful alternatives:

```bash
# More fidelity and a lower savings requirement
python3 -m vidreclaim plan ROOT --profile conservative

# Smaller output when casual quality is the priority
python3 -m vidreclaim plan ROOT --profile compact

# Much faster on the M4 Media Engine, usually with larger files
python3 -m vidreclaim run ROOT --encoder videotoolbox --review

# Fully prioritize encoding throughput
python3 -m vidreclaim run ROOT --nice 0 --preset fast
```

HandBrake's documented x265 starting ranges are broadly 18–22 for SD, 19–23
for 720p, 20–24 for 1080p, and 22–28 for 4K. The balanced profile starts near
the middle of those ranges, then the sample measurement decides whether the
result is acceptable. See HandBrake's
[quality guidance](https://handbrake.fr/docs/en/latest/workflow/adjust-quality.html).

Defaults:

- balanced minimum savings: 20%
- minimum absolute reclaim: 100 MiB per item
- three 10-second samples
- XPSNR gate: 35 dB native, 33 dB for a scaled candidate
- quick verification: decode samples near the start, middle, and end

Use `--deep-verify` to decode every frame before accepting an output.

## DVD main-content selection

Main-content-only mode is enabled by default:

1. Titles shorter than 10 minutes are excluded.
2. Titles at least 65% as long as the longest title are kept.
3. If every title is short, only the longest is kept.

This separates a long movie from trailers and most extras, while preserving a
set of 22- or 44-minute TV episodes. Every plan prints the selected and
excluded title numbers. Ambiguous discs should be checked in `--review`.

Override the behavior when needed:

```bash
python3 -m vidreclaim plan ROOT --keep-dvd-extras
python3 -m vidreclaim plan ROOT --dvd-min-title-minutes 5
```

## Progress and interruption

During long encodes, the terminal shows:

- current job and total jobs
- current-file and duration-weighted whole-batch percentages
- current encoding speed
- rolling whole-batch ETA
- the active phase: encoding, verifying, archiving, or deleting

The same state is atomically updated once per second in
`.vidreclaim/progress.json`, making it safe for a menu-bar widget, `watch`, or
other automation to read. The result manifest is atomically updated after
every completed or failed job. `Ctrl-C` never triggers source handling for the
interrupted job.

## Caveats

- Lossy-to-lossy transcoding always discards information. XPSNR is a useful
  guardrail, not a substitute for looking at material you care about.
- Dolby Vision and unusual HDR metadata are more safely handled by HandBrake
  than arbitrary FFmpeg remux paths; inspect HDR output before deleting a
  source.
- MKV is used to preserve heterogeneous tracks. IINA and VLC are good macOS
  players for MKV; QuickTime Player does not support every MKV feature.
- The DVD selector intentionally removes non-dominant long extras. Use
  `--keep-dvd-extras` for concert, anthology, branching, or otherwise unusual
  discs.

The implementation also relies on FFmpeg's
[loopback decoder](https://ffmpeg.org/ffmpeg.html#Loopback-decoders) for exact
sample comparison and Apple's
[VideoToolbox](https://developer.apple.com/documentation/videotoolbox) when
the hardware encoder is selected.
