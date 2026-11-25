#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/CompressREA-build.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_app="$task_build/Compress REA.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
if [[ ! -x "$task_root/Engine/ffmpeg" || ! -x "$task_root/Engine/ffprobe" ]]; then
    print "Engine/ffmpeg and Engine/ffprobe are required. See README.md."
    exit 1
fi
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx14.0 \
    "$task_root/Source/App.swift" "$task_root/Source/MediaEngine.swift" "$task_root/Source/ProcessRunner.swift" \
    -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation \
    -o "$task_app/Contents/MacOS/CompressREA"
cp "$task_root/Source/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/Engine/ffmpeg" "$task_root/Engine/ffprobe" "$task_app/Contents/Resources/"
if [[ -f "$task_root/Source/AppIcon.icns" ]]; then cp "$task_root/Source/AppIcon.icns" "$task_app/Contents/Resources/"; fi
if [[ -d "$task_root/Licenses" ]]; then
    mkdir -p "$task_app/Contents/Resources/Licenses"
    # Skip the external drive's AppleDouble metadata files when sealing resources.
    for task_license in "$task_root"/Licenses/*(.N); do
        COPYFILE_DISABLE=1 cp "$task_license" "$task_app/Contents/Resources/Licenses/"
    done
fi
chmod +x "$task_app/Contents/MacOS/CompressREA" "$task_app/Contents/Resources/ffmpeg" "$task_app/Contents/Resources/ffprobe"
codesign --force --sign - "$task_app/Contents/Resources/ffmpeg"
codesign --force --sign - "$task_app/Contents/Resources/ffprobe"
codesign --force --sign - "$task_app"
if [[ -d "$task_root/Compress REA.app" ]]; then
    task_backup="$task_root/Previous-Build-$(date +%Y%m%d-%H%M%S).app"
    mv "$task_root/Compress REA.app" "$task_backup"
fi
ditto --norsrc --noextattr "$task_app" "$task_root/Compress REA.app"
codesign --verify --deep --strict "$task_root/Compress REA.app"
print "Built: $task_root/Compress REA.app"
