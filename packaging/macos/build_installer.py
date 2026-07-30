from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def run(args: list[str], *, cwd: Path = ROOT) -> None:
    print("+", " ".join(args), flush=True)
    subprocess.run(args, cwd=cwd, check=True)


def copy_plain(source: str | Path, destination: str | Path) -> str:
    source_path = Path(source)
    destination_path = Path(destination)
    shutil.copyfile(source_path, destination_path)
    destination_path.chmod(source_path.stat().st_mode & 0o777)
    return str(destination_path)


def copy_executable(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    copy_plain(source, destination)
    destination.chmod(0o755)


def build_app_icon(source: Path, destination: Path, build_root: Path) -> None:
    iconset = build_root / "VidReclaim.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, size in sizes.items():
        run([
            "/usr/bin/sips",
            "-z", str(size), str(size),
            str(source),
            "--out", str(iconset / name),
        ])
    run([
        "/usr/bin/iconutil",
        "-c", "icns",
        str(iconset),
        "-o", str(destination),
    ])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="0.6.5")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "outputs")
    parser.add_argument(
        "--build-dir", type=Path,
        default=Path(tempfile.gettempdir()) / "vidreclaim-macos-installer",
    )
    args = parser.parse_args()
    os.environ["COPYFILE_DISABLE"] = "1"

    build_root = args.build_dir.resolve()
    if build_root.exists():
        shutil.rmtree(build_root)
    dist = build_root / "pyinstaller-dist"
    pywork = build_root / "pyinstaller-work"
    spec = build_root / "spec"
    payload = build_root / "payload"
    component_dir = build_root / "component"
    resources = build_root / "resources"
    scripts = build_root / "scripts"
    for path in (dist, pywork, spec, payload, component_dir, resources, scripts):
        path.mkdir(parents=True, exist_ok=True)

    run([
        args.python, "-m", "PyInstaller",
        "--noconfirm", "--clean", "--onedir", "--console",
        "--name", "vidreclaim",
        "--distpath", str(dist),
        "--workpath", str(pywork),
        "--specpath", str(spec),
        "--paths", str(ROOT),
        "--add-data", f"{ROOT / 'vidreclaim' / 'windows_worker.ps1'}:vidreclaim",
        "--add-binary", "/opt/homebrew/bin/ffmpeg:tools",
        "--add-binary", "/opt/homebrew/bin/ffprobe:tools",
        "--add-binary", "/opt/homebrew/bin/HandBrakeCLI:tools",
        str(HERE / "entry.py"),
    ])

    frozen = dist / "vidreclaim"
    install_root = payload / "usr" / "local" / "libexec" / "vidreclaim"
    shutil.copytree(
        frozen, install_root, dirs_exist_ok=True, copy_function=copy_plain,
    )
    copy_executable(HERE / "bin" / "vidreclaim", payload / "usr/local/bin/vidreclaim")
    copy_executable(
        HERE / "bin" / "vidreclaim-uninstall",
        payload / "usr/local/bin/vidreclaim-uninstall",
    )

    docs = payload / "usr/local/share/doc/vidreclaim"
    docs.mkdir(parents=True, exist_ok=True)
    copy_plain(ROOT / "README.md", docs / "README.md")
    copy_plain(HERE / "THIRD_PARTY_NOTICES.md", docs / "THIRD_PARTY_NOTICES.md")

    app = payload / "Applications" / "VidReclaim.app"
    app_macos = app / "Contents" / "MacOS"
    app_resources = app / "Contents" / "Resources"
    app_macos.mkdir(parents=True, exist_ok=True)
    app_resources.mkdir(parents=True, exist_ok=True)
    info_plist = app / "Contents" / "Info.plist"
    info_plist.write_text(
        (HERE / "gui" / "Info.plist.in").read_text(encoding="utf-8")
        .replace("@VERSION@", args.version),
        encoding="utf-8",
    )
    build_app_icon(
        HERE / "gui" / "assets" / "VidReclaimIcon.png",
        app_resources / "VidReclaim.icns",
        build_root,
    )
    run([
        "/usr/bin/xcrun", "swiftc",
        "-swift-version", "5",
        "-target", "arm64-apple-macos26.0",
        "-parse-as-library",
        "-O",
        "-framework", "SwiftUI",
        "-framework", "AppKit",
        str(HERE / "gui" / "VidReclaimApp.swift"),
        "-o", str(app_macos / "VidReclaim"),
    ])
    # File-provider-backed build folders (including iCloud Documents) can attach
    # Finder metadata that strict code-signing verification rejects. Remove it
    # before signing, then verify the exact bundle that will enter the package.
    run(["/usr/bin/xattr", "-cr", str(payload)])
    run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)])
    run([
        "/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2",
        str(app),
    ])
    run([
        "/usr/bin/codesign", "--force", "--deep", "--sign", "-",
        str(install_root / "vidreclaim"),
    ])
    shutil.copytree(
        HERE / "scripts", scripts, dirs_exist_ok=True, copy_function=copy_plain,
    )
    for script in scripts.iterdir():
        script.chmod(0o755)

    component = component_dir / "vidreclaim-component.pkg"
    run([
        "/usr/bin/pkgbuild",
        "--root", str(payload),
        "--identifier", "io.vidreclaim.pkg",
        "--version", args.version,
        "--install-location", "/",
        "--scripts", str(scripts),
        str(component),
    ])

    shutil.copytree(
        HERE / "resources", resources, dirs_exist_ok=True,
        copy_function=copy_plain,
    )
    distribution = build_root / "distribution.xml"
    distribution.write_text(
        (HERE / "distribution.xml.in").read_text(encoding="utf-8")
        .replace("@VERSION@", args.version),
        encoding="utf-8",
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = (
        args.output_dir
        / f"VidReclaim-{args.version}-macOS26+-arm64-unsigned.pkg"
    ).resolve()
    run([
        "/usr/bin/productbuild",
        "--distribution", str(distribution),
        "--package-path", str(component_dir),
        "--resources", str(resources),
        str(output),
    ])
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
