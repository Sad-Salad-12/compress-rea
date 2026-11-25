# Source provenance

Retrieved 2026-10-13 from official project release channels over HTTPS:

- FFmpeg download page: https://ffmpeg.org/download.html
- FFmpeg source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
- FFmpeg detached RSA signature: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz.asc
- FFmpeg release key: https://ffmpeg.org/ffmpeg-devel.asc
- LAME official download page: https://lame.sourceforge.io/download.php
- LAME official SourceForge source: https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz
- LAME published SHA256: https://sourceforge.net/projects/lame/files/latest/download
- pkgconf official project: https://github.com/pkgconf/pkgconf
- pkgconf release directory linked by the project: https://distfiles.ariadne.space/pkgconf/
- pkgconf source: https://distfiles.ariadne.space/pkgconf/pkgconf-3.0.8.tar.xz

FFmpeg's detached RSA signature was cryptographically verified using PGPy against the downloaded key, whose fingerprint was matched to the official download page: `FCF986EA15E6E293A5644F10B4322F04D67658D8`. PGPy's key revocation/trust checks are not implemented; this was signature and fingerprint verification, not a Web of Trust evaluation. FFmpeg also publishes post-quantum signatures; those were not used here.

LAME's archive SHA256 matched the checksum displayed by the project's official SourceForge download page. pkgconf's SHA256 was recorded locally after the HTTPS download; an independently published checksum was not found in its release directory.

`SHA256SUMS` records the exact input archives, and `rebuild-engine.sh` records the exact configure options used for the bundled binaries. Source files were not modified. Generated configure/build files live outside the input archives.
