import AppKit
import Combine
import OrbitCore

/// State behind the main window. All mutation happens on the main thread;
/// jobs run on a background queue and report back through `apply`.
final class AppModel: ObservableObject {
    enum RowStatus: Equatable {
        case ready
        case queued
        case running(Double?)
        case done
        case skipped(String)
        case failed(String)
        case cancelled
    }

    struct FileRow: Identifiable {
        let id = UUID()
        let url: URL
        let kind: FileKind
        var status: RowStatus = .ready
        var outputs: [URL] = []
        var notes: [String] = []

        var statusText: String {
            switch status {
            case .ready: return kind.displayName
            case .queued: return "Waiting"
            case .running(let fraction):
                return fraction.map { "Working… \(Int($0 * 100))%" } ?? "Working…"
            case .done:
                let names = outputs.map { $0.lastPathComponent }
                let summary = names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) files"
                return (["Saved \(summary)"] + notes).joined(separator: " — ")
            case .skipped(let reason): return "Skipped: \(reason)"
            case .failed(let reason): return reason
            case .cancelled: return "Cancelled"
            }
        }

        var isFailure: Bool {
            if case .failed = status { return true }
            return false
        }
    }

    static let ffmpegPathKey = "ffmpegPath"

    @Published var rows: [FileRow] = []
    @Published var selection: UUID?
    @Published var targets: [OutputFormat] = []
    @Published var tools: [ToolDescriptor] = []
    @Published var unsupportedCount = 0
    @Published var selectedTargetID = ""
    @Published var selectedToolID = ""
    @Published var isRunning = false
    @Published var outputDirectory: URL?
    @Published var pendingTool: ToolDescriptor?
    @Published var engineSummary = "Checking for ffmpeg…"

    private(set) var engine = OrbitEngine(capabilities: .native())
    private var token: CancellationToken?

    init() {
        detectCapabilities()
    }

    // MARK: Engine

    /// Looks for ffmpeg off the main thread, then swaps in the full engine.
    func detectCapabilities() {
        let configured = UserDefaults.standard.string(forKey: AppModel.ffmpegPathKey)
        DispatchQueue.global(qos: .utility).async {
            let capabilities = Capabilities.detect(ffmpegPath: configured)
            DispatchQueue.main.async {
                self.install(OrbitEngine(capabilities: capabilities))
            }
        }
    }

    private func install(_ newEngine: OrbitEngine) {
        guard !isRunning else {
            // Never swap engines under a running batch; try again afterwards.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.install(newEngine) }
            return
        }
        engine = newEngine
        if let media = newEngine.capabilities.media {
            let hardware = media.encoders.contains("h264_videotoolbox") ? "hardware H.264" : "software encoders only"
            let probe = media.ffprobe == nil ? ", no ffprobe" : ""
            engineSummary = "ffmpeg: \(media.ffmpeg.path) (\(hardware)\(probe))"
        } else {
            engineSummary = "ffmpeg not found — images, PDFs, documents, subtitles and archives work natively; media is limited to MOV/MP4 and common audio."
        }
        refreshChoices()
    }

    func setFFmpegPath(_ path: String?) {
        if let path {
            UserDefaults.standard.set(path, forKey: AppModel.ffmpegPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppModel.ffmpegPathKey)
        }
        engineSummary = "Checking for ffmpeg…"
        detectCapabilities()
    }

    // MARK: Files

    var selectedRow: FileRow? {
        rows.first { $0.id == selection } ?? rows.first
    }

    var hasOutputs: Bool {
        rows.contains { !$0.outputs.isEmpty }
    }

    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        let known = Set(rows.map { $0.url.standardizedFileURL })
        for url in urls where url.isFileURL && !known.contains(url.standardizedFileURL) {
            rows.append(FileRow(url: url, kind: FileKind.detect(url)))
        }
        refreshChoices()
    }

    func setFiles(_ urls: [URL]) {
        guard !isRunning else { return }
        rows = []
        selection = nil
        add(urls)
    }

    func clear() {
        guard !isRunning else { return }
        rows = []
        selection = nil
        refreshChoices()
    }

    func removeSelected() {
        guard !isRunning, let selection else { return }
        rows.removeAll { $0.id == selection }
        self.selection = nil
        refreshChoices()
    }

    func accept(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self.add([url]) }
            }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }

    func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an ffmpeg executable. OrbitDrop never installs or downloads one."
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { setFFmpegPath(url.path) }
    }

    func refreshChoices() {
        let urls = rows.map { $0.url }
        let batch = engine.commonTargets(for: urls)
        targets = batch.formats
        unsupportedCount = batch.unsupported.count
        tools = engine.commonTools(for: urls)
        if !targets.contains(where: { $0.id == selectedTargetID }) { selectedTargetID = targets.first?.id ?? "" }
        if !tools.contains(where: { $0.id == selectedToolID }) { selectedToolID = tools.first?.id ?? "" }
    }

    // MARK: Jobs

    func convert() {
        guard !selectedTargetID.isEmpty else { return }
        start(.convert(formatID: selectedTargetID, options: .none))
    }

    /// Runs the selected tool, asking for parameters first when it has any.
    func requestSelectedTool() {
        guard let tool = tools.first(where: { $0.id == selectedToolID }) else { return }
        if tool.parameters.isEmpty {
            runTool(tool, values: [:])
        } else {
            pendingTool = tool
        }
    }

    func runTool(_ tool: ToolDescriptor, values: [String: Any]) {
        start(.tool(id: tool.id, options: ToolOptions(values)))
    }

    private func start(_ action: BatchAction) {
        guard !isRunning, !rows.isEmpty else { return }
        let urls = rows.map { $0.url }
        let ids = rows.map { $0.id }
        for index in rows.indices {
            rows[index].status = .queued
            rows[index].outputs = []
            rows[index].notes = []
        }
        let token = CancellationToken()
        self.token = token
        isRunning = true
        let engine = self.engine
        let directory = outputDirectory

        DispatchQueue.global(qos: .userInitiated).async {
            engine.runBatch(sources: urls, action: action, outputDirectory: directory, token: token) { indices, status in
                DispatchQueue.main.async { self.apply(status, to: indices.map { ids[$0] }) }
            }
            DispatchQueue.main.async { self.finish() }
        }
    }

    private func apply(_ status: JobStatus, to ids: [UUID]) {
        for index in rows.indices where ids.contains(rows[index].id) {
            switch status {
            case .running(let fraction):
                rows[index].status = .running(fraction.map { min(max($0, 0), 1) })
            case .succeeded(let result):
                rows[index].status = .done
                rows[index].outputs = result.outputs
                rows[index].notes = result.notes
            case .skipped(let reason):
                rows[index].status = .skipped(reason)
            case .failed(let reason):
                rows[index].status = .failed(reason)
            case .cancelled:
                rows[index].status = .cancelled
            }
        }
    }

    private func finish() {
        isRunning = false
        token = nil
    }

    func cancel() {
        token?.cancel()
    }

    func revealOutputs() {
        var seen = Set<URL>()
        let outputs = rows.flatMap { $0.outputs }.filter { seen.insert($0).inserted }
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }
}
