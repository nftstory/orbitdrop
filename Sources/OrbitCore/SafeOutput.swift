import Foundation

/// Size, modification date and inode of a source file, used to detect that a
/// source changed while a job was running.
struct SourceFingerprint: Equatable, Sendable {
    let size: UInt64
    let modified: Date?
    let inode: UInt64

    static func capture(_ url: URL) throws -> SourceFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return SourceFingerprint(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}

/// A hidden, uniquely named directory next to the final outputs. Engines
/// write only inside it; finished files are moved out with an exclusive,
/// never-overwriting commit. Only this directory is ever deleted.
public final class StagingArea {
    public let outputDirectory: URL
    public let directory: URL
    private var counter = 0

    static let prefix = ".orbitdrop-staging-"

    public init(outputDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw OrbitError.outputNotWritable("Output folder does not exist: \(outputDirectory.path)")
        }
        let staging = outputDirectory.appendingPathComponent(StagingArea.prefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw OrbitError.outputNotWritable(
                "Cannot write to folder \"\(outputDirectory.path)\": \(error.localizedDescription) "
                + "Choose a different output folder or adjust the folder's permissions.")
        }
        self.outputDirectory = outputDirectory
        self.directory = staging
    }

    /// A fresh path inside the staging directory with the correct extension
    /// (native writers pick the container from it).
    public func newFile(ext: String) -> URL {
        counter += 1
        let name = ext.isEmpty ? "staged-\(counter)" : "staged-\(counter).\(ext)"
        return directory.appendingPathComponent(name)
    }

    public func subdirectory(named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private enum MoveResult {
        case done
        case exists
        case failed(Int32)
    }

    /// Moves `source` to `destination` only if nothing exists there.
    private static func exclusiveMove(_ source: String, _ destination: String) -> MoveResult {
        // A hard link fails atomically with EEXIST when the name is taken.
        if link(source, destination) == 0 {
            unlink(source)
            return .done
        }
        if errno == EEXIST { return .exists }
        // Volumes without hard links: exclusive rename.
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return .done }
        if errno == EEXIST { return .exists }
        // No exclusive primitive works on this volume. A plain rename could
        // replace a file that appears in between, so the commit fails instead.
        return .failed(errno)
    }

    /// Commits a staged file as `stem.ext`, or `stem-2.ext`, `stem-3.ext`, ...
    /// when the name is taken. Existing files are never replaced. Only files
    /// inside this staging directory can be committed.
    public func commit(_ staged: URL, stem: String, ext: String) throws -> URL {
        let ownPrefix = directory.standardizedFileURL.path + "/"
        guard staged.standardizedFileURL.path.hasPrefix(ownPrefix) else {
            throw OrbitError.outputNotWritable("Refusing to commit a file outside the job's staging folder.")
        }
        guard ext.count <= 16, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw OrbitError.outputNotWritable("Refusing to save a file with the extension \"\(ext)\".")
        }
        var safeStem = stem
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        if safeStem.isEmpty || safeStem == "." || safeStem == ".." { safeStem = "output" }
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        for attempt in 1...9999 {
            let name = attempt == 1 ? safeStem + suffix : "\(safeStem)-\(attempt)\(suffix)"
            let destination = outputDirectory.appendingPathComponent(name)
            switch StagingArea.exclusiveMove(staged.path, destination.path) {
            case .done:
                return destination
            case .exists:
                continue
            case .failed(let code):
                throw OrbitError.outputNotWritable(
                    "Could not save \(name) in \"\(outputDirectory.path)\": \(String(cString: strerror(code)))")
            }
        }
        throw OrbitError.outputNotWritable("Too many files named \(safeStem)\(suffix) already exist.")
    }

    /// Removes the staging directory. It is always this job's own directory.
    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}
