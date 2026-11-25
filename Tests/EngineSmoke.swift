import Foundation

@main struct EngineSmoke {
    struct Result: Codable { var name: String; var passed: Bool; var details: String }
    enum Failure: Error { case assertion(String) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.assertion(message) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let ffmpeg = URL(fileURLWithPath: CommandLine.arguments[2])
        let ffprobe = URL(fileURLWithPath: CommandLine.arguments[3])
        let fm = FileManager.default
        let job = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: job, withIntermediateDirectories: true)
        let input = job.appendingPathComponent("O'Brien 空 格 ;$().mp4")
        let portrait = job.appendingPathComponent("portrait.mp4")
        func run(_ arguments: [String], duration: Double = 2) throws {
            let progressArguments = arguments.contains("-progress") ? arguments : ["-progress", "pipe:1", "-nostats"] + arguments
            try ProcessRunner().run(executable: ffmpeg, arguments: progressArguments, duration: duration) { _ in }
        }
        try run(["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
                 "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2", "-c:v", "mpeg4", "-c:a", "aac", input.path])
        try run(["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=120x180:rate=30",
                 "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000", "-t", "2", "-c:v", "mpeg4", "-c:a", "aac", portrait.path])
        let originalData = try Data(contentsOf: input)
        let info = try MediaEngine.probe(url: input, ffprobe: ffprobe)
        var results: [Result] = []
        func test(_ name: String, _ body: () throws -> String) {
            do { let detail = try body(); results.append(Result(name: name, passed: true, details: detail)); print("PASS \(name): \(detail)") }
            catch { results.append(Result(name: name, passed: false, details: String(describing: error))); print("FAIL \(name): \(error)") }
        }
        func convert(_ name: String, _ settings: ExportSettings, source: URL? = nil) throws -> MediaInfo {
            let source = source ?? input
            let details = try MediaEngine.probe(url: source, ffprobe: ffprobe)
            let output = job.appendingPathComponent(name)
            let arguments = try MediaEngine.command(input: source, info: details, output: output, settings: settings, ffmpeg: ffmpeg)
            try run(arguments)
            return try MediaEngine.probe(url: output, ffprobe: ffprobe)
        }
        test("probe Unicode / apostrophe / shell punctuation filename") {
            try require(info.hasAudio && info.hasVideo && info.width == 320 && info.height == 180 && abs(info.duration - 2) < 0.1 && info.size > 0, "unexpected media metadata")
            return "320×180, audio+video, \(info.duration) sec"
        }
        for format in MediaEngine.audioFormats {
            test("audio-only \(format)") {
                var settings = ExportSettings(); settings.format = format
                let result = try convert("audio.\(format)", settings)
                try require(result.hasAudio && !result.hasVideo && result.duration > 1.8 && result.size > 0, "audio output invalid")
                return "\(result.size) bytes, \(result.duration) sec"
            }
        }
        for (format, codec) in [("mp4", VideoCodec.h264), ("mov", .hevc), ("mkv", .mpeg4), ("avi", .mpeg4)] {
            test("video \(format) / \(codec.rawValue)") {
                var settings = ExportSettings(); settings.format = format; settings.videoCodec = codec
                let result = try convert("video.\(format)", settings)
                try require(result.hasAudio && result.hasVideo && result.width == 320 && result.height == 180 && result.duration > 1.8, "video output invalid")
                return "320×180, \(result.size) bytes"
            }
        }
        test("crop, rotation, flip, volume, trim, watermark, exact custom padding") {
            var settings = ExportSettings(); settings.videoCodec = .mpeg4
            settings.cropLeft = 10; settings.cropRight = 10; settings.cropTop = 10; settings.cropBottom = 10
            settings.rotate = 90; settings.flip = "horizontal"; settings.volume = 0.5
            settings.trimStart = 0.25; settings.trimEnd = 1.25
            settings.resolution = -1; settings.customWidth = 200; settings.customHeight = 200; settings.exactResolution = true
            settings.watermark = root.appendingPathComponent("watermark.png"); settings.watermarkPosition = "center"
            let result = try convert("transformed.mp4", settings)
            try require(result.width == 200 && result.height == 200 && abs(result.duration - 1) < 0.15, "transform size/duration invalid")
            return "200×200, \(result.duration) sec"
        }
        test("custom values do not override a standard preset; portrait fits exact box") {
            var settings = ExportSettings(); settings.videoCodec = .mpeg4; settings.resolution = 480
            settings.customWidth = 200; settings.customHeight = 200; settings.exactResolution = true
            let result = try convert("portrait-padded.mp4", settings, source: portrait)
            try require(result.width == 854 && result.height == 480, "preset did not use standard box")
            return "854×480"
        }
        test("original/existing output rejected; unique output chooses unused name") {
            var rejected = 0
            for output in [input, job.appendingPathComponent("audio.mp3")] {
                do { _ = try MediaEngine.command(input: input, info: info, output: output, settings: ExportSettings(), ffmpeg: ffmpeg) }
                catch { rejected += 1 }
            }
            try require(rejected == 2, "existing file was accepted")
            let candidate = MediaEngine.uniqueOutput(input: input, directory: job, format: "mp4")
            try Data("keep".utf8).write(to: candidate)
            let next = MediaEngine.uniqueOutput(input: input, directory: job, format: "mp4")
            try require(next != candidate && !fm.fileExists(atPath: next.path), "unique name reused output")
            return "both protected; suffix increments"
        }
        test("FFmpeg -n protects a file created after argument construction") {
            let output = job.appendingPathComponent("race.mp4")
            let arguments = try MediaEngine.command(input: input, info: info, output: output, settings: ExportSettings(), ffmpeg: ffmpeg)
            let sentinel = Data("do not replace".utf8); try sentinel.write(to: output)
            var rejected = false
            do { try run(arguments) } catch { rejected = true }
            try require(rejected && (try Data(contentsOf: output)) == sentinel, "late output overwritten")
            return "existing bytes unchanged"
        }
        test("bad crop / trim / custom / codec settings rejected") {
            var bad: [ExportSettings] = []
            var settings = ExportSettings(); settings.cropLeft = 320; bad.append(settings)
            settings = ExportSettings(); settings.trimStart = 1; settings.trimEnd = 0.5; bad.append(settings)
            settings = ExportSettings(); settings.trimStart = 3; bad.append(settings)
            settings = ExportSettings(); settings.resolution = -1; settings.customWidth = 201; settings.customHeight = 200; bad.append(settings)
            settings = ExportSettings(); settings.format = "avi"; settings.videoCodec = .hevc; bad.append(settings)
            settings = ExportSettings(); settings.format = "ogg"; settings.channels = 1; bad.append(settings)
            var count = 0
            for settings in bad {
                do { _ = try MediaEngine.command(input: input, info: info, output: job.appendingPathComponent("invalid.mp4"), settings: settings, ffmpeg: ffmpeg) }
                catch { count += 1 }
            }
            try require(count == bad.count, "invalid setting accepted")
            return "\(count) cases rejected"
        }
        test("normalized landscape+portrait merge with quoted paths") {
            var settings = ExportSettings(); settings.videoCodec = .mpeg4; settings.resolution = -1
            settings.customWidth = 320; settings.customHeight = 180; settings.exactResolution = true
            settings.fps = 30; settings.channels = 2; settings.sampleRate = 48000
            let normalized = [job.appendingPathComponent("clip O'Brien 空 格.mp4"), job.appendingPathComponent("portrait normalized.mp4")]
            for (source, output) in zip([input, portrait], normalized) {
                let sourceInfo = try MediaEngine.probe(url: source, ffprobe: ffprobe)
                try run(MediaEngine.command(input: source, info: sourceInfo, output: output, settings: settings, ffmpeg: ffmpeg))
            }
            let output = job.appendingPathComponent("merged.mp4")
            let arguments = try MediaEngine.mergeCommand(inputs: normalized, output: output, listFile: job.appendingPathComponent("concat.txt"), ffmpeg: ffmpeg)
            try run(arguments, duration: 4)
            let merged = try MediaEngine.probe(url: output, ffprobe: ffprobe)
            try require(merged.width == 320 && merged.height == 180 && merged.hasAudio && merged.duration > 3.8 && merged.duration < 4.3, "merged media invalid")
            return "320×180, \(merged.duration) sec"
        }
        test("progress callback and cancellation") {
            let runner = ProcessRunner()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { runner.cancel() }
            var cancelled = false; var midProgress = false
            do {
                try runner.run(executable: ffmpeg, arguments: ["-hide_banner", "-nostdin", "-loglevel", "error", "-re", "-i", input.path,
                    "-progress", "pipe:1", "-nostats", "-c", "copy", "-f", "null", "-"], duration: 2) { fraction in
                    if fraction > 0 && fraction < 1 { midProgress = true }
                }
            } catch ConversionError.cancelled { cancelled = true }
            try require(cancelled && midProgress, "cancellation/progress did not occur")
            return "progress observed and child stopped"
        }
        test("original remains byte-identical") {
            try require(try Data(contentsOf: input) == originalData, "original changed")
            return "\(originalData.count) original bytes preserved"
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: root.appendingPathComponent("core-smoke-results.json"))
        print("Test artifacts: \(job.path)")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
