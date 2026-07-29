# vidreclaim

`vidreclaim` is a sample-driven batch transcoder for a Mac video
archive. It recursively finds video files and `VIDEO_TS` folders, chooses an
adaptive HEVC plan, and schedules a full encode only when the estimated reclaim
clears both percentage and absolute storage-savings gates. The default fast
path uses stream metadata; optional thorough analysis adds short trial encodes,
XPSNR measurements, and side-by-side review images.

It is intended for personal, casual-viewing libraries—not masters or archival
preservation.

## Native Mac app

The self-contained installer adds `/Applications/VidReclaim.app`, a native
SwiftUI workspace. Library scanning, storage prioritization, hierarchical
selection, encode settings, analysis, side-by-side review, and starting the
queue use one flow. A top switch opens Reclaim, Combine, or Activity without a
sidebar. The app provides source-handling modes, a destructive-action
confirmation for rolling deletion, live scan, batch, and current-file
progress, speed and ETA, cancellation, and a persistent activity log.
Sessions survive app restarts and reboots.

The app uses the same installed command-line engine described below. Disk-usage
findings stay in the native interface and can feed selected files or folders
directly into a queue. Its unified picking flow first scans user-selected
library locations, then lets the user independently choose which discovered
contents to analyze and which smaller subset should receive side-by-side
samples. Parent-folder checks select every descendant and show a mixed state
when only some children are selected. The optional screenshot reviewer opens
natively inside the app for workspace-created jobs; the CLI can still use its
local browser review.

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
- Tracks scan and analysis, per-item encoding, and whole-queue encoding
  separately, with speed and continuously corrected ETAs in an atomic session
  file.
- Can optionally open a local side-by-side review gallery before the full run.
- Generates side-by-side comparisons only for the specifically checked files
  or folders. Quick mode encodes a few individual frames; short-sample mode
  spends more time to reveal motion and temporal-compression artifacts.
- Persists queue order and item state. After a reboot, completed videos remain
  complete and the interrupted video restarts from its beginning; partially
  written MKV/HEVC output is not unsafely appended.
- Keeps source-relative folder paths, supports folder-wide inclusion changes,
  multi-row selection, search, status filters, and sorting by projected raw or
  percentage savings, source size, encode time, name, status, or queue order.
- Tracks completed outputs in a persistent media catalog. Unchanged sources and
  known outputs are marked processed and hidden by default on later scans,
  preventing accidental repeated encodes.
- Shows live selected-job totals for projected reclaim, verified space saved,
  elapsed encode time, and estimated selected encode time.
- Offers an instant per-video “Compare Options” table for Conservative,
  Balanced, and Compact quality across x265 Very Fast/Medium/Slow and M4
  hardware encoding. It estimates resolution, output size, savings, and total
  encode time without launching extra probes or trial encodes.
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

Side-by-side review uses quick still frames by default. Add
`--review-mode clips` when motion artifacts are important enough to justify
short trial encodes.

The browser UI is served only on `127.0.0.1`. Each proposed job has up to three
draggable source/new comparisons and an Encode checkbox. Submitting the page
continues only with the checked jobs.

Outputs go under `ROOT/.vidreclaim/output/`. Queue sessions and processed-media
history live under `~/Library/Application Support/VidReclaim/`; probe metadata
is cached under `~/Library/Caches/VidReclaim/`.

## Queue controls and reboot resumption

The native Queue screen is the easiest way to manage work. The same controls
are automation-friendly:

```bash
vidreclaim queue-control SESSION.json pause --item ITEM_ID
vidreclaim queue-control SESSION.json resume --item ITEM_ID
vidreclaim queue-control SESSION.json skip --item ITEM_ID
vidreclaim queue-control SESSION.json cancel --item ITEM_ID
vidreclaim queue-control SESSION.json move-up --item ITEM_ID
vidreclaim queue-control SESSION.json exclude --folder "TV/Season 1"
vidreclaim queue-control SESSION.json include --folder "TV"
vidreclaim queue-control SESSION.json clear-completed
vidreclaim queue-control SESSION.json clear-cancelled
vidreclaim queue-control SESSION.json clear-all
vidreclaim queue-resume SESSION.json
```

Pause/resume uses macOS process suspension, so the encoder keeps its exact
place while the computer remains on. After a reboot, the session, completed
items, decisions, inclusion flags, and order are restored; only an interrupted
current encode starts over because appending to a partial MKV is not safely
supported. A saved queue can be reopened without scanning its source tree.
Starting a prepared queue reactivates its selected paused, cancelled, and
failed items. A plan with no qualifying files reports that result instead of
entering an empty encode cycle. Queue items cannot be cleared while a worker
is active.

## x265 versus the M4 hardware encoder

In plain English, VideoToolbox usually finishes about **4–8 times sooner** than
x265 Medium on an M4, but often needs **15–35% more space** for roughly similar
casual-viewing quality. x265 is the patient, storage-efficient choice;
VideoToolbox is the “finish tonight” choice. These are useful starting ranges,
not promises: source complexity, resolution, grain, and x265 preset matter.
VidReclaim replaces the initial estimate with measured speed as each real
encode progresses.

The Queue screen’s **Compare Options** button shows these tradeoffs for the
selected video before or during a job. The matrix is calculated from metadata
already collected during the normal scan, so opening it adds no analysis time.
It is intentionally labeled as an estimate: grain, motion, HDR, and source
complexity can move the actual result.

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

The app shows input expansion and metadata progress as soon as a combine job
starts. After probing the clips, it reports clip count, total playback time,
source size, estimated output size and size change, and estimated encode time.
Encode progress and ETA then update while the job runs. The verified output
size replaces the estimate when the job finishes.

If a combine is interrupted, the app reports its partial output before scanning
the inputs again. It can reveal that file in Finder or move it to Trash and
retry. It never removes the partial without the user's action.

For mixed HDR and SDR inputs, the default creates separately named `-sdr` and
`-hdr` outputs so each group keeps an appropriate dynamic range. Select
`--mixed-dynamic-range sdr` to request one BT.709 SDR output using Hable
tone-mapping. That unified path requires FFmpeg's `zscale` and `tonemap`
filters; when they are unavailable, VidReclaim safely falls back to the two
outputs instead of applying a misleading color conversion.

## Finding what uses the space

Scan a folder, disk, or mounted volume:

```bash
vidreclaim space "/Volumes/Media"
vidreclaim space "$HOME/Movies" "$HOME/Downloads"
```

The native app embeds the complete findings, supports filtering and size
ordering, and lets a user select videos or whole directories within the main
library workflow.
Exact video paths from those findings are passed to the planner, avoiding
another full-tree discovery walk. Selections must belong to one scanned
location per queue so source-relative output paths remain unambiguous.

The scan reports allocated disk blocks by default, de-duplicates hard links,
does not follow symlinks, and stays on each starting filesystem unless
`--cross-filesystems` is supplied. The command can still produce an HTML
treemap with `--output`, and `--json-output` writes the complete structured
tree for automation. Use `--logical-size` when apparent file length is more
useful than allocated space.

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
