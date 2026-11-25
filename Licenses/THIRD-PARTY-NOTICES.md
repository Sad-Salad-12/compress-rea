# Third-party notices

Compress REA's own source code (everything under `Source/`, `Tests/`, and the build scripts) is licensed under the MIT License; see `../LICENSE`. The media engine bundled inside the app is a separate set of programs with its own licenses, listed below. The app runs those programs as separate processes.

The engine executables were built from unmodified, officially published source archives.

FFmpeg 9.0.2: https://ffmpeg.org/ — built under LGPL version 2.1 or later, without the `--enable-gpl`, `--enable-version3`, or `--enable-nonfree` options. See `FFmpeg-LICENSE.md` and `FFmpeg-COPYING.LGPLv2.1`. Files retain their original individual copyright and license notices in the source archive.

LAME 4.0: https://lame.sourceforge.io/ — MP3 encoding is provided by the statically linked LAME library. See `LAME-COPYING` and `LAME-LICENSE`. LAME source was not modified.

This software is based in part on the work of the Independent JPEG Group. The FFmpeg files derived from libjpeg (`jfdctfst.c`, `jfdctint_template.c`, `jrevdct.c`) were not modified.

pkgconf 3.0.8: https://github.com/pkgconf/pkgconf — a build-time dependency only. It is not linked into either runtime executable. Its ISC-style copyright/permission notice is included for the rebuild process.

## Corresponding source

The exact source archives used for the bundled engine (`ffmpeg-9.0.2.tar.xz`, `lame-4.0.tar.gz`, `pkgconf-3.0.8.tar.xz`) are attached to every GitHub Release of this project, next to the app download. `../Engine-Sources/fetch-sources.sh` downloads the same archives from the official project sites, and `../Engine-Sources/SHA256SUMS` lets you verify them.

`../Engine-Sources/rebuild-engine.sh` lets a recipient rebuild or change the LGPL components using Apple's command-line compiler and make. The final executables are copied into the `Engine` folder, and `../Build.command` packages them into the app. The app may use any compatible user-built `ffmpeg`/`ffprobe` in place of the bundled ones.

Apple's system VideoToolbox and AudioToolbox frameworks and system compression libraries are loaded from macOS. They are not distributed in this package.
