#!/bin/sh
# Rebuild this independent engine locally with Apple's command-line tools.
# No global installation, Homebrew, app bundle code, or network download is used.
set -eu
engine_source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
engine_output_dir="$(dirname "$engine_source_dir")/Engine"
# Use a private path without spaces for configure/compiler flag compatibility.
build_dir=$(mktemp -d /tmp/compress-engine-rebuild.XXXXXX)
mkdir -p "$engine_output_dir"
test "$(uname -m)" = arm64
cd "$engine_source_dir"
shasum -a 256 -c SHA256SUMS
cd "$build_dir"
tar -xf "$engine_source_dir/pkgconf-3.0.8.tar.xz"
tar -xf "$engine_source_dir/lame-4.0.tar.gz"
tar -xf "$engine_source_dir/ffmpeg-9.0.2.tar.xz"
cd "$build_dir/pkgconf-3.0.8"
CC=clang CFLAGS='-O2 -mmacosx-version-min=12.0' LDFLAGS='-mmacosx-version-min=12.0' ./configure --prefix="$build_dir/tools" --enable-static --disable-shared
make -j8
make install
cd "$build_dir/lame-4.0"
PKG_CONFIG="$build_dir/tools/bin/pkgconf" CC=clang CFLAGS='-O3 -mmacosx-version-min=12.0' LDFLAGS='-mmacosx-version-min=12.0' ./configure --prefix="$build_dir/deps" --enable-static --disable-shared --disable-frontend --disable-decoder --disable-nasm
make -j8
make install
cd "$build_dir/ffmpeg-9.0.2"
./configure --prefix="$build_dir/output" --arch=arm64 --target-os=darwin --cc=clang --disable-shared --enable-static --disable-autodetect --disable-network --disable-doc --disable-debug --disable-ffplay --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv --enable-libmp3lame --pkg-config="$build_dir/tools/bin/pkgconf" --extra-cflags="-I$build_dir/deps/include -mmacosx-version-min=12.0" --extra-ldflags="-L$build_dir/deps/lib -mmacosx-version-min=12.0" --extra-libs=-liconv
make -j8
cp ffmpeg ffprobe "$engine_output_dir/"
printf '%s\n' "Built arm64 binaries in $engine_output_dir"
printf '%s\n' "Build sources, objects and static libraries retained in $build_dir"
