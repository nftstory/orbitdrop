import Foundation
import ImageIO
import PDFKit

/// A validated, immutable description of one input file. Sources are only
/// ever read; outputs are named from `stem`, never from user-supplied paths.
public struct SourceFile: Sendable {
    public let url: URL
    public let kind: FileKind
    public let stem: String
    let fingerprint: SourceFingerprint

    public var ext: String { url.pathExtension.lowercased() }
    public var name: String { url.lastPathComponent }

    public init(_ input: URL) throws {
        guard input.isFileURL else {
            throw OrbitError.invalidInput("Only local files are accepted.")
        }
        let resolved = input.resolvingSymlinksInPath().standardizedFileURL
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        } catch {
            throw OrbitError.invalidInput("File not found: \(input.lastPathComponent)")
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw OrbitError.invalidInput(
                "\(input.lastPathComponent) is not a regular file. Folders and file promises are not supported.")
        }
        guard FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw OrbitError.invalidInput("No permission to read \(input.lastPathComponent).")
        }

        var stem = resolved.deletingPathExtension().lastPathComponent
        if stem.isEmpty || stem == "." || stem == ".." { stem = "output" }
        while stem.utf8.count > 180 { stem.removeLast() }

        self.url = resolved
        self.kind = FileKind.detect(resolved)
        self.stem = stem
        self.fingerprint = try SourceFingerprint.capture(resolved)
    }
}

enum OutputCheck: Sendable {
    case image, pdf, media, nonEmpty
}

/// A finished file inside the staging directory and the name it should get.
struct StagedOutput {
    let url: URL
    let stem: String
    let ext: String
    let check: OutputCheck
}

struct StagedResult {
    var outputs: [StagedOutput]
    var notes: [String] = []

    static func single(_ url: URL, stem: String, ext: String, check: OutputCheck, notes: [String] = []) -> StagedResult {
        StagedResult(outputs: [StagedOutput(url: url, stem: stem, ext: ext, check: check)], notes: notes)
    }
}

public struct JobResult: Sendable {
    public let outputs: [URL]
    /// Honest remarks about what happened, e.g. an encoder fallback.
    public let notes: [String]
}

/// Reopens staged outputs before they are committed.
struct OutputValidator: Sendable {
    let toolchain: MediaToolchain?

    func validate(_ url: URL, check: OutputCheck) throws {
        let name = url.lastPathComponent
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw OrbitError.validationFailed("The converter produced an empty file (\(name)).")
        }
        switch check {
        case .nonEmpty:
            break
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw OrbitError.validationFailed("The written image could not be reopened (\(name)).")
            }
        case .pdf:
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw OrbitError.validationFailed("The written PDF could not be reopened (\(name)).")
            }
        case .media:
            // ffprobe when present, otherwise ffmpeg's own stream report,
            // otherwise AVFoundation: the output is always actually reopened.
            let readable: Bool
            if let toolchain {
                readable = (try? FFmpegEngine(toolchain: toolchain).inspect(url)) != nil
            } else {
                readable = NativeMedia.canOpen(url)
            }
            guard readable else {
                throw OrbitError.validationFailed("The written media file could not be reopened (\(name)).")
            }
        }
    }
}

/// Inode of a path without following symlinks, or nil when nothing is there.
private func inode(of url: URL) -> UInt64? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return UInt64(info.st_ino)
}

enum JobRunner {
    /// Runs one job with the safety contract shared by every operation:
    /// stage beside the output, validate, confirm the sources did not change,
    /// honour late cancellation, then commit without overwriting. Cancellation
    /// is checked for the last time immediately before the commit; the commit
    /// itself (a few link calls) is not interruptible. On any failure the
    /// job's own staging directory and its own already-committed outputs are
    /// removed, so a job is all-or-nothing. A committed path is removed only
    /// while it still is the file this job put there.
    static func perform(
        sources: [SourceFile],
        outputDirectory: URL?,
        token: CancellationToken?,
        validator: OutputValidator,
        body: (StagingArea) throws -> StagedResult
    ) throws -> JobResult {
        guard let first = sources.first else {
            throw OrbitError.invalidInput("No input files.")
        }
        try token?.check()
        let directory = outputDirectory ?? first.url.deletingLastPathComponent()
        let staging = try StagingArea(outputDirectory: directory)
        var committed: [URL] = []
        var committedInodes: [UInt64?] = []
        do {
            let staged = try body(staging)
            guard !staged.outputs.isEmpty else {
                throw OrbitError.engineFailure("The operation produced no output.")
            }
            for output in staged.outputs {
                try validator.validate(output.url, check: output.check)
            }
            for source in sources {
                guard let current = try? SourceFingerprint.capture(source.url), current == source.fingerprint else {
                    throw OrbitError.sourceChanged(
                        "\(source.name) changed while it was being processed. Nothing was saved; run the job again.")
                }
            }
            try token?.check()
            for output in staged.outputs {
                let destination = try staging.commit(output.url, stem: output.stem, ext: output.ext)
                committed.append(destination)
                committedInodes.append(inode(of: destination))
            }
            staging.discard()
            return JobResult(outputs: committed, notes: staged.notes)
        } catch {
            for (url, original) in zip(committed, committedInodes) {
                // Someone may have replaced the file since; then it is not ours to delete.
                if let original, inode(of: url) == original { _ = unlink(url.path) }
            }
            staging.discard()
            throw error
        }
    }
}
