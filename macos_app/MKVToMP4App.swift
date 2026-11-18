import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum QueueItemStatus: Equatable {
    case pending
    case inspecting
    case ready
    case converting
    case finalizing
    case converted
    case skipped
    case failed

    var label: String {
        switch self {
        case .pending: return "Queued"
        case .inspecting: return "Inspecting…"
        case .ready: return "Ready"
        case .converting: return "Converting"
        case .finalizing: return "Finalizing…"
        case .converted: return "Converted"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .pending, .inspecting: return .secondary
        case .ready: return .blue
        case .converting, .finalizing: return .accentColor
        case .converted: return .green
        case .skipped: return .orange
        case .failed: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .pending, .inspecting: return "clock"
        case .ready: return "film"
        case .converting, .finalizing: return "arrow.triangle.2.circlepath.circle.fill"
        case .converted: return "checkmark.circle.fill"
        case .skipped: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

struct QueueItem: Identifiable {
    let id = UUID()
    let inputURL: URL
    var sizeBytes: Int64
    var durationSec: Double = 0
    var videoSummary: String = ""
    var audioSummary: String = ""
    var warnings: [String] = []
    var status: QueueItemStatus = .pending
    var progressPercent: Double = 0
    var speed: String = ""
    var detailMessage: String = ""
    var outputURL: URL?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum OutputContainer: String, CaseIterable, Identifiable {
    case mp4
    case mov

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mp4: return "MP4 (Universal FCP / DaVinci • AAC Audio)"
        case .mov: return "MOV (Lossless Video + 24-bit PCM Audio)"
        }
    }
}

enum AudioLangPreset: String, CaseIterable, Identifiable {
    case all
    case eng
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Tracks"
        case .eng: return "English (eng)"
        case .custom: return "Custom…"
        }
    }
}

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var container: OutputContainer = .mp4 {
        didSet {
            UserDefaults.standard.set(container.rawValue, forKey: "container")
            if !isConverting { inspectAllReadyItems() }
        }
    }
    @Published var useCustomOutputDir: Bool = false {
        didSet { UserDefaults.standard.set(useCustomOutputDir, forKey: "useCustomOutputDir") }
    }
    @Published var customOutputDir: String = "" {
        didSet { UserDefaults.standard.set(customOutputDir, forKey: "customOutputDir") }
    }
    @Published var audioPreset: AudioLangPreset = .all {
        didSet { UserDefaults.standard.set(audioPreset.rawValue, forKey: "audioPreset") }
    }
    @Published var customAudioLangs: String = "eng" {
        didSet { UserDefaults.standard.set(customAudioLangs, forKey: "customAudioLangs") }
    }
    @Published var firstAudioOnly: Bool = false {
        didSet { UserDefaults.standard.set(firstAudioOnly, forKey: "firstAudioOnly") }
    }
    @Published var stereoDownmix: Bool = false {
        didSet { UserDefaults.standard.set(stereoDownmix, forKey: "stereoDownmix") }
    }
    @Published var extractSubs: Bool = false {
        didSet { UserDefaults.standard.set(extractSubs, forKey: "extractSubs") }
    }
    @Published var overwriteExisting: Bool = false {
        didSet { UserDefaults.standard.set(overwriteExisting, forKey: "overwriteExisting") }
    }
    @Published var allowTranscode: Bool = false {
        didSet { UserDefaults.standard.set(allowTranscode, forKey: "allowTranscode") }
    }
    @Published var isDropTargeted: Bool = false
    @Published var includeSubfolders: Bool = true
    @Published var isConverting: Bool = false
    @Published var isInstallingFFmpeg: Bool = false
    @Published var ffmpegAvailable: Bool = false
    @Published var ffmpegStatusText: String = "Checking FFmpeg…"
    @Published var bannerError: String?
    @Published var batchSummary: String?

    private var activeProcess: Process?
    private var inspectProcess: Process?
    private let workerQueue = DispatchQueue(label: "mkv.to.mp4.worker", qos: .userInitiated)

    init() {
        loadPreferences()
        refreshFFmpegStatus()
    }

    var supportBinDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Video Converter", isDirectory: true).appendingPathComponent("bin", isDirectory: true)
    }

    var scriptPath: URL? {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("mkv_to_mp4.py")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        let appParent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("mkv_to_mp4.py")
        if FileManager.default.fileExists(atPath: appParent.path) {
            return appParent
        }
        return nil
    }

    var setupScriptPath: URL? {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("setup_ffmpeg.sh")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        let appParent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("setup_ffmpeg.sh")
        if FileManager.default.fileExists(atPath: appParent.path) {
            return appParent
        }
        return nil
    }

    var hasConvertedOutputs: Bool {
        items.contains { $0.status == .converted && $0.outputURL != nil }
    }

    var canStartConversion: Bool {
        ffmpegAvailable && !isConverting && !isInstallingFFmpeg && !items.isEmpty
    }

    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        let total = items.reduce(0.0) { partial, item in
            switch item.status {
            case .converted, .skipped: return partial + 100.0
            case .converting, .finalizing: return partial + item.progressPercent
            default: return partial
            }
        }
        return total / Double(items.count)
    }

    private func loadPreferences() {
        let d = UserDefaults.standard
        if let rawContainer = d.string(forKey: "container"), let parsed = OutputContainer(rawValue: rawContainer) {
            container = parsed
        }
        useCustomOutputDir = d.bool(forKey: "useCustomOutputDir")
        customOutputDir = d.string(forKey: "customOutputDir") ?? ""
        if let rawAudio = d.string(forKey: "audioPreset"), let parsedAudio = AudioLangPreset(rawValue: rawAudio) {
            audioPreset = parsedAudio
        }
        customAudioLangs = d.string(forKey: "customAudioLangs") ?? "eng"
        firstAudioOnly = d.bool(forKey: "firstAudioOnly")
        stereoDownmix = d.bool(forKey: "stereoDownmix")
        extractSubs = d.bool(forKey: "extractSubs")
        overwriteExisting = d.bool(forKey: "overwriteExisting")
        allowTranscode = d.bool(forKey: "allowTranscode")
    }

    func refreshFFmpegStatus() {
        var candidateDirs: [String] = []
        if let resBin = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            candidateDirs.append(resBin)
        }
        candidateDirs.append(contentsOf: [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("bin").path,
            supportBinDir.path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        ])

        for dir in candidateDirs {
            let ff = (dir as NSString).appendingPathComponent("ffmpeg")
            let fp = (dir as NSString).appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: ff) && FileManager.default.isExecutableFile(atPath: fp) {
                ffmpegAvailable = true
                ffmpegStatusText = "FFmpeg ready (\(dir))"
                return
            }
        }
        ffmpegAvailable = false
        ffmpegStatusText = "FFmpeg not installed yet"
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.message = "Select where converted MP4/MOV files should be saved."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !customOutputDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customOutputDir)
        }
        if panel.runModal() == .OK, let url = panel.url {
            customOutputDir = url.path
            useCustomOutputDir = true
        }
    }

    func pickInputFilesAndFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add MKV Files or Folders"
        panel.message = "Choose .mkv files or folders containing MKV files."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let mkvType = UTType(filenameExtension: "mkv") {
            panel.allowedContentTypes = [mkvType, .folder]
        }
        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }

    func addURLs(_ urls: [URL]) {
        bannerError = nil
        batchSummary = nil
        var existingPaths = Set(items.map { $0.inputURL.standardizedFileURL.path })
        var addedIndices: [Int] = []

        for url in urls {
            let discovered = collectMKVs(at: url, recursive: includeSubfolders)
            for mkv in discovered {
                let norm = mkv.standardizedFileURL.path
                if existingPaths.contains(norm) { continue }
                existingPaths.insert(norm)
                let attrs = try? FileManager.default.attributesOfItem(atPath: norm)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                items.append(QueueItem(inputURL: mkv, sizeBytes: size))
                addedIndices.append(items.count - 1)
            }
        }

        if addedIndices.isEmpty && !urls.isEmpty {
            bannerError = "No new .mkv files were found in what you dropped."
            return
        }

        if ffmpegAvailable && !isConverting {
            inspectItems(at: addedIndices)
        }
    }

    private func collectMKVs(at url: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }

        if !isDir.boolValue {
            let name = url.lastPathComponent
            if url.pathExtension.lowercased() == "mkv" && !name.hasPrefix("._") {
                return [url]
            }
            return []
        }

        var results: [URL] = []
        if recursive {
            if let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let child as URL in enumerator {
                    let name = child.lastPathComponent
                    if child.pathExtension.lowercased() == "mkv" && !name.hasPrefix("._") {
                        results.append(child)
                    }
                }
            }
        } else if let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                let name = child.lastPathComponent
                if child.pathExtension.lowercased() == "mkv" && !name.hasPrefix("._") {
                    results.append(child)
                }
            }
        }
        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func removeItem(_ item: QueueItem) {
        guard !isConverting else { return }
        items.removeAll { $0.id == item.id }
    }

    func clearQueue() {
        guard !isConverting else { return }
        items.removeAll()
        batchSummary = nil
        bannerError = nil
    }

    func installFFmpeg() {
        guard !isInstallingFFmpeg else { return }
        guard let setupScript = setupScriptPath else {
            bannerError = "setup_ffmpeg.sh not found in app bundle."
            return
        }

        isInstallingFFmpeg = true
        bannerError = nil
        ffmpegStatusText = "Downloading native Apple Silicon FFmpeg…"

        let targetDir = supportBinDir.path
        workerQueue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = [setupScript.path, targetDir]

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var allLines: [String] = []
            var lineBuffer = Data()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                lineBuffer.append(chunk)
                while let nlRange = lineBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = lineBuffer.subdata(in: 0..<nlRange.lowerBound)
                    lineBuffer.removeSubrange(0...nlRange.lowerBound)
                    if let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !line.isEmpty {
                        allLines.append(line)
                        DispatchQueue.main.async {
                            self.ffmpegStatusText = line
                        }
                    }
                }
            }

            do {
                try proc.run()
                proc.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                if !lineBuffer.isEmpty,
                   let trailing = String(data: lineBuffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !trailing.isEmpty {
                    allLines.append(trailing)
                }

                DispatchQueue.main.async {
                    self.isInstallingFFmpeg = false
                    self.refreshFFmpegStatus()
                    if proc.terminationStatus != 0 || !self.ffmpegAvailable {
                        let detail = allLines.suffix(3).joined(separator: " ")
                        self.bannerError = "FFmpeg install failed: \(detail)"
                    } else if !self.items.isEmpty {
                        self.inspectAllReadyItems()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isInstallingFFmpeg = false
                    self.bannerError = "Could not run installer: \(error.localizedDescription)"
                }
            }
        }
    }

    private func buildCLIArguments(for fileURLs: [URL], inspectOnly: Bool) -> [String]? {
        guard let script = scriptPath else { return nil }
        var args = [script.path, "--progress-json"]
        if inspectOnly {
            args.append("--inspect")
        }
        args.append(contentsOf: ["--container", container.rawValue])
        if useCustomOutputDir && !customOutputDir.isEmpty {
            args.append(contentsOf: ["-o", customOutputDir])
        }
        switch audioPreset {
        case .all:
            break
        case .eng:
            args.append(contentsOf: ["--audio-langs", "eng"])
        case .custom:
            let trimmed = customAudioLangs.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                args.append(contentsOf: ["--audio-langs", trimmed])
            }
        }
        if firstAudioOnly { args.append("--first-audio") }
        if stereoDownmix { args.append("--stereo") }
        if extractSubs { args.append("--extract-subs") }
        if overwriteExisting { args.append("--overwrite") }
        if allowTranscode { args.append("--allow-transcode") }
        args.append(contentsOf: fileURLs.map { $0.path })
        return args
    }

    func inspectAllReadyItems() {
        let indices = items.indices.filter { items[$0].status != .converted }
        inspectItems(at: Array(indices))
    }

    private func inspectItems(at indices: [Int]) {
        guard ffmpegAvailable, !indices.isEmpty else { return }
        let urls = indices.compactMap { idx -> URL? in
            guard items.indices.contains(idx) else { return nil }
            items[idx].status = .inspecting
            return items[idx].inputURL
        }
        guard let args = buildCLIArguments(for: urls, inspectOnly: true) else { return }

        inspectProcess?.terminate()
        let supportBin = supportBinDir.path
        let resBin = Bundle.main.resourceURL?.appendingPathComponent("bin").path

        workerQueue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            if let resBin, FileManager.default.fileExists(atPath: resBin) {
                env["MKV_TO_MP4_BIN_DIR"] = resBin
            } else if FileManager.default.fileExists(atPath: supportBin) {
                env["MKV_TO_MP4_BIN_DIR"] = supportBin
            }
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            DispatchQueue.main.async { self.inspectProcess = proc }

            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                guard let text = String(data: data, encoding: .utf8) else { return }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                DispatchQueue.main.async {
                    for line in lines {
                        self.applyJSONLine(String(line))
                    }
                }
            } catch {
                // Non-fatal; user can still click Convert.
            }
        }
    }

    func startConversion() {
        guard canStartConversion else { return }
        if useCustomOutputDir && customOutputDir.isEmpty {
            chooseDestinationFolder()
            if customOutputDir.isEmpty { return }
        }

        let targetURLs = items.filter { $0.status != .converted }.map { $0.inputURL }
        guard !targetURLs.isEmpty, let args = buildCLIArguments(for: targetURLs, inspectOnly: false) else {
            return
        }

        isConverting = true
        bannerError = nil
        batchSummary = nil
        for idx in items.indices where items[idx].status != .converted {
            items[idx].status = .pending
            items[idx].progressPercent = 0
            items[idx].speed = ""
            items[idx].detailMessage = ""
        }

        let supportBin = supportBinDir.path
        let resBin = Bundle.main.resourceURL?.appendingPathComponent("bin").path

        workerQueue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            if let resBin, FileManager.default.fileExists(atPath: resBin) {
                env["MKV_TO_MP4_BIN_DIR"] = resBin
            } else if FileManager.default.fileExists(atPath: supportBin) {
                env["MKV_TO_MP4_BIN_DIR"] = supportBin
            }
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            DispatchQueue.main.async { self.activeProcess = proc }

            var lineBuffer = Data()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                lineBuffer.append(chunk)
                while let nlRange = lineBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = lineBuffer.subdata(in: 0..<nlRange.lowerBound)
                    lineBuffer.removeSubrange(0...nlRange.lowerBound)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        DispatchQueue.main.async {
                            self.applyJSONLine(line)
                        }
                    }
                }
            }

            do {
                try proc.run()
                proc.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                if !lineBuffer.isEmpty, let trailing = String(data: lineBuffer, encoding: .utf8), !trailing.isEmpty {
                    DispatchQueue.main.async { self.applyJSONLine(trailing) }
                }

                DispatchQueue.main.async {
                    self.activeProcess = nil
                    self.isConverting = false
                    if proc.terminationStatus != 0 && proc.terminationStatus != 130 && self.bannerError == nil && self.batchSummary == nil {
                        self.bannerError = "Conversion finished with warnings or errors (exit \(proc.terminationStatus))."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.activeProcess = nil
                    self.isConverting = false
                    self.bannerError = "Failed to launch converter: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelConversion() {
        activeProcess?.terminate()
    }

    func revealConvertedInFinder() {
        let urls = items.compactMap { $0.status == .converted ? $0.outputURL : nil }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func applyJSONLine(_ rawLine: String) {
        guard let data = rawLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }

        if event == "error" {
            bannerError = json["message"] as? String ?? "Unknown error"
            return
        }

        if event == "batch_done" {
            let conv = json["converted"] as? Int ?? 0
            let skip = json["skipped"] as? Int ?? 0
            let fail = json["failed"] as? Int ?? 0
            batchSummary = "Finished: \(conv) converted, \(skip) skipped, \(fail) failed."
            return
        }

        let fileName = json["file"] as? String ?? ""
        let inputPath = json["input_path"] as? String
        guard let idx = findItemIndex(inputPath: inputPath, fileName: fileName) else { return }

        switch event {
        case "inspect", "file_start":
            items[idx].durationSec = json["duration_sec"] as? Double ?? items[idx].durationSec
            items[idx].videoSummary = json["video_action"] as? String ?? ""
            let audios = json["audio_actions"] as? [String] ?? []
            items[idx].audioSummary = audios.joined(separator: " • ")
            items[idx].warnings = json["warnings"] as? [String] ?? []
            if let outStr = json["output_path"] as? String {
                items[idx].outputURL = URL(fileURLWithPath: outStr)
            }
            if event == "inspect" {
                let canProceed = json["can_proceed"] as? Bool ?? true
                items[idx].status = canProceed ? .ready : .skipped
                items[idx].detailMessage = json["skip_reason"] as? String ?? ""
            } else {
                items[idx].status = .converting
                items[idx].progressPercent = 0
                items[idx].detailMessage = ""
            }

        case "progress":
            let phase = json["phase"] as? String ?? "converting"
            items[idx].status = (phase == "finalizing") ? .finalizing : .converting
            items[idx].progressPercent = json["percent"] as? Double ?? items[idx].progressPercent
            items[idx].speed = json["speed"] as? String ?? ""

        case "file_done":
            let st = json["status"] as? String ?? "failed"
            switch st {
            case "converted":
                items[idx].status = .converted
                items[idx].progressPercent = 100
            case "skipped":
                items[idx].status = .skipped
            default:
                items[idx].status = .failed
            }
            if let outStr = json["output_path"] as? String {
                items[idx].outputURL = URL(fileURLWithPath: outStr)
            }
            items[idx].detailMessage = json["message"] as? String ?? ""

        case "cancelled":
            items[idx].status = .ready
            items[idx].progressPercent = 0
            items[idx].detailMessage = "Cancelled"
            batchSummary = "Cancelled cleanly — partial temp files removed."

        default:
            break
        }
    }

    private func findItemIndex(inputPath: String?, fileName: String) -> Int? {
        if let inputPath {
            let norm = URL(fileURLWithPath: inputPath).standardizedFileURL.path
            if let idx = items.firstIndex(where: { $0.inputURL.standardizedFileURL.path == norm }) {
                return idx
            }
        }
        return items.firstIndex { $0.inputURL.lastPathComponent == fileName }
    }
}

struct ContentView: View {
    @ObservedObject var vm: ConverterViewModel

    var body: some View {
        VStack(spacing: 14) {
            headerBar
            if !vm.ffmpegAvailable {
                ffmpegMissingBanner
            }
            dropZone
            optionsPanel
            queueSection
            footerBar
        }
        .padding(18)
        .frame(minWidth: 740, minHeight: 620)
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Video Converter")
                    .font(.title2.bold())
                Text("Lossless video remux for Final Cut Pro & DaVinci Resolve (10–20 GB Blu-ray & film ready)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.ffmpegAvailable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(vm.ffmpegAvailable ? "FFmpeg Ready" : "Setup Needed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private var ffmpegMissingBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("FFmpeg & FFprobe are needed for conversion")
                    .font(.headline)
                Text(vm.isInstallingFFmpeg ? vm.ffmpegStatusText : "One-click install downloads official notarized Apple Silicon binaries into Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if vm.isInstallingFFmpeg {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button("Install FFmpeg Now") {
                    vm.installFFmpeg()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: vm.isDropTargeted ? "arrow.down.doc.fill" : "film.stack")
                .font(.system(size: 32))
                .foregroundStyle(vm.isDropTargeted ? Color.accentColor : Color.secondary)
            Text("Drop MKV files or folders here")
                .font(.headline)
            Text("Or drag files straight onto the app icon • Video is copied bit-for-bit with zero quality loss")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Add MKVs / Folder…") {
                    vm.pickInputFilesAndFolders()
                }
                .disabled(vm.isConverting)
                Toggle("Include subfolders", isOn: $vm.includeSubfolders)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(vm.isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    vm.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("Format:")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 85, alignment: .leading)
                Picker("", selection: $vm.container) {
                    ForEach(OutputContainer.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .disabled(vm.isConverting)
            }

            HStack(spacing: 14) {
                Text("Save To:")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 85, alignment: .leading)
                Picker("", selection: $vm.useCustomOutputDir) {
                    Text("Same folder as original").tag(false)
                    Text("Selected folder").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .disabled(vm.isConverting)

                if vm.useCustomOutputDir {
                    Text(vm.customOutputDir.isEmpty ? "No folder chosen" : vm.customOutputDir)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(vm.customOutputDir.isEmpty ? .orange : .secondary)
                    Spacer()
                    Button("Choose…") {
                        vm.chooseDestinationFolder()
                    }
                    .disabled(vm.isConverting)
                } else {
                    Spacer()
                }
            }

            HStack(spacing: 14) {
                Text("Audio:")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 85, alignment: .leading)
                Picker("", selection: $vm.audioPreset) {
                    ForEach(AudioLangPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(vm.isConverting)

                if vm.audioPreset == .custom {
                    TextField("e.g. eng,jpn", text: $vm.customAudioLangs)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .disabled(vm.isConverting)
                }

                Toggle("First track only", isOn: $vm.firstAudioOnly)
                    .toggleStyle(.checkbox)
                    .disabled(vm.isConverting)
                Toggle("Stereo 2.0 downmix", isOn: $vm.stereoDownmix)
                    .toggleStyle(.checkbox)
                    .disabled(vm.isConverting)
                Spacer()
            }

            HStack(spacing: 18) {
                Spacer().frame(width: 85)
                Toggle("Extract subtitles (.srt/.ass/.sup)", isOn: $vm.extractSubs)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(vm.isConverting)
                Toggle("Overwrite existing", isOn: $vm.overwriteExisting)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(vm.isConverting)
                Toggle("Allow transcode if VC-1/MPEG-2", isOn: $vm.allowTranscode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(vm.isConverting)
                Spacer()
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Queue (\(vm.items.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !vm.items.isEmpty && !vm.isConverting {
                    Button("Clear All") {
                        vm.clearQueue()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if vm.items.isEmpty {
                HStack {
                    Spacer()
                    Text("No files queued yet. Drop an MKV or folder above to inspect streams and convert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                List {
                    ForEach(vm.items) { item in
                        QueueRowView(item: item, canRemove: !vm.isConverting) {
                            vm.removeItem(item)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footerBar: some View {
        VStack(spacing: 8) {
            if let error = vm.bannerError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                }
            } else if let summary = vm.batchSummary {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(summary).font(.caption.weight(.medium))
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                if vm.isConverting {
                    ProgressView(value: vm.overallProgress, total: 100)
                        .frame(maxWidth: 260)
                    Text(String(format: "%.0f%%", vm.overallProgress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if vm.hasConvertedOutputs {
                    Button("Reveal in Finder") {
                        vm.revealConvertedInFinder()
                    }
                }

                if vm.isConverting {
                    Button("Cancel", role: .destructive) {
                        vm.cancelConversion()
                    }
                } else {
                    Button("Convert \(vm.items.filter { $0.status != .converted }.count) File(s)") {
                        vm.startConversion()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canStartConversion)
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        let group = DispatchGroup()
        var droppedURLs: [URL] = []
        let lock = NSLock()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var resolved: URL?
                if let data = item as? Data {
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolved = url
                } else if let nsurl = item as? NSURL {
                    resolved = nsurl as URL
                }
                if let resolved {
                    lock.lock()
                    droppedURLs.append(resolved)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if !droppedURLs.isEmpty {
                vm.addURLs(droppedURLs)
            }
        }
        return accepted
    }
}

struct QueueRowView: View {
    let item: QueueItem
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: item.status.systemImage)
                    .foregroundStyle(item.status.color)
                Text(item.inputURL.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(item.status.color)
                if canRemove {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !item.videoSummary.isEmpty || !item.audioSummary.isEmpty {
                Text([item.videoSummary, item.audioSummary].filter { !$0.isEmpty }.joined(separator: "  |  "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if item.status == .converting || item.status == .finalizing {
                ProgressView(value: item.progressPercent, total: 100)
                    .progressViewStyle(.linear)
            }

            if !item.detailMessage.isEmpty {
                Text(item.detailMessage)
                    .font(.caption2)
                    .foregroundStyle(item.status == .failed ? .red : .secondary)
                    .lineLimit(2)
            } else if let warning = item.warnings.first {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var statusText: String {
        switch item.status {
        case .converting:
            let speedSuffix = item.speed.isEmpty ? "" : " (\(item.speed))"
            return String(format: "%.0f%%%@", item.progressPercent, speedSuffix)
        case .finalizing:
            return "Finalizing MP4…"
        default:
            return item.status.label
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var viewModel = ConverterViewModel()
    private var window: NSWindow?

    private func ensureWindow() {
        if window == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Video Converter"
            newWindow.center()
            newWindow.contentView = NSHostingView(rootView: ContentView(vm: viewModel))
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ensureWindow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ensureWindow()
        viewModel.addURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

