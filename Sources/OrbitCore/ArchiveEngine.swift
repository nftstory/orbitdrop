import Foundation

/// Archive creation and listing with the system `ditto`, `tar` and `gzip`,
/// always through argument arrays. Extraction is deliberately not offered:
/// OrbitDrop lists archive contents but never unpacks them.
public enum ArchiveEngine {
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")

    /// Copies the sources into a private payload folder under plain,
    /// de-duplicated basenames, so the archivers only ever see one
    /// directory argument and archive entries are simple relative names.
    static func preparePayload(_ sources: [SourceFile], staging: StagingArea, token: CancellationToken?) throws -> URL {
        let payload = try staging.subdirectory(named: "payload")
        var used = Set<String>()
        for source in sources {
            try token?.check()
            let ext = source.url.pathExtension
            let base = source.url.deletingPathExtension().lastPathComponent
            var name = source.url.lastPathComponent
            var counter = 2
            while used.contains(name.lowercased()) {
                name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
                counter += 1
            }
            used.insert(name.lowercased())
            do {
                try FileManager.default.copyItem(at: source.url, to: payload.appendingPathComponent(name))
            } catch {
                throw OrbitError.engineFailure("Could not stage \(source.name): \(error.localizedDescription)")
            }
        }
        return payload
    }

    private static func require(_ result: ProcessResult, _ tool: String) throws {
        guard result.status == 0 else {
            throw OrbitError.engineFailure("\(tool) failed: \(result.stderrTail)")
        }
    }

    static func createZip(payload: URL, output: URL, token: CancellationToken?) throws {
        let result = try ProcessRunner.run(ditto, ["-c", "-k", "--norsrc", payload.path, output.path], token: token)
        try require(result, "ditto")
    }

    static func createTar(payload: URL, output: URL, compressed: Bool, token: CancellationToken?) throws {
        let result = try ProcessRunner.run(
            tar, [compressed ? "-czf" : "-cf", output.path, "-C", payload.path, "."],
            environment: ["COPYFILE_DISABLE": "1"], token: token)
        try require(result, "tar")
    }

    static func gzipFile(_ source: URL, output: URL, token: CancellationToken?) throws {
        let result = try ProcessRunner.run(gzip, ["-c", source.path], stdoutFile: output, token: token)
        try require(result, "gzip")
    }

    /// Entry names of an archive. This reads the archive's table of contents
    /// only; nothing is extracted.
    public static func list(_ url: URL, token: CancellationToken? = nil) throws -> [String] {
        let result = try ProcessRunner.run(tar, ["-tf", url.path], token: token)
        if result.status == 0 {
            return result.stdoutText.split(separator: "\n").map(String.init)
        }
        if url.pathExtension.lowercased() == "gz" {
            // A plain gzip stream holds a single unnamed file.
            let check = try ProcessRunner.run(gzip, ["-t", url.path], token: token)
            if check.status == 0 {
                return [url.deletingPathExtension().lastPathComponent]
            }
        }
        throw OrbitError.malformed(
            "\(url.lastPathComponent) could not be read as an archive: \(result.stderrTail)")
    }
}
