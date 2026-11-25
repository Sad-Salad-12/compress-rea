#!/bin/sh
# Download the exact upstream source archives used for the bundled engine
# from the official project sites, then verify them against SHA256SUMS.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
fetch() {
    if [ -f "$1" ]; then
        printf '%s\n' "Already present: $1"
    else
        printf '%s\n' "Downloading $1"
        curl -fL --retry 3 -o "$1.part" "$2"
        mv "$1.part" "$1"
    fi
}
fetch ffmpeg-9.0.2.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
fetch lame-4.0.tar.gz https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz
fetch pkgconf-3.0.8.tar.xz https://distfiles.ariadne.space/pkgconf/pkgconf-3.0.8.tar.xz
shasum -a 256 -c SHA256SUMS
printf '%s\n' "Sources verified. Next: ./rebuild-engine.sh"
