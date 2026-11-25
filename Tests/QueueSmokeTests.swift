import Foundation
import AppKit

struct CheckResult: Codable {
    let name: String
    let passed: Bool
    let detail: String
}

@main struct QueueSmokeTests {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4 else { print("Usage: QueueSmokeTests ENGINE_DIR FIXTURE_DIR RESULTS.json"); exit(2) }
        let engine = URL(fileURLWithPath: args[1], isDirectory: true)
        let fixtures = URL(fileURLWithPath: args[2], isDirectory: true)
        let resultsURL = URL(fileURLWithPath: args[3])
        let destination = fixtures.appendingPathComponent("Queue Exports", isDirectory: true)
        let video = fixtures.appendingPathComponent("Tester's 测试 clip.mp4")
        let audio = fixtures.appendingPathComponent("sample.wav")
        var results: [CheckResult] = []
        let fm = FileManager.default
        let oldDirectory = UserDefaults.standard.object(forKey: "exportDirectory")
        defer {
            if let oldDirectory { UserDefaults.standard.set(oldDirectory, forKey: "exportDirectory") }
            else { UserDefaults.standard.removeObject(forKey: "exportDirectory") }
        }
        func record(_ name: String, _ passed: Bool, _ detail: String) { results.append(CheckResult(name: name, passed: passed, detail: detail)); print("\(passed ? "PASS" : "FAIL") \(name): \(detail)") }
        func wait(_ predicate: () -> Bool, timeout: Double = 40) async -> Bool {
            let start = Date()
            while !predicate() && Date().timeIntervalSince(start) < timeout { try? await Task.sleep(nanoseconds: 50_000_000) }
            return predicate()
        }
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let original = try Data(contentsOf: video)
            let model = QueueModel(engineDirectory: engine)
            model.destination = destination
            model.add([video, audio])
            let imported = await wait { !model.importing && model.items.count == 2 }
            record("Media import", imported && model.items.allSatisfy(\.ready), "\(model.items.count) files, \(model.selectedCount) ready; Unicode and apostrophe filename")
            model.settings.format = "mp4"
            model.settings.resolution = 480
            model.settings.videoBitrateKbps = 500
            model.settings.trimStart = 0.5
            model.settings.trimEnd = 2.5
            model.selectAll(false)
            if let id = model.items.first(where: { $0.url == video })?.id { model.update(id) { $0.selected = true } }
            model.export()
            let finished = await wait { !model.busy }
            let output = model.items.first(where: { $0.url == video })?.output
            if let output {
                let info = try MediaEngine.probe(url: output, ffprobe: engine.appendingPathComponent("ffprobe"))
                record("Queue video compression + trim", finished && info.hasVideo && info.height <= 480 && abs(info.duration - 2) < 0.25, "\(info.width)×\(info.height), \(info.duration)s, \(info.size) bytes")
            } else { record("Queue video compression + trim", false, model.items.first(where: { $0.url == video })?.error ?? model.alert ?? "No output") }
            let firstOutput = output.flatMap { try? Data(contentsOf: $0) }
            model.export()
            _ = await wait { !model.busy }
            let secondOutput = model.items.first(where: { $0.url == video })?.output
            record("Repeat export preserves existing files", output != nil && secondOutput != nil && output != secondOutput && (output.flatMap { try? Data(contentsOf: $0) } == firstOutput), secondOutput?.lastPathComponent ?? "No second output")

            model.selectAll(true)
            model.settings = ExportSettings()
            model.settings.format = "mp3"
            model.settings.channels = 2
            model.export()
            _ = await wait { !model.busy }
            record("Batch MP3 extraction", model.items.allSatisfy { $0.output?.pathExtension == "mp3" && $0.status == "Complete" }, model.message)

            model.selectAll(false)
            if let id = model.items.first(where: { $0.url == video })?.id { model.update(id) { $0.selected = true } }
            model.settings = ExportSettings(); model.settings.trimStart = 4; model.settings.trimEnd = 1
            model.export()
            _ = await wait { !model.busy }
            record("Invalid trim rejected", model.items.first(where: { $0.url == video })?.status == "Failed", model.items.first(where: { $0.url == video })?.error ?? "No error")

            let duplicate = fixtures.appendingPathComponent("Second clip.mp4")
            if !fm.fileExists(atPath: duplicate.path) { try fm.copyItem(at: video, to: duplicate) }
            model.add([duplicate]); _ = await wait { !model.importing }
            model.selectAll(false)
            for item in model.items where item.info.hasVideo { model.update(item.id) { $0.selected = true } }
            model.settings = ExportSettings(); model.settings.resolution = 480; model.settings.merge = true
            model.export()
            _ = await wait { !model.busy }
            let merged = model.items.filter { $0.selected }.first?.output
            if let merged {
                let info = try MediaEngine.probe(url: merged, ffprobe: engine.appendingPathComponent("ffprobe"))
                record("Queue merge", model.items.filter { $0.selected }.allSatisfy { $0.status == "Merged" && $0.output == merged } && info.duration > 7.5, "\(info.duration)s, \(info.width)×\(info.height)")
            } else { record("Queue merge", false, model.alert ?? model.message) }
            model.selectAll(false)
            if let id = model.items.first(where: { $0.url == video })?.id { model.update(id) { $0.selected = true } }
            model.settings = ExportSettings(); model.settings.resolution = 480
            model.export(); model.cancel()
            _ = await wait { !model.busy }
            record("Queue cancellation", model.items.first(where: { $0.url == video })?.status == "Cancelled" && model.items.first(where: { $0.url == video })?.output == nil, model.message)

            let activeRunner = ProcessRunner()
            let cancelFile = fixtures.appendingPathComponent("runner-cancel.mp4")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { activeRunner.cancel() }
            do {
                try activeRunner.run(executable: engine.appendingPathComponent("ffmpeg"), arguments: ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-re", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-t", "20", "-c:v", "mpeg4", "-f", "mp4", cancelFile.path], duration: 20) { _ in }
                record("Active process cancellation", false, "The real-time process was not interrupted")
            } catch ConversionError.cancelled { record("Active process cancellation", true, "A running media process terminated and reported cancellation") }
            catch { record("Active process cancellation", false, error.localizedDescription) }
            try? fm.removeItem(at: cancelFile)
            record("Original input preserved", try Data(contentsOf: video) == original, "Input bytes unchanged after every export")
            let partials = try fm.contentsOfDirectory(atPath: destination.path).filter { $0.contains(".partial.") }
            record("Partial output cleanup", partials.isEmpty, "\(partials.count) partial files remaining")
        } catch { record("Harness", false, error.localizedDescription) }
        do { try JSONEncoder().encode(results).write(to: resultsURL) } catch { print(error); exit(2) }
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
}
