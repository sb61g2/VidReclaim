# Third-party notices

VidReclaim's self-contained macOS package includes the following open-source
components. The installed executables report their own versions.

## FFmpeg

- Project: https://ffmpeg.org/
- Source: https://ffmpeg.org/download.html
- Homebrew build recipe: https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/f/ffmpeg.rb
- License for this GPL-enabled build: GNU GPL version 3 or later

Run `ffmpeg -version` to see the complete build configuration.

## HandBrake

- Project and source: https://github.com/HandBrake/HandBrake
- Release source: https://handbrake.fr/downloads2.php
- Homebrew build recipe: https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/h/handbrake.rb
- License: GNU GPL version 2

## CPython

- Project and source: https://www.python.org/
- License: Python Software Foundation License

## PyInstaller bootloader

- Project and source: https://github.com/pyinstaller/pyinstaller
- License: GPL version 2 with the PyInstaller exception for bundled programs

## Codec and support libraries

FFmpeg and HandBrake dynamically incorporate open-source codec and support
libraries collected into this package, including x264, x265, SVT-AV1, dav1d,
libvpx, Opus, LAME, libass, libdvdnav, libdvdread, libdvdcss, libbluray,
libvorbis, libogg, Speex, Theora, OpenSSL, and their transitive dependencies.
Their license texts and source links are available from their upstream projects
and the corresponding Homebrew formulae:

https://github.com/Homebrew/homebrew-core/tree/HEAD/Formula

No warranty is provided for VidReclaim or any bundled component.
