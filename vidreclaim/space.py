from __future__ import annotations

import html
import json
import os
import time
import webbrowser
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .discovery import VIDEO_EXTENSIONS
from .util import CommandError, human_bytes


@dataclass
class SpaceNode:
    name: str
    path: str
    kind: str
    size: int = 0
    files: int = 0
    errors: int = 0
    children: list["SpaceNode"] = field(default_factory=list)

    def report(self, max_children: int | None = 160) -> dict[str, Any]:
        ordered = sorted(self.children, key=lambda item: item.size, reverse=True)
        visible = ordered if max_children is None else ordered[:max_children]
        hidden = [] if max_children is None else ordered[max_children:]
        children = [child.report(max_children) for child in visible]
        if hidden:
            children.append({
                "name": f"Other ({len(hidden)} items)",
                "path": self.path,
                "kind": "other",
                "size": sum(item.size for item in hidden),
                "files": sum(item.files for item in hidden),
                "errors": sum(item.errors for item in hidden),
                "children": [],
            })
        return {
            "name": self.name,
            "path": self.path,
            "kind": self.kind,
            "size": self.size,
            "files": self.files,
            "errors": self.errors,
            "children": children,
        }


@dataclass
class ScanStats:
    files: int = 0
    directories: int = 0
    bytes: int = 0
    errors: int = 0
    started: float = field(default_factory=time.monotonic)
    last_update: float = 0.0

    def update_terminal(self, current: Path, *, force: bool = False) -> None:
        now = time.monotonic()
        if not force and now - self.last_update < 1:
            return
        print(
            f"\rScanned {self.files:,} files · {self.directories:,} folders · "
            f"{human_bytes(self.bytes)} · {current}",
            end="" if os.isatty(1) else "\n",
            flush=True,
        )
        self.last_update = now


def _kind(path: Path) -> str:
    extension = path.suffix.lower()
    if extension in VIDEO_EXTENSIONS:
        return "video"
    if extension in {".jpg", ".jpeg", ".png", ".gif", ".heic", ".tiff", ".webp"}:
        return "image"
    if extension in {".mp3", ".aac", ".m4a", ".flac", ".wav", ".aiff", ".opus"}:
        return "audio"
    if extension in {".zip", ".7z", ".rar", ".tar", ".gz", ".dmg", ".pkg"}:
        return "archive"
    if extension in {".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx"}:
        return "document"
    return "file"


def scan_space(
    paths: list[Path],
    *,
    allocated: bool = True,
    cross_filesystems: bool = False,
) -> tuple[SpaceNode, ScanStats]:
    if not paths:
        raise CommandError("At least one path is required")
    resolved = [path.expanduser().resolve() for path in paths]
    missing = [path for path in resolved if not path.exists()]
    if missing:
        raise CommandError(f"Space scan path does not exist: {missing[0]}")
    stats = ScanStats()
    seen_files: set[tuple[int, int]] = set()

    def file_size(stat: os.stat_result) -> int:
        if allocated and hasattr(stat, "st_blocks"):
            return int(stat.st_blocks) * 512
        return int(stat.st_size)

    def walk(path: Path, device: int) -> SpaceNode:
        try:
            stat = path.stat(follow_symlinks=False)
        except OSError:
            stats.errors += 1
            return SpaceNode(path.name or str(path), str(path), "error", errors=1)
        if path.is_symlink():
            return SpaceNode(path.name, str(path), "symlink")
        if not path.is_dir():
            identity = (stat.st_dev, stat.st_ino)
            if identity in seen_files:
                return SpaceNode(path.name, str(path), "hardlink")
            seen_files.add(identity)
            size = file_size(stat)
            stats.files += 1
            stats.bytes += size
            stats.update_terminal(path)
            return SpaceNode(path.name, str(path), _kind(path), size=size, files=1)
        if not cross_filesystems and stat.st_dev != device:
            return SpaceNode(path.name or str(path), str(path), "mount")
        node = SpaceNode(path.name or str(path), str(path), "directory")
        stats.directories += 1
        stats.update_terminal(path)
        try:
            with os.scandir(path) as entries:
                for entry in entries:
                    child = walk(Path(entry.path), device)
                    node.children.append(child)
                    node.size += child.size
                    node.files += child.files
                    node.errors += child.errors
        except OSError:
            node.errors += 1
            stats.errors += 1
        return node

    roots: list[SpaceNode] = []
    for path in resolved:
        try:
            device = path.stat().st_dev
        except OSError as error:
            raise CommandError(f"Cannot inspect {path}: {error}") from error
        roots.append(walk(path, device))
    root = SpaceNode(
        "Scanned locations", "",
        "root",
        size=sum(item.size for item in roots),
        files=sum(item.files for item in roots),
        errors=sum(item.errors for item in roots),
        children=roots,
    )
    stats.update_terminal(resolved[-1], force=True)
    if os.isatty(1):
        print()
    return root, stats


def largest_nodes(root: SpaceNode, count: int = 20) -> list[SpaceNode]:
    nodes: list[SpaceNode] = []
    stack = list(root.children)
    while stack:
        node = stack.pop()
        nodes.append(node)
        stack.extend(node.children)
    return sorted(nodes, key=lambda item: item.size, reverse=True)[:count]


def _report_html(data: dict[str, Any], allocated: bool) -> str:
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    size_mode = "allocated disk space" if allocated else "logical file size"
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VidReclaim Space Map</title>
  <style>
    :root {{ color-scheme: dark; font: 14px/1.4 -apple-system,BlinkMacSystemFont,sans-serif; }}
    * {{ box-sizing: border-box; }}
    body {{ margin:0; background:#111318; color:#eef1f5; }}
    header {{ padding:14px 18px; border-bottom:1px solid #343944; background:#191c23; }}
    h1 {{ font-size:19px; margin:0 0 3px; }}
    #crumbs button {{ border:0; color:#9cbaff; background:none; cursor:pointer; padding:2px 4px; }}
    .layout {{ display:grid; grid-template-columns:minmax(0,1fr) 390px; height:calc(100vh - 84px); }}
    #map {{ position:relative; overflow:hidden; background:#0c0e12; }}
    .tile {{ position:absolute; overflow:hidden; border:1px solid #1118; cursor:pointer;
             min-width:2px; min-height:2px; }}
    .tile:hover {{ outline:2px solid white; z-index:3; }}
    .tile span {{ display:block; padding:5px 6px; font-size:11px; text-shadow:0 1px 2px #000; }}
    .directory {{ background:#3f5f8c; }} .video {{ background:#d46a2d; }}
    .image {{ background:#9a4f91; }} .audio {{ background:#448d70; }}
    .archive {{ background:#9a7b35; }} .document {{ background:#6070a8; }}
    .file,.other {{ background:#4d535e; }} .error {{ background:#922f3e; }}
    aside {{ overflow:auto; border-left:1px solid #343944; padding:12px; }}
    table {{ border-collapse:collapse; width:100%; }}
    th,td {{ padding:7px 5px; border-bottom:1px solid #2c3039; text-align:left; }}
    td.size {{ white-space:nowrap; text-align:right; }}
    tr {{ cursor:pointer; }} tr:hover {{ background:#252a34; }}
    .muted {{ color:#969fad; }}
    #tip {{ position:fixed; pointer-events:none; display:none; padding:6px 8px;
            background:#050608e8; border:1px solid #5c6472; border-radius:6px; z-index:10; }}
    @media(max-width:850px) {{ .layout {{ grid-template-columns:1fr; grid-template-rows:60vh auto;height:auto; }}
      aside {{ border-left:0;border-top:1px solid #343944; }} }}
  </style>
</head>
<body>
<header><h1>VidReclaim Space Map</h1><div id="summary" class="muted"></div><div id="crumbs"></div></header>
<div class="layout"><main id="map"></main><aside><h2>Largest items here</h2><table>
<thead><tr><th>Name</th><th>Type</th><th class="size">Size</th></tr></thead><tbody id="rows"></tbody>
</table></aside></div><div id="tip"></div>
<script>
const root={payload}; let current=root; const parents=new Map();
const tip=document.querySelector('#tip');
function index(node){{(node.children||[]).forEach(c=>{{parents.set(c,node);index(c)}})}} index(root);
function bytes(n){{const u=['B','KiB','MiB','GiB','TiB','PiB'];let i=0;while(n>=1024&&i<u.length-1){{n/=1024;i++}}return n.toFixed(i?1:0)+' '+u[i]}}
function crumbs(){{
  let chain=[],n=current; while(n){{chain.unshift(n);n=parents.get(n)}}
  const box=document.querySelector('#crumbs');box.innerHTML='';
  chain.forEach((n,i)=>{{const b=document.createElement('button');b.textContent=n.name||'All';
    b.onclick=()=>{{current=n;render()}};box.append(b);if(i<chain.length-1)box.append(' › ');}});
}}
function render(){{
  crumbs(); const kids=(current.children||[]).filter(x=>x.size>0).sort((a,b)=>b.size-a.size);
  document.querySelector('#summary').textContent=bytes(current.size)+' {size_mode} · '+current.files.toLocaleString()+' files'+(current.errors?' · '+current.errors+' unreadable':'');
  const map=document.querySelector('#map');map.innerHTML='';const w=map.clientWidth,h=map.clientHeight,total=kids.reduce((s,x)=>s+x.size,0)||1;
  let cursor=0; const horizontal=w>=h;
  kids.forEach((n,i)=>{{const frac=n.size/total;const d=document.createElement('div');d.className='tile '+n.kind;
    if(horizontal){{d.style.left=(cursor*100)+'%';d.style.top=0;d.style.width=(frac*100)+'%';d.style.height='100%';}}
    else{{d.style.top=(cursor*100)+'%';d.style.left=0;d.style.height=(frac*100)+'%';d.style.width='100%';}}
    cursor+=frac;const label=document.createElement('span');label.textContent=n.name+' · '+bytes(n.size);d.append(label);
    d.onclick=()=>{{if(n.children&&n.children.length){{current=n;render()}}}};
    d.onmousemove=e=>{{tip.style.display='block';tip.style.left=(e.clientX+12)+'px';tip.style.top=(e.clientY+12)+'px';tip.textContent=n.path+' · '+bytes(n.size)+' · '+n.files+' files'}};
    d.onmouseleave=()=>tip.style.display='none';map.append(d);}});
  const rows=document.querySelector('#rows');rows.innerHTML='';
  kids.slice(0,60).forEach(n=>{{const tr=document.createElement('tr');tr.innerHTML='<td></td><td class="muted"></td><td class="size"></td>';
    tr.children[0].textContent=n.name;tr.children[1].textContent=n.kind;tr.children[2].textContent=bytes(n.size);
    tr.title=n.path;tr.onclick=()=>{{if(n.children&&n.children.length){{current=n;render()}}}};rows.append(tr);}});
}}
addEventListener('resize',render);render();
</script></body></html>"""


def write_space_report(root: SpaceNode, output: Path, *, allocated: bool) -> Path:
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(_report_html(root.report(), allocated), encoding="utf-8")
    return output


def write_space_json(root: SpaceNode, output: Path, *, allocated: bool) -> Path:
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    atomic = {
        "schema": 1,
        "allocated": allocated,
        "root": root.report(max_children=None),
    }
    output.write_text(
        json.dumps(atomic, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return output


def open_space_report(path: Path) -> None:
    webbrowser.open(path.as_uri())
