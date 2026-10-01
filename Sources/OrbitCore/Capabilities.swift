import Foundation
import ImageIO

/// An externally installed ffmpeg and what it can encode. OrbitDrop never
/// bundles, downloads or installs ffmpeg.
public struct MediaToolchain: Sendable, Equatable {
    public let ffmpeg: URL
    public let ffprobe: URL?
    public let encoders: Set<String>
    public let muxers: Set<String>

    public init(ffmpeg: URL, ffprobe: URL?, encoders: Set<String>, muxers: Set<String>) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.encoders = encoders
        self.muxers = muxers
    }
}

public enum FFmpegLocator {
    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    public static let environmentKey = "ORBITDROP_FFMPEG"

    static func isUsableExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Finds ffmpeg at the configured absolute path (argument, then the
    /// `ORBITDROP_FFMPEG` environment variable), then in the standard
    /// Homebrew locations. `"none"` disables ffmpeg entirely.
    public static func locate(configuredPath: String? = nil) -> MediaToolchain? {
        let configured = configuredPath ?? ProcessInfo.processInfo.environment[environmentKey]
        if let configured, ["none", "off"].contains(configured.lowercased()) { return nil }

        var candidates: [String] = []
        if let configured, !configured.isEmpty { candidates.append(configured) }
        candidates += searchDirectories.map { $0 + "/ffmpeg" }
        guard let path = candidates.first(where: isUsableExecutable) else { return nil }

        let ffmpeg = URL(fileURLWithPath: path)
        let probeCandidates = [ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe").path]
            + searchDirectories.map { $0 + "/ffprobe" }
        let ffprobe = probeCandidates.first(where: isUsableExecutable).map { URL(fileURLWithPath: $0) }

        guard let encoderList = try? ProcessRunner.run(ffmpeg, ["-nostdin", "-hide_banner", "-encoders"]),
              encoderList.status == 0,
              let muxerList = try? ProcessRunner.run(ffmpeg, ["-nostdin", "-hide_banner", "-muxers"]),
              muxerList.status == 0 else {
            return nil
        }
        return MediaToolchain(
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            encoders: parseEncoders(encoderList.stdoutText),
            muxers: parseMuxers(muxerList.stdoutText))
    }

    /// Parses `ffmpeg -encoders`: lines look like ` V....D libx264   H.264 ...`.
    static func parseEncoders(_ text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0].count == 6, let type = fields[0].first, "VAS".contains(type),
                  fields[1] != "=" else { continue }
            names.insert(String(fields[1]))
        }
        return names
    }

    /// Parses `ffmpeg -muxers`: lines look like `  E mp4   MP4 (MPEG-4 Part 14)`.
    static func parseMuxers(_ text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0].count <= 3, fields[0].contains("E"), fields[1] != "=" else { continue }
            for name in fields[1].split(separator: ",") { names.insert(String(name)) }
        }
        return names
    }
}

/// What this machine can do right now. Formats and tools are only offered
/// when the capability behind them is present.
public struct Capabilities: Sendable {
    public let imageTypeIdentifiers: Set<String>
    public let media: MediaToolchain?
    public let supportsSubjectMask: Bool

    public init(imageTypeIdentifiers: Set<String>, media: MediaToolchain?, supportsSubjectMask: Bool) {
        self.imageTypeIdentifiers = imageTypeIdentifiers
        self.media = media
        self.supportsSubjectMask = supportsSubjectMask
    }

    private static func nativeImageTypes() -> Set<String> {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }

    private static var subjectMaskAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Native frameworks plus an installed ffmpeg, if one is found.
    public static func detect(ffmpegPath: String? = nil) -> Capabilities {
        Capabilities(
            imageTypeIdentifiers: nativeImageTypes(),
            media: FFmpegLocator.locate(configuredPath: ffmpegPath),
            supportsSubjectMask: subjectMaskAvailable)
    }

    /// Native frameworks only; ffmpeg is ignored even when installed.
    public static func native() -> Capabilities {
        Capabilities(imageTypeIdentifiers: nativeImageTypes(), media: nil, supportsSubjectMask: subjectMaskAvailable)
    }

    public func canWrite(_ spec: ImageFormatSpec) -> Bool {
        imageTypeIdentifiers.contains(spec.uti)
    }
}
