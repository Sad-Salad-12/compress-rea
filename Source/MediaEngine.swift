import Foundation

struct MediaInfo: Codable, Sendable {
    var duration: Double
    var width: Int
    var height: Int
    var hasVideo: Bool
    var hasAudio: Bool
    var size: Int64

    init(duration: Double = 0, width: Int = 0, height: Int = 0,
         hasVideo: Bool = false, hasAudio: Bool = false, size: Int64 = 0) {
        self.duration = duration
        self.width = width
        self.height = height
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.size = size
    }
}

enum VideoCodec: String, CaseIterable, Codable, Sendable {
    case h264, hevc, mpeg4
}

struct ExportSettings: Sendable {
    var format = "mp4"
    var videoCodec: VideoCodec = .h264
    var resolution = 0
    var customWidth = 0
    var customHeight = 0
    var exactResolution = false
    var videoBitrateKbps = 0
    var fps = 0
    var audioBitrateKbps = 128
    var sampleRate = 0
    var channels = 0
    var volume = 1.0
    var rotate = 0
    var flip = "none"
    var cropLeft = 0
    var cropRight = 0
    var cropTop = 0
    var cropBottom = 0
    var trimStart = 0.0
    var trimEnd = 0.0
    var watermark: URL?
    var watermarkPosition = "bottom-right"
    var merge = false

    init() {}
}

enum MediaEngineError: LocalizedError {
    case invalid(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .processFailed(let message): return message
        }
    }
}

enum MediaEngine {
    static let videoFormats = ["mp4", "mov", "mkv", "avi"]
    static let audioFormats = ["m4a", "mp3", "wav", "flac", "aiff", "ogg"]

    /// Runs synchronously; callers should invoke this on a background queue.
    static func probe(url: URL, ffprobe: URL) throws -> MediaInfo {
        try validateInput(url)
        try validateExecutable(ffprobe)
        let result = try capture(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries",
            "format=duration,size:stream=codec_type,width,height,duration:stream_disposition=attached_pic:stream_tags=rotate:stream_side_data=rotation",
            "-of", "json", url.path
        ])
        guard result.status == 0 else {
            throw MediaEngineError.processFailed("Could not read media information. \(result.stderr)")
        }
        guard !result.stdoutOverflow else {
            throw MediaEngineError.processFailed("The media information was too large to read.")
        }
        let document: ProbeDocument
        do { document = try JSONDecoder().decode(ProbeDocument.self, from: result.stdout) }
        catch { throw MediaEngineError.processFailed("The media information could not be decoded.") }
        let video = document.streams.first { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 }
        let hasAudio = document.streams.contains { $0.codec_type == "audio" }
        guard video != nil || hasAudio else {
            throw MediaEngineError.invalid("This file has no readable video or audio stream.")
        }
        var width = video?.width ?? 0
        var height = video?.height ?? 0
        let rotation = video?.side_data_list?.compactMap(\.rotation).first
            ?? video?.tags?["rotate"].flatMap(Double.init) ?? 0
        if rotation.isFinite && abs(Int(rotation.rounded()) % 180) == 90 {
            swap(&width, &height)
        }
        let durations = [document.format?.duration.flatMap(Double.init)]
            + document.streams.map { $0.duration.flatMap(Double.init) }
        let duration = durations.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
        let actualSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return MediaInfo(duration: duration, width: width, height: height,
                         hasVideo: video != nil, hasAudio: hasAudio,
                         size: actualSize.map(Int64.init) ?? document.format?.size.flatMap(Int64.init) ?? 0)
    }

    /// Returns Process.arguments, excluding the executable. No shell is involved.
    /// The caller owns the partial output and must publish it only after a successful exit.
    static func command(input: URL, info: MediaInfo, output: URL,
                        settings: ExportSettings, ffmpeg: URL) throws -> [String] {
        try validateInput(input)
        try validateExecutable(ffmpeg)
        try validateOutput(output, inputs: [input])
        let format = settings.format.lowercased()
        guard let muxer = muxers[format] else {
            throw MediaEngineError.invalid("Choose a supported output format.")
        }
        let audioOnly = audioFormats.contains(format)
        guard audioOnly ? info.hasAudio : info.hasVideo else {
            throw MediaEngineError.invalid(audioOnly
                ? "This file has no audio to export."
                : "Choose an audio format for a file without video.")
        }
        if !audioOnly && format == "avi" && settings.videoCodec == .hevc {
            throw MediaEngineError.invalid("HEVC requires MP4, MOV, or MKV output.")
        }
        try validateSettings(settings, info: info, audioOnly: audioOnly, format: format)

        var arguments = ["-hide_banner", "-nostdin", "-n", "-loglevel", "error",
                         "-progress", "pipe:1", "-nostats", "-i", input.path]
        if !audioOnly, let watermark = settings.watermark {
            try validateInput(watermark)
            arguments += ["-i", watermark.path]
        }
        // Output seeking provides accurate cuts even between input keyframes.
        if settings.trimStart > 0 { arguments += ["-ss", decimal(settings.trimStart)] }
        if settings.trimEnd > 0 {
            arguments += ["-t", decimal(settings.trimEnd - settings.trimStart)]
        }

        if audioOnly {
            arguments += ["-vn", "-map", "0:a:0"]
        } else {
            let filters = videoFilters(settings)
            if settings.watermark != nil {
                let base = filters.isEmpty ? "null" : filters.joined(separator: ",")
                let position = overlayPosition(settings.watermarkPosition)
                arguments += ["-filter_complex",
                    "[0:V:0]\(base)[base];[1:v:0]format=rgba[wm];[base][wm]overlay=\(position):eof_action=repeat:eval=init[vout]",
                    "-map", "[vout]"]
            } else {
                // Uppercase V excludes attached cover art (FFmpeg stream-specifier contract).
                arguments += ["-map", "0:V:0"]
                if !filters.isEmpty { arguments += ["-vf", filters.joined(separator: ",")] }
            }
            if info.hasAudio { arguments += ["-map", "0:a:0"] }
            else { arguments += ["-an"] }
            switch settings.videoCodec {
            case .h264: arguments += ["-c:v", "h264_videotoolbox", "-allow_sw", "1"]
            case .hevc: arguments += ["-c:v", "hevc_videotoolbox", "-allow_sw", "1"]
            case .mpeg4: arguments += ["-c:v", "mpeg4"]
            }
            arguments += ["-pix_fmt", "yuv420p"]
            if settings.videoBitrateKbps > 0 {
                arguments += ["-b:v", "\(settings.videoBitrateKbps)k"]
            } else if settings.videoCodec == .mpeg4 {
                arguments += ["-q:v", "4"]
            } else {
                // VideoToolbox's low default bitrate is unsuitable for ordinary HD media.
                arguments += ["-b:v", "\(automaticBitrate(settings, info: info))k"]
            }
            if settings.fps > 0 { arguments += ["-r", String(settings.fps)] }
            if settings.videoCodec == .hevc && ["mp4", "mov"].contains(format) {
                arguments += ["-tag:v", "hvc1"]
            }
        }
        if info.hasAudio {
            let audioCodec = audioCodecs[format] ?? (format == "avi" ? "libmp3lame" : "aac")
            arguments += ["-c:a", audioCodec]
            if !["pcm_s16le", "pcm_s16be", "flac", "vorbis"].contains(audioCodec), settings.audioBitrateKbps > 0 {
                arguments += ["-b:a", "\(settings.audioBitrateKbps)k"]
            }
            if settings.sampleRate > 0 { arguments += ["-ar", String(settings.sampleRate)] }
            if format == "ogg" {
                arguments += ["-strict", "experimental", "-ac", "2", "-q:a", String(vorbisQuality(settings.audioBitrateKbps))]
            }
            else if settings.channels > 0 { arguments += ["-ac", String(settings.channels)] }
            if settings.volume != 1 { arguments += ["-af", "volume=\(decimal(settings.volume))"] }
        }
        arguments += ["-map_metadata", "0", "-sn", "-dn"]
        if ["mp4", "mov", "m4a"].contains(format) { arguments += ["-movflags", "+faststart"] }
        arguments += ["-f", muxer, output.path]
        return arguments
    }

    static func uniqueOutput(input: URL, directory: URL, format: String) -> URL {
        let requested = format.lowercased()
        let suffix = muxers[requested] == nil ? "mp4" : requested
        let stem = String(input.deletingPathExtension().lastPathComponent.prefix(160))
        var number = 0
        while true {
            let name = "\(stem)-compressed\(number == 0 ? "" : "-\(number)").\(suffix)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path)
                && candidate.resolvingSymlinksInPath().standardizedFileURL != input.resolvingSymlinksInPath().standardizedFileURL {
                return candidate
            }
            number += 1
        }
    }

    /// Inputs must already share codec, dimensions, timebase, and stream layout.
    /// listFile must be inside the caller's owned temporary job directory.
    static func mergeCommand(inputs: [URL], output: URL, listFile: URL, ffmpeg: URL) throws -> [String] {
        guard inputs.count >= 2 else { throw MediaEngineError.invalid("Add at least two files to merge.") }
        try validateExecutable(ffmpeg)
        for input in inputs { try validateInput(input) }
        try validateOutput(output, inputs: inputs)
        guard listFile.isFileURL, !FileManager.default.fileExists(atPath: listFile.path),
              !inputs.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == listFile.resolvingSymlinksInPath().standardizedFileURL }),
              output.resolvingSymlinksInPath().standardizedFileURL != listFile.resolvingSymlinksInPath().standardizedFileURL else {
            throw MediaEngineError.invalid("The temporary merge list must be a new local file.")
        }
        // Match partial outputs such as .merged.partial.mp4; normalize jobs carry this extension.
        let format = output.pathExtension.lowercased()
        guard let muxer = muxers[format] else {
            throw MediaEngineError.invalid("The merged output must have a supported format extension.")
        }
        let lines = try inputs.map { input -> String in
            let path = input.standardizedFileURL.path
            guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
                throw MediaEngineError.invalid("A merge input has a filename that cannot be represented safely.")
            }
            // FFconcat quoting: close the quote, escape the apostrophe, then reopen it.
            return "file '\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        let contents = "ffconcat version 1.0\n" + lines.joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: listFile, options: .withoutOverwriting)
        var arguments = ["-hide_banner", "-nostdin", "-n", "-loglevel", "error",
                         "-progress", "pipe:1", "-nostats", "-f", "concat", "-safe", "0",
                         "-i", listFile.path, "-map", "0", "-c", "copy"]
        if ["mp4", "mov", "m4a"].contains(format) { arguments += ["-movflags", "+faststart"] }
        arguments += ["-f", muxer, output.path]
        return arguments
    }

    private static let muxers = ["mp4": "mp4", "mov": "mov", "mkv": "matroska", "avi": "avi",
                                 "m4a": "ipod", "mp3": "mp3", "wav": "wav", "flac": "flac",
                                 "aiff": "aiff", "ogg": "ogg"]
    private static let audioCodecs = ["m4a": "aac", "mp3": "libmp3lame", "wav": "pcm_s16le",
                                      "flac": "flac", "aiff": "pcm_s16be", "ogg": "vorbis"]

    private static func validateInput(_ url: URL) throws {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw MediaEngineError.invalid("The input is not a readable local file: \(url.lastPathComponent)")
        }
    }

    private static func validateExecutable(_ url: URL) throws {
        guard url.isFileURL, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MediaEngineError.invalid("The media tools are missing or are not executable.")
        }
    }

    private static func validateOutput(_ output: URL, inputs: [URL]) throws {
        let resolved = output.resolvingSymlinksInPath().standardizedFileURL
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path),
              !inputs.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == resolved }) else {
            throw MediaEngineError.invalid("Choose a new output file. Existing files and originals are protected.")
        }
        guard (try? output.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw MediaEngineError.invalid("The output folder does not exist.")
        }
    }

    private static func validateSettings(_ s: ExportSettings, info: MediaInfo, audioOnly: Bool, format: String) throws {
        guard s.trimStart.isFinite, s.trimEnd.isFinite, s.trimStart >= 0, s.trimEnd >= 0,
              s.trimEnd == 0 || s.trimEnd > s.trimStart,
              info.duration <= 0 || s.trimStart < info.duration,
              info.duration <= 0 || s.trimEnd <= info.duration + 0.05 else {
            throw MediaEngineError.invalid("Set a valid start and end time within the media duration.")
        }
        guard s.volume.isFinite, (0...8).contains(s.volume),
              (0...512).contains(s.audioBitrateKbps),
              (0...192_000).contains(s.sampleRate), (0...8).contains(s.channels) else {
            throw MediaEngineError.invalid("Check the audio bitrate, sample rate, channels, and volume.")
        }
        if format == "mp3" || format == "avi" {
            guard s.channels <= 2, s.audioBitrateKbps <= 320,
                  s.sampleRate == 0 || [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000].contains(s.sampleRate) else {
                throw MediaEngineError.invalid("MP3 audio supports up to two channels, 320 kbps, and sample rates up to 48 kHz.")
            }
        }
        if format == "ogg" && ![0, 2].contains(s.channels) {
            throw MediaEngineError.invalid("OGG output currently supports stereo audio. Choose Original or 2 channels.")
        }
        if audioOnly { return }
        guard [-1, 0, 480, 720, 1080, 2160].contains(s.resolution),
              (0...500_000).contains(s.videoBitrateKbps), (0...240).contains(s.fps),
              [0, 90, 180, 270].contains(s.rotate), ["none", "horizontal", "vertical"].contains(s.flip),
              [s.cropLeft, s.cropRight, s.cropTop, s.cropBottom].allSatisfy({ (0...16_384).contains($0) }) else {
            throw MediaEngineError.invalid("Check the video dimensions, bitrate, frame rate, rotation, and crop. Custom dimensions must be even numbers.")
        }
        if s.resolution == -1 && ![s.customWidth, s.customHeight].allSatisfy({ (2...16_384).contains($0) && $0.isMultiple(of: 2) }) {
            throw MediaEngineError.invalid("Enter a positive even width and height for Custom resolution.")
        }
        if s.cropLeft + s.cropRight > 0 || s.cropTop + s.cropBottom > 0 {
            guard info.width > s.cropLeft + s.cropRight + 1,
                  info.height > s.cropTop + s.cropBottom + 1 else {
                throw MediaEngineError.invalid("The crop must leave at least two pixels in each dimension.")
            }
        }
        if s.watermark != nil && !["top-left", "top-right", "bottom-left", "bottom-right", "center"].contains(s.watermarkPosition) {
            throw MediaEngineError.invalid("Choose a supported watermark position.")
        }
    }

    private static func videoFilters(_ s: ExportSettings) -> [String] {
        var filters: [String] = []
        if s.cropLeft + s.cropRight + s.cropTop + s.cropBottom > 0 {
            filters.append("crop=iw-\(s.cropLeft + s.cropRight):ih-\(s.cropTop + s.cropBottom):\(s.cropLeft):\(s.cropTop)")
        }
        switch s.rotate {
        case 90: filters.append("transpose=clock")
        case 180: filters += ["hflip", "vflip"]
        case 270: filters.append("transpose=cclock")
        default: break
        }
        if s.flip == "horizontal" { filters.append("hflip") }
        if s.flip == "vertical" { filters.append("vflip") }
        if let box = resolutionBox(s) {
            filters.append("scale=\(box.width):\(box.height):force_original_aspect_ratio=decrease:force_divisible_by=2")
            if s.exactResolution {
                filters.append("pad=\(box.width):\(box.height):(ow-iw)/2:(oh-ih)/2:color=black")
            }
        }
        filters += ["scale=trunc(iw/2)*2:trunc(ih/2)*2", "setsar=1"]
        return filters
    }

    private static func automaticBitrate(_ s: ExportSettings, info: MediaInfo) -> Int {
        let box = resolutionBox(s)
        let height = box?.height ?? max(info.height, 2)
        let width = box?.width ?? max(info.width, 2)
        let bitsPerPixel = s.videoCodec == .hevc ? 0.05 : 0.08
        let kbps = Double(width) * Double(height) * Double(s.fps > 0 ? s.fps : 30) * bitsPerPixel / 1000
        return Int(min(50_000, max(1000, kbps)))
    }

    private static func resolutionBox(_ s: ExportSettings) -> (width: Int, height: Int)? {
        if s.resolution == -1 { return (s.customWidth, s.customHeight) }
        if s.resolution > 0 {
            let width = Int((Double(s.resolution) * 16.0 / 9.0 / 2.0).rounded()) * 2
            return (width, s.resolution)
        }
        return nil
    }

    private static func overlayPosition(_ value: String) -> String {
        switch value {
        case "top-left": return "10:10"
        case "top-right": return "main_w-overlay_w-10:10"
        case "bottom-left": return "10:main_h-overlay_h-10"
        case "center": return "(main_w-overlay_w)/2:(main_h-overlay_h)/2"
        default: return "main_w-overlay_w-10:main_h-overlay_h-10"
        }
    }

    private static func vorbisQuality(_ requested: Int) -> Int {
        let presets = [(64, 0), (96, 2), (128, 4), (160, 5), (192, 6), (256, 8), (320, 10)]
        let target = requested > 0 ? requested : 128
        return presets.min(by: { abs($0.0 - target) < abs($1.0 - target) })?.1 ?? 4
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private struct ProbeDocument: Decodable {
        var streams: [ProbeStream]
        var format: ProbeFormat?
    }
    private struct ProbeFormat: Decodable { var duration: String?; var size: String? }
    private struct ProbeStream: Decodable {
        var codec_type: String?
        var width: Int?
        var height: Int?
        var duration: String?
        var disposition: Disposition?
        var tags: [String: String]?
        var side_data_list: [SideData]?
    }
    private struct Disposition: Decodable { var attached_pic: Int? }
    private struct SideData: Decodable { var rotation: Double? }

    private final class CaptureBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var overflow = false
        init(limit: Int) { self.limit = limit }
        func drain(_ handle: FileHandle) {
            while true {
                let chunk = handle.readData(ofLength: 16_384)
                if chunk.isEmpty { break }
                lock.lock()
                let remaining = max(0, limit - data.count)
                if chunk.count > remaining { overflow = true }
                data.append(chunk.prefix(remaining))
                lock.unlock()
            }
        }
        func value() -> (Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (data, overflow)
        }
    }

    private static func capture(executable: URL, arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: String, stdoutOverflow: Bool) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = CaptureBuffer(limit: 8 * 1024 * 1024)
        let stderr = CaptureBuffer(limit: 128 * 1024)
        try process.run()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { stdout.drain(stdoutPipe.fileHandleForReading); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { stderr.drain(stderrPipe.fileHandleForReading); group.leave() }
        process.waitUntilExit()
        group.wait()
        let (data, overflow) = stdout.value()
        let (errors, truncated) = stderr.value()
        let message = String(decoding: errors, as: UTF8.self) + (truncated ? "\n[Error output truncated]" : "")
        return (process.terminationStatus, data, message, overflow)
    }
}
