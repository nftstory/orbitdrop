import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import OrbitCore

/// The converter window: file list, preview, target and tool pickers, job
/// status, Cancel and Reveal. It works fully without the drag gesture.
struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                fileList
                Divider()
                PreviewPane(row: model.selectedRow)
                    .frame(width: 260)
            }
            Divider()
            controls
                .padding(12)
        }
        .frame(minWidth: 760, minHeight: 460)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            model.accept(providers)
            return true
        }
        .sheet(item: $model.pendingTool) { tool in
            // Framing and single-image cropping get interactive editors;
            // everything else uses the generated parameter form.
            if tool.id == "image-frame" {
                FrameEditorSheet(tool: tool, model: model)
            } else if tool.id == "image-crop", model.rows.count == 1 {
                CropEditorSheet(tool: tool, model: model)
            } else {
                ToolOptionsSheet(tool: tool, model: model)
            }
        }
    }

    @ViewBuilder
    private var fileList: some View {
        if model.rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(.teal)
                Text("Drop files here")
                    .font(.title3)
                Text("or use Add Files. Outputs are saved beside each source; nothing is overwritten.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add Files…") { model.chooseFiles() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.rows, selection: $model.selection) { row in
                FileRowView(row: row)
            }
        }
    }

    private var outputLabel: String {
        model.outputDirectory.map { $0.path } ?? "Beside each source file"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Convert to", selection: $model.selectedTargetID) {
                    if model.targets.isEmpty {
                        Text(model.rows.isEmpty ? "Add files first" : "No common format").tag("")
                    }
                    ForEach(model.targets) { format in
                        Text(format.title).tag(format.id)
                    }
                }
                .frame(maxWidth: 300)
                Button("Convert") { model.convert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRunning || model.selectedTargetID.isEmpty)

                Spacer(minLength: 16)

                Picker("Tool", selection: $model.selectedToolID) {
                    if model.tools.isEmpty {
                        Text(model.rows.isEmpty ? "Add files first" : "No common tool").tag("")
                    }
                    ForEach(model.tools) { tool in
                        Text(tool.title).tag(tool.id)
                    }
                }
                .frame(maxWidth: 300)
                Button("Run Tool…") { model.requestSelectedTool() }
                    .disabled(model.isRunning || model.selectedToolID.isEmpty)
            }

            HStack(spacing: 8) {
                Text("Save to:")
                    .foregroundColor(.secondary)
                Text(outputLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { model.chooseOutputDirectory() }
                if model.outputDirectory != nil {
                    Button("Beside Source") { model.outputDirectory = nil }
                }
                Spacer()
                Button("Add Files…") { model.chooseFiles() }
                    .disabled(model.isRunning)
                Button("Remove") { model.removeSelected() }
                    .disabled(model.isRunning || model.selection == nil)
                Button("Clear") { model.clear() }
                    .disabled(model.isRunning || model.rows.isEmpty)
                Button("Reveal") { model.revealOutputs() }
                    .disabled(!model.hasOutputs)
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.isRunning)
            }

            HStack(spacing: 8) {
                if model.unsupportedCount > 0 {
                    Text("\(model.unsupportedCount) file(s) have no conversion and will be reported as failed.")
                        .foregroundColor(.orange)
                }
                Text(model.engineSummary)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Locate ffmpeg…") { model.chooseFFmpeg() }
                    .disabled(model.isRunning)
            }
            .font(.caption)
        }
    }
}

struct FileRowView: View {
    let row: AppModel.FileRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.kind.symbolName)
                .foregroundColor(.teal)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.statusText)
                    .font(.caption)
                    .foregroundColor(row.isFailure ? .red : .secondary)
                    .lineLimit(3)
            }
            Spacer()
            indicator
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var indicator: some View {
        switch row.status {
        case .running(let fraction):
            if let fraction {
                ProgressView(value: fraction)
                    .frame(width: 90)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.teal)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        default:
            EmptyView()
        }
    }
}

/// Image or player preview of the selected file, where the system can show one.
struct PreviewPane: View {
    let row: AppModel.FileRow?

    private static let playable: Set<String> = ["mov", "mp4", "m4v", "m4a", "mp3", "wav", "aiff", "aif", "caf"]

    var body: some View {
        VStack(spacing: 8) {
            if let row {
                preview(for: row)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(row.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(row.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Spacer()
                Text("No file selected")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func preview(for row: AppModel.FileRow) -> some View {
        let ext = row.url.pathExtension.lowercased()
        if row.kind == .image, let preview = ImageEngine.preview(row.url) {
            Image(decorative: preview.image, scale: 1)
                .resizable()
                .scaledToFit()
        } else if (row.kind == .video || row.kind == .audio), PreviewPane.playable.contains(ext) {
            PlayerView(url: row.url)
        } else {
            VStack(spacing: 6) {
                Image(systemName: row.kind.symbolName)
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.secondary)
                Text(row.kind.displayName)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }
}
