import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

// The command-line SDK exposes a newer State macro without its plugin.
// This alias selects the stable property wrapper used by macOS 14 and later.
typealias ViewState<Value> = State<Value>

struct QueueItem: Identifiable {
    let id = UUID()
    let url: URL
    var selected = true
    var info = MediaInfo()
    var status = "Reading media…"
    var progress: Double = 0
    var output: URL?
    var outputSize: Int64 = 0
    var error: String?
    var ready = false
}

func fileSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func mediaTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "—" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value/3600, value/60%60, value%60)
        : String(format: "%d:%02d", value/60, value%60)
}

@MainActor final class QueueModel: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var settings = ExportSettings()
    @Published var destination: URL
    @Published var busy = false
    @Published var importing = false
    @Published var batchProgress: Double = 0
    @Published var message = ""
    @Published var alert: String?
    @Published var previewURL: URL?
    @Published var activeTab = "Video"
    private var runner: ProcessRunner?
    let ffmpeg: URL
    let ffprobe: URL

    init(engineDirectory: URL? = nil) {
        let resources = engineDirectory ?? Bundle.main.resourceURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        ffmpeg = resources.appendingPathComponent("ffmpeg")
        ffprobe = resources.appendingPathComponent("ffprobe")
        let saved = UserDefaults.standard.string(forKey: "exportDirectory")
        destination = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    var selectedCount: Int { items.filter { $0.selected && $0.ready }.count }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.info.size } }
    var audioOnly: Bool { ["m4a", "mp3", "wav", "flac", "aiff", "ogg"].contains(settings.format) }
    var engineAvailable: Bool { FileManager.default.isExecutableFile(atPath: ffmpeg.path) && FileManager.default.isExecutableFile(atPath: ffprobe.path) }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose video or audio files to convert."
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.directoryURL = destination
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            UserDefaults.standard.set(url.path, forKey: "exportDirectory")
        }
    }

    func chooseWatermark() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        if panel.runModal() == .OK { settings.watermark = panel.url }
    }

    func add(_ urls: [URL]) {
        guard !busy else { return }
        guard engineAvailable else { alert = "The media engine is missing. Rebuild the app with Build.command."; return }
        let existing = Set(items.map { $0.url.standardizedFileURL.path })
        let fresh = Array(Set(urls.filter { $0.isFileURL }.map { $0.standardizedFileURL })).filter { !existing.contains($0.path) }.sorted { $0.path < $1.path }
        let jobs = fresh.map { QueueItem(url: $0) }
        items.append(contentsOf: jobs)
        guard !jobs.isEmpty else { return }
        importing = true
        let probe = ffprobe
        DispatchQueue.global(qos: .userInitiated).async {
            for item in jobs {
                let result = Result { try MediaEngine.probe(url: item.url, ffprobe: probe) }
                DispatchQueue.main.async {
                    guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                    switch result {
                    case .success(let info):
                        self.items[index].info = info
                        self.items[index].ready = info.hasAudio || info.hasVideo
                        self.items[index].status = self.items[index].ready ? "Ready" : "Unsupported media"
                    case .failure(let error):
                        self.items[index].selected = false
                        self.items[index].status = "Could not read"
                        self.items[index].error = error.localizedDescription
                    }
                }
            }
            DispatchQueue.main.async { self.importing = false }
        }
    }

    func update(_ id: UUID, _ action: @escaping (inout QueueItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) { action(&items[index]) }
    }

    func selectAll(_ selected: Bool) { for index in items.indices { items[index].selected = selected && items[index].ready } }
    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func cancel() { message = "Cancelling…"; runner?.cancel() }

    func export() {
        let jobs = items.filter { $0.selected && $0.ready }
        guard !busy, !jobs.isEmpty else { return }
        guard engineAvailable else { alert = "The media engine is missing."; return }
        if !audioOnly && jobs.contains(where: { !$0.info.hasVideo }) { alert = "Choose an audio format for audio-only files."; return }
        if audioOnly && jobs.contains(where: { !$0.info.hasAudio }) { alert = "A selected file has no audio track. Choose a video format or deselect it."; return }
        if settings.merge && jobs.count < 2 { alert = "Select at least two files to merge."; return }
        var options = settings
        if options.merge {
            if !audioOnly && options.resolution == 0 && options.customWidth == 0 {
                let dimensions = Set(jobs.map { "\($0.info.width)x\($0.info.height)" })
                if dimensions.count != 1 { alert = "For files with different sizes, choose a common resolution before merging."; return }
            }
            // Normalization gives the concat stage identical audio and frame timing.
            options.sampleRate = options.sampleRate == 0 ? 48000 : options.sampleRate
            options.channels = options.channels == 0 ? 2 : options.channels
            options.fps = options.fps == 0 ? 30 : options.fps
            if !audioOnly && Set(jobs.map { $0.info.hasAudio }).count > 1 {
                alert = "Merged videos must all have audio or all be silent."; return
            }
            options.exactResolution = true
        }
        let settings = options, folder = destination, ffmpeg = ffmpeg, ffprobe = ffprobe
        let currentRunner = ProcessRunner()
        runner = currentRunner; busy = true; batchProgress = 0; message = "Starting export…"
        for job in jobs { update(job.id) { $0.status = "Queued"; $0.progress = 0; $0.error = nil; $0.output = nil; $0.outputSize = 0 } }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let tempDirectory = fm.temporaryDirectory.appendingPathComponent("CompressREA-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: tempDirectory) }
            var successes = 0, failures = 0, normalized: [URL] = []
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if settings.merge { try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true) }
                for (index, job) in jobs.enumerated() {
                    try currentRunner.checkCancellation()
                    let final = settings.merge
                        ? tempDirectory.appendingPathComponent("clip-\(index).\(settings.format)")
                        : MediaEngine.uniqueOutput(input: job.url, directory: folder, format: settings.format)
                    let partial = final.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.\(settings.format)")
                    do {
                        DispatchQueue.main.async {
                            self.update(job.id) { $0.status = settings.merge ? "Preparing merge" : "Converting" }
                            self.message = "\(index + 1) of \(jobs.count) · \(job.url.lastPathComponent)"
                        }
                        let arguments = try MediaEngine.command(input: job.url, info: job.info, output: partial, settings: settings, ffmpeg: ffmpeg)
                        let end = settings.trimEnd > 0 ? min(settings.trimEnd, job.info.duration) : job.info.duration
                        let duration = max(0, end - settings.trimStart)
                        try currentRunner.run(executable: ffmpeg, arguments: arguments, duration: duration) { fraction in
                            DispatchQueue.main.async {
                                self.update(job.id) { $0.progress = fraction }
                                let stages = Double(jobs.count + (settings.merge ? 1 : 0))
                                self.batchProgress = (Double(index) + fraction) / stages
                            }
                        }
                        try currentRunner.checkCancellation()
                        let outputInfo = try MediaEngine.probe(url: partial, ffprobe: ffprobe)
                        guard outputInfo.size > 0, outputInfo.hasVideo || outputInfo.hasAudio else { throw ConversionError.message("The converted file could not be validated.") }
                        try fm.moveItem(at: partial, to: final)
                        if settings.merge { normalized.append(final) }
                        else {
                            successes += 1
                            DispatchQueue.main.async { self.update(job.id) { $0.status = "Complete"; $0.progress = 1; $0.output = final; $0.outputSize = outputInfo.size } }
                        }
                    } catch {
                        try? fm.removeItem(at: partial)
                        if case ConversionError.cancelled = error { throw error }
                        failures += 1
                        DispatchQueue.main.async { self.update(job.id) { $0.status = "Failed"; $0.error = error.localizedDescription; $0.progress = 0 } }
                        if settings.merge { throw error }
                    }
                }
                if settings.merge {
                    let final = MediaEngine.uniqueOutput(input: URL(fileURLWithPath: "Merged"), directory: folder, format: settings.format)
                    let partial = folder.appendingPathComponent(".\(UUID().uuidString).partial.\(settings.format)")
                    do {
                        let arguments = try MediaEngine.mergeCommand(inputs: normalized, output: partial, listFile: tempDirectory.appendingPathComponent("concat.txt"), ffmpeg: ffmpeg)
                        DispatchQueue.main.async { self.message = "Joining converted files…" }
                        try currentRunner.run(executable: ffmpeg, arguments: arguments, duration: jobs.reduce(0) { $0 + $1.info.duration }) { fraction in
                            DispatchQueue.main.async { self.batchProgress = (Double(jobs.count) + fraction) / Double(jobs.count + 1) }
                        }
                        try currentRunner.checkCancellation()
                        let outputInfo = try MediaEngine.probe(url: partial, ffprobe: ffprobe)
                        guard outputInfo.size > 0 else { throw ConversionError.message("The merged output is empty.") }
                        try fm.moveItem(at: partial, to: final)
                        successes = jobs.count
                        DispatchQueue.main.async { for job in jobs { self.update(job.id) { $0.status = "Merged"; $0.output = final; $0.outputSize = outputInfo.size; $0.progress = 1 } } }
                    } catch { try? fm.removeItem(at: partial); throw error }
                }
                DispatchQueue.main.async { self.message = "Finished · \(successes) converted\(failures > 0 ? ", \(failures) failed" : "")"; self.batchProgress = 1 }
            } catch {
                let cancelled: Bool
                if case ConversionError.cancelled = error { cancelled = true } else { cancelled = false }
                DispatchQueue.main.async {
                    self.message = cancelled ? "Export cancelled. Finished files were kept." : "Export stopped."
                    if !cancelled { self.alert = error.localizedDescription }
                    for job in jobs { self.update(job.id) { if $0.output == nil && $0.status != "Failed" { $0.status = cancelled ? "Cancelled" : "Stopped"; $0.progress = 0 } } }
                }
            }
            DispatchQueue.main.async { self.busy = false; self.runner = nil }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: QueueModel
    @ViewState private var dropActive = false
    private let accent = Color(red: 0.34, green: 0.31, blue: 0.88)
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compress REA").font(.system(size: 24, weight: .semibold))
                        Text("\(model.items.count) \(model.items.count == 1 ? "file" : "files") · \(fileSize(model.totalSize))").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: model.chooseFiles) { Label("Add Files", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).keyboardShortcut("o").disabled(model.busy)
                }.padding(24)
                Divider()
                HStack(spacing: 16) {
                    Button("Select All") { model.selectAll(true) }
                    Button("Select None") { model.selectAll(false) }
                    Spacer()
                    Button("Clear List") { model.items.removeAll() }.disabled(model.items.isEmpty)
                }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 24).padding(.vertical, 12).disabled(model.busy || model.importing)
                if model.items.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "arrow.down.document").font(.system(size: 48, weight: .light)).foregroundStyle(accent)
                        Text("Drop video or audio files here").font(.title3.weight(.medium))
                        Text("Or choose Add Files to build your queue.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) { ForEach(model.items) { item in queueRow(item); Divider().padding(.leading, 60) } }
                    }
                }
                Divider()
                HStack {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text(model.message.isEmpty ? "Files are saved to your chosen folder." : model.message).lineLimit(1)
                    Spacer()
                    Text("\(model.selectedCount) selected").foregroundStyle(.secondary)
                }.font(.caption).padding(16)
            }.frame(minWidth: 510, maxWidth: .infinity)
            Divider()
            inspector.frame(width: 335).background(Color(nsColor: .controlBackgroundColor))
        }
        .tint(accent).frame(minWidth: 870, minHeight: 670)
        .overlay { if dropActive { RoundedRectangle(cornerRadius: 10).stroke(accent, lineWidth: 3).padding(5).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in
            guard !model.busy else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { model.add([url]) } } }
            }
            return true
        }
        .alert("Export", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .sheet(item: Binding(get: { model.previewURL.map { PreviewItem(url: $0) } }, set: { model.previewURL = $0?.url })) { preview in
            PreviewView(url: preview.url)
        }
    }

    func queueRow(_ item: QueueItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Toggle("Select \(item.url.lastPathComponent)", isOn: Binding(get: { model.items.first(where: { $0.id == item.id })?.selected ?? false }, set: { value in model.update(item.id) { $0.selected = value } })).labelsHidden().disabled(model.busy || !item.ready)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(item.url.lastPathComponent).font(.system(size: 14, weight: .medium)).lineLimit(1).help(item.url.path)
                    Spacer()
                    Button { model.previewURL = item.output ?? item.url } label: { Image(systemName: "play.circle") }.help("Preview media").disabled(!item.ready)
                    if let output = item.output { Button { model.reveal(output) } label: { Image(systemName: "folder") }.help("Show exported file") }
                    Button { model.remove(item.id) } label: { Image(systemName: "xmark") }.help("Remove from queue").disabled(model.busy)
                }.buttonStyle(.borderless)
                HStack(spacing: 9) {
                    Text(fileSize(item.info.size))
                    Text(mediaTime(item.info.duration))
                    if item.info.hasVideo { Text("\(item.info.width) × \(item.info.height)") } else if item.info.hasAudio { Text("Audio") }
                }.font(.caption).foregroundStyle(.secondary)
                if item.status == "Converting" || item.status == "Preparing merge" { ProgressView(value: item.progress).animation(.easeOut(duration: 0.15), value: item.progress) }
                HStack {
                    Text(item.status).foregroundStyle(item.error == nil ? .secondary : Color.red)
                    if item.outputSize > 0 {
                        Text("→ \(fileSize(item.outputSize))").foregroundStyle(.secondary)
                        if !model.settings.merge && item.info.size > 0 {
                            let saved = 100 * (1 - Double(item.outputSize) / Double(item.info.size))
                            Text(saved >= 0 ? "\(Int(saved))% smaller" : "\(Int(-saved))% larger").foregroundStyle(saved >= 0 ? Color.green : .secondary)
                        }
                    }
                    if let error = item.error { Button("Details") { model.alert = error } }
                }.font(.caption)
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Export to").font(.headline)
                Button(action: model.chooseDestination) {
                    HStack { Image(systemName: "folder"); Text(model.destination.lastPathComponent).lineLimit(1); Spacer(); Image(systemName: "chevron.down").font(.caption) }.frame(maxWidth: .infinity)
                }.help(model.destination.path).disabled(model.busy)
                Picker("Format", selection: $model.settings.format) {
                    ForEach(["mp4", "mov", "mkv", "avi", "m4a", "mp3", "wav", "flac", "aiff", "ogg"], id: \.self) { Text($0.uppercased()).tag($0) }
                }.disabled(model.busy)
                Picker("Settings", selection: $model.activeTab) { Text("Video").tag("Video"); Text("Audio").tag("Audio"); Text("Tools").tag("Tools") }.pickerStyle(.segmented)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if model.activeTab == "Video" { videoOptions }
                    else if model.activeTab == "Audio" { audioOptions }
                    else { toolOptions }
                }.padding(22).disabled(model.busy)
            }
            Divider()
            VStack(spacing: 12) {
                if model.busy { ProgressView(value: model.batchProgress); Button("Cancel Export", action: model.cancel).frame(maxWidth: .infinity) }
                else { Button(action: model.export) { Text(model.settings.merge ? "Merge Selected Files" : "Export Selected Files").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.borderedProminent).disabled(model.selectedCount == 0 || model.importing) }
                Text("Original files are kept.").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
    }

    var videoOptions: some View {
        Group {
            if model.audioOnly { Text("Choose a video format to use these settings.").font(.subheadline).foregroundStyle(.secondary) }
            Picker("Encoder", selection: $model.settings.videoCodec) {
                Text("H.264").tag(VideoCodec.h264); Text("H.265 / HEVC").tag(VideoCodec.hevc); Text("MPEG-4").tag(VideoCodec.mpeg4)
            }
            Picker("Resolution", selection: $model.settings.resolution) {
                Text("Original").tag(0); Text("480p").tag(480); Text("720p").tag(720); Text("1080p").tag(1080); Text("4K / 2160p").tag(2160); Text("Custom").tag(-1)
            }
            if model.settings.resolution == -1 {
                HStack { numberField("Width", $model.settings.customWidth); Text("×"); numberField("Height", $model.settings.customHeight) }
            }
            Toggle("Pad to exact resolution", isOn: $model.settings.exactResolution).font(.caption)
            Picker("Video bitrate", selection: $model.settings.videoBitrateKbps) {
                Text("Automatic").tag(0)
                ForEach([500, 1000, 2000, 4000, 8000, 12000, 20000], id: \.self) { Text($0 < 1000 ? "\($0) kb/s" : "\($0/1000) Mb/s").tag($0) }
            }
            Picker("Frame rate", selection: $model.settings.fps) {
                Text("Original").tag(0); ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            Text("Smaller dimensions and a lower bitrate usually produce smaller files.").font(.caption).foregroundStyle(.secondary)
        }.disabled(model.audioOnly)
    }

    var audioOptions: some View {
        Group {
            if model.settings.format == "ogg" {
                Picker("OGG quality", selection: $model.settings.audioBitrateKbps) {
                    Text("Smallest").tag(64); Text("Low").tag(96); Text("Standard").tag(128); Text("Balanced").tag(160); Text("High").tag(192); Text("Higher").tag(256); Text("Highest").tag(320)
                }
                Text("OGG uses variable bitrate and stereo audio.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Audio bitrate", selection: $model.settings.audioBitrateKbps) { ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kb/s").tag($0) } }
            }
            Picker("Sample rate", selection: $model.settings.sampleRate) { Text("Original").tag(0); ForEach([22050, 44100, 48000], id: \.self) { Text("\($0) Hz").tag($0) } }
            Picker("Channels", selection: $model.settings.channels) { Text("Original").tag(0); Text("Mono").tag(1); Text("Stereo").tag(2) }
            VStack(alignment: .leading) { Text("Volume · \(Int(model.settings.volume * 100))%"); Slider(value: $model.settings.volume, in: 0...2, step: 0.05) }.font(.caption)
            Text("WAV, AIFF and FLAC use lossless encoding. Bitrate settings apply to compressed audio formats.").font(.caption).foregroundStyle(.secondary)
        }
    }

    var toolOptions: some View {
        Group {
            Toggle("Merge selected files", isOn: $model.settings.merge)
            Text("Files join in queue order. For different video sizes, choose a common resolution.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Trim playback").font(.headline)
            HStack { decimalField("From (s)", $model.settings.trimStart); decimalField("To (s)", $model.settings.trimEnd) }
            Text("Set To to 0 to keep the rest of the file.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Rotate", selection: $model.settings.rotate) { Text("None").tag(0); Text("90° clockwise").tag(90); Text("180°").tag(180); Text("270° clockwise").tag(270) }.disabled(model.audioOnly)
            Picker("Flip", selection: $model.settings.flip) { Text("None").tag("none"); Text("Horizontal").tag("horizontal"); Text("Vertical").tag("vertical") }.disabled(model.audioOnly)
            Text("Crop edges (pixels)").font(.headline)
            HStack { numberField("Left", $model.settings.cropLeft); numberField("Right", $model.settings.cropRight) }.disabled(model.audioOnly)
            HStack { numberField("Top", $model.settings.cropTop); numberField("Bottom", $model.settings.cropBottom) }.disabled(model.audioOnly)
            Divider()
            HStack { Text("Watermark").font(.headline); Spacer(); if model.settings.watermark != nil { Button("Clear") { model.settings.watermark = nil } } }
            Button(model.settings.watermark?.lastPathComponent ?? "Choose Watermark Image…", action: model.chooseWatermark).lineLimit(1).disabled(model.audioOnly)
            if model.settings.watermark != nil {
                Picker("Position", selection: $model.settings.watermarkPosition) {
                    Text("Top left").tag("top-left"); Text("Top right").tag("top-right"); Text("Bottom left").tag("bottom-left"); Text("Bottom right").tag("bottom-right"); Text("Center").tag("center")
                }.disabled(model.audioOnly)
                Text("Uses the image at its original size.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func numberField(_ title: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder) }
    }
    func decimalField(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder) }
    }
}

struct PreviewItem: Identifiable { let url: URL; var id: String { url.path } }
struct PreviewView: View {
    let url: URL
    @Environment(\.dismiss) var dismiss
    @ViewState private var player: AVPlayer? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(url.lastPathComponent).lineLimit(1); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            VideoPlayer(player: player).frame(width: 720, height: 420)
        }.onAppear { player = AVPlayer(url: url); player?.play() }.onDisappear { player?.pause() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: QueueModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "An export is running."
        alert.informativeText = "Quit cancels the current export. Completed files are kept."
        alert.addButton(withTitle: "Keep Exporting"); alert.addButton(withTitle: "Cancel and Quit")
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        model.cancel(); return .terminateNow
    }
}

#if !HEADLESS_TEST
@main struct CompressREAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = QueueModel()
    var body: some Scene {
        WindowGroup("Compress REA") {
            ContentView().environmentObject(model)
                .onAppear { delegate.model = model }
                .onOpenURL { url in model.add([url]) }
        }.defaultSize(width: 1020, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Add Files…", action: model.chooseFiles).keyboardShortcut("o").disabled(model.busy) }
            CommandMenu("Export") {
                Button("Export Selected Files", action: model.export).keyboardShortcut("e").disabled(model.busy || model.selectedCount == 0)
                Button("Choose Output Folder…", action: model.chooseDestination).disabled(model.busy)
                Button("Show Output Folder") { NSWorkspace.shared.open(model.destination) }
            }
        }
    }
}
#endif
