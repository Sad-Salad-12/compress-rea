#!/bin/zsh
# Compile and run the engine and queue smoke tests against Engine/ffmpeg and Engine/ffprobe.
# All media is generated on the fly; nothing outside Tests/.build is written.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$root/Engine"
work="$root/Tests/.build"
if [[ ! -x "$engine/ffmpeg" || ! -x "$engine/ffprobe" ]]; then
    print "Engine/ffmpeg and Engine/ffprobe are required. See README.md."
    exit 1
fi
rm -rf "$work"; mkdir -p "$work/core" "$work/fixtures"
swift_flags=(-swift-version 5 -parse-as-library -O -target arm64-apple-macosx14.0)

print "== Generating fixtures"
"$engine/ffmpeg" -hide_banner -loglevel error -f lavfi -i "color=c=white@0.6:s=64x32,format=rgba" -frames:v 1 "$work/core/watermark.png"
"$engine/ffmpeg" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=640x360:rate=30" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 4 -c:v mpeg4 -q:v 3 -c:a aac \
    "$work/fixtures/Tester's 测试 clip.mp4"
"$engine/ffmpeg" -hide_banner -loglevel error -f lavfi -i "sine=frequency=550:sample_rate=48000" -t 3 \
    "$work/fixtures/sample.wav"

print "== Building EngineSmoke"
xcrun swiftc "${swift_flags[@]}" \
    "$root/Source/MediaEngine.swift" "$root/Source/ProcessRunner.swift" "$root/Tests/EngineSmoke.swift" \
    -o "$work/EngineSmoke"
print "== Building QueueSmokeTests"
xcrun swiftc "${swift_flags[@]}" -D HEADLESS_TEST \
    "$root/Source/App.swift" "$root/Source/MediaEngine.swift" "$root/Source/ProcessRunner.swift" "$root/Tests/QueueSmokeTests.swift" \
    -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation \
    -o "$work/QueueSmokeTests"

print "== Running EngineSmoke"
"$work/EngineSmoke" "$work/core" "$engine/ffmpeg" "$engine/ffprobe"
print "== Running QueueSmokeTests"
"$work/QueueSmokeTests" "$engine" "$work/fixtures" "$work/queue-results.json"
print "All smoke tests passed. Output: $work"
