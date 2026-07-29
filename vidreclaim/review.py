from __future__ import annotations

import html
import json
import threading
import urllib.parse
import webbrowser
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Iterable

from .dvd import handbrake_input_args
from .model import Plan
from .util import CommandError, atomic_write_json, duration_text, human_bytes, run


def _snapshot(
    input_path: Path,
    at: float,
    output: Path,
    filters: list[str],
    *,
    stream_index: int = 0,
) -> None:
    graph = [*filters, "scale=960:-2:flags=lanczos"]
    output.parent.mkdir(parents=True, exist_ok=True)
    run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", f"{max(0.0, at):.3f}", "-i", str(input_path),
        "-map", f"0:{stream_index}", "-frames:v", "1", "-vf", ",".join(graph),
        "-q:v", "2", str(output),
    ])


def _dvd_reference_clip(plan: Plan, offset: float, seconds: float, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    run([
        "HandBrakeCLI", *handbrake_input_args(plan.media.source),
        "--output", str(output), "--format", "av_mkv",
        "--start-at", f"seconds:{round(offset)}",
        "--stop-at", f"seconds:{max(2, round(seconds))}",
        "--encoder", "x264", "--encoder-preset", "veryfast", "--quality", "1",
        "--audio", "none", "--subtitle", "none", "--comb-detect", "--decomb",
    ])


def build_review_assets(
    plans: list[Plan],
    *,
    session_dir: Path,
    sample_seconds: float,
    plan_indices: set[int] | None = None,
) -> list[dict[str, object]]:
    cards: list[dict[str, object]] = []
    for plan_index, plan in enumerate(plans):
        if plan_indices is not None and plan_index not in plan_indices:
            continue
        if plan.status != "encode" or plan.candidate is None:
            continue
        try:
            candidate_index = plan.candidates.index(plan.candidate)
        except ValueError:
            continue
        pairs: list[dict[str, str]] = []
        for sample_index, offset in enumerate(plan.sample_offsets[:3]):
            clip = (
                session_dir / "clips" / str(plan_index)
                / f"candidate-{candidate_index}-sample-{sample_index}.mkv"
            )
            if not clip.exists():
                raise CommandError(f"Review sample is missing: {clip}")
            before = session_dir / "images" / f"{plan_index}-{sample_index}-before.jpg"
            after = session_dir / "images" / f"{plan_index}-{sample_index}-after.jpg"
            middle = min(sample_seconds / 2, max(0.0, plan.media.duration - offset - 0.1))
            filters: list[str] = []
            if plan.media.field_order not in {"progressive", "unknown", ""}:
                filters.append("bwdif=mode=send_frame:parity=auto:deint=interlaced")
            if plan.media.source.kind == "dvd":
                reference_clip = (
                    session_dir / "clips" / str(plan_index)
                    / f"reference-{sample_index}.mkv"
                )
                _dvd_reference_clip(plan, offset, sample_seconds, reference_clip)
                _snapshot(reference_clip, middle, before, [])
            else:
                _snapshot(
                    plan.media.source.path, offset + middle, before, filters,
                    stream_index=plan.media.video_stream_index,
                )
            _snapshot(clip, middle, after, [])
            pairs.append({
                "before": str(before.relative_to(session_dir)),
                "after": str(after.relative_to(session_dir)),
                "time": duration_text(offset + middle),
            })
        cards.append({
            "plan_index": plan_index,
            "name": plan.media.source.display_name or plan.media.source.path.name,
            "path": str(plan.media.source.path),
            "source": (
                f"{plan.media.codec} · {plan.media.width}×{plan.media.height} · "
                f"{human_bytes(plan.media.size_bytes)}"
            ),
            "output": (
                f"HEVC · {plan.candidate.resolution} · "
                f"about {human_bytes(plan.candidate.projected_bytes)} · "
                f"{plan.candidate.savings_pct:.1f}% smaller · "
                f"about {duration_text(plan.candidate.projected_encode_seconds)}"
            ),
            "estimate_seconds": plan.candidate.projected_encode_seconds,
            "pairs": pairs,
        })
    return cards


def _render_html(cards: Iterable[dict[str, object]]) -> str:
    cards = list(cards)
    total_estimate = sum(float(card.get("estimate_seconds", 0)) for card in cards)
    summary = f"{len(cards)} proposed job(s) · about {duration_text(total_estimate)} total"
    card_markup: list[str] = []
    for card in cards:
        index = int(card["plan_index"])
        comparisons: list[str] = []
        for pair in card["pairs"]:  # type: ignore[union-attr]
            pair = dict(pair)
            comparisons.append(f"""
              <figure>
                <div class="compare">
                  <img src="{html.escape(pair['after'])}" alt="Compressed frame">
                  <img class="before" src="{html.escape(pair['before'])}" alt="Source frame">
                  <input aria-label="Drag to compare before and after" type="range"
                         min="0" max="100" value="50">
                  <span class="tag left">SOURCE</span><span class="tag right">NEW</span>
                </div>
                <figcaption>{html.escape(pair['time'])}</figcaption>
              </figure>
            """)
        card_markup.append(f"""
          <article class="card">
            <header>
              <label class="decision">
                <input type="checkbox" name="approve" value="{index}" checked>
                <span>Encode</span>
              </label>
              <div>
                <h2>{html.escape(str(card['name']))}</h2>
                <p class="path">{html.escape(str(card['path']))}</p>
              </div>
            </header>
            <div class="facts">
              <span>Source: {html.escape(str(card['source']))}</span>
              <span>Planned: {html.escape(str(card['output']))}</span>
            </div>
            <div class="shots">{''.join(comparisons)}</div>
          </article>
        """)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>vidreclaim review</title>
  <style>
    :root {{ color-scheme: dark; font: 15px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; background: #111318; color: #f3f4f6; }}
    .top {{ position: sticky; top: 0; z-index: 9; padding: 16px 24px;
            background: color-mix(in srgb, #171a21 94%, transparent);
            backdrop-filter: blur(16px); border-bottom: 1px solid #343844;
            display: flex; gap: 18px; align-items: center; }}
    .top h1 {{ font-size: 19px; margin: 0 auto 0 0; }}
    .top h1 small {{ display: block; color: #9ca5b5; font-size: 12px; font-weight: 500; }}
    button {{ border: 0; border-radius: 8px; padding: 9px 13px; cursor: pointer;
              background: #303541; color: white; font-weight: 600; }}
    button.primary {{ background: #4f7cff; }}
    main {{ max-width: 1500px; margin: auto; padding: 22px; }}
    .card {{ background: #1b1f27; border: 1px solid #343a47; border-radius: 13px;
             padding: 18px; margin-bottom: 22px; }}
    header {{ display: flex; gap: 14px; align-items: start; }}
    h2 {{ font-size: 17px; margin: 0; }}
    p.path {{ color: #8f98aa; margin: 3px 0 0; overflow-wrap: anywhere; }}
    .decision {{ display: flex; align-items: center; gap: 8px; padding: 8px 11px;
                 background: #283141; border-radius: 8px; font-weight: 700; }}
    .decision input {{ width: 18px; height: 18px; accent-color: #5f8bff; }}
    .facts {{ display: flex; flex-wrap: wrap; gap: 8px 22px; margin: 14px 0;
              color: #bdc5d4; }}
    .shots {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }}
    figure {{ margin: 0; }}
    figcaption {{ color: #9ca5b5; margin-top: 5px; text-align: center; }}
    .compare {{ position: relative; overflow: hidden; aspect-ratio: 16/9;
                background: #090a0d; border-radius: 8px; }}
    .compare img {{ position: absolute; width: 100%; height: 100%; object-fit: contain; }}
    .compare img.before {{ clip-path: inset(0 50% 0 0); }}
    .compare input {{ position: absolute; inset: 0; width: 100%; height: 100%;
                      opacity: 0; cursor: ew-resize; }}
    .compare::after {{ content: ""; position: absolute; pointer-events: none;
                       left: var(--split, 50%); top: 0; bottom: 0; width: 2px;
                       background: white; box-shadow: 0 0 8px #000; }}
    .tag {{ position: absolute; top: 8px; padding: 3px 6px; border-radius: 4px;
            background: #000a; font-size: 10px; font-weight: 800; pointer-events: none; }}
    .tag.left {{ left: 8px; }} .tag.right {{ right: 8px; }}
    @media (max-width: 900px) {{ .shots {{ grid-template-columns: 1fr; }} }}
  </style>
</head>
<body>
  <form method="post" action="/submit">
    <div class="top">
      <h1>Spot-check proposed encodes <small>{html.escape(summary)}</small></h1>
      <button type="button" onclick="setAll(true)">Approve all</button>
      <button type="button" onclick="setAll(false)">Skip all</button>
      <button class="primary" type="submit">Continue with selected</button>
    </div>
    <main>{''.join(card_markup)}</main>
  </form>
  <script>
    document.querySelectorAll('.compare input').forEach(slider => {{
      const box = slider.parentElement, before = box.querySelector('.before');
      const update = () => {{
        const right = 100 - Number(slider.value);
        before.style.clipPath = `inset(0 ${{right}}% 0 0)`;
        box.style.setProperty('--split', slider.value + '%');
      }};
      slider.addEventListener('input', update); update();
    }});
    function setAll(value) {{
      document.querySelectorAll('input[name=approve]').forEach(x => x.checked = value);
    }}
  </script>
</body>
</html>"""


def review_in_browser(
    plans: list[Plan],
    *,
    session_dir: Path,
    decisions_path: Path,
    sample_seconds: float,
    plan_indices: set[int] | None = None,
) -> set[int]:
    cards = build_review_assets(
        plans,
        session_dir=session_dir,
        sample_seconds=sample_seconds,
        plan_indices=plan_indices,
    )
    if not cards:
        return set()
    index_path = session_dir / "index.html"
    index_path.write_text(_render_html(cards), encoding="utf-8")
    selected: set[int] = set()
    submitted = threading.Event()

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *handler_args: object, **handler_kwargs: object) -> None:
            super().__init__(
                *handler_args, directory=str(session_dir), **handler_kwargs,
            )

        def log_message(self, format: str, *args: object) -> None:
            return

        def do_POST(self) -> None:
            if self.path != "/submit":
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            length = int(self.headers.get("Content-Length", "0"))
            fields = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"))
            selected.update(int(value) for value in fields.get("approve", []))
            atomic_write_json(decisions_path, {
                "approved_plan_indices": sorted(selected),
                "skipped_plan_indices": sorted(
                    int(card["plan_index"]) for card in cards
                    if int(card["plan_index"]) not in selected
                ),
            })
            body = (
                "<!doctype html><meta charset=utf-8><title>Review saved</title>"
                "<style>body{font:18px -apple-system;padding:40px;background:#111;color:#eee}</style>"
                f"<h1>Review saved</h1><p>{len(selected)} job(s) approved. "
                "You can close this tab.</p>"
            ).encode()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            submitted.set()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.timeout = 0.5
    url = f"http://127.0.0.1:{server.server_port}/index.html"
    print(f"Review interface: {url}")
    webbrowser.open(url)
    try:
        while not submitted.is_set():
            server.handle_request()
    finally:
        server.server_close()
    return selected
