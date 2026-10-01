import Foundation

/// Coarse classification of an input file, derived from its extension and
/// confirmed by the engine that actually opens it.
public enum FileKind: String, CaseIterable, Codable, Sendable {
    case image, video, audio, pdf, document, subtitle, archive, unknown

    static let extensions: [FileKind: Set<String>] = [
        .image: ["png", "jpg", "jpeg", "jpe", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "jp2",
                 "jpf", "j2k", "ico", "icns", "psd", "tga", "exr", "avif", "dng", "cr2", "nef", "arw",
                 "raf", "orf", "rw2"],
        .video: ["mov", "mp4", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "wmv", "flv", "mts", "m2ts",
                 "3gp", "ogv"],
        .audio: ["mp3", "m4a", "wav", "aiff", "aif", "aifc", "caf", "flac", "ogg", "oga", "opus", "aac",
                 "wma", "ac3", "amr"],
        .pdf: ["pdf"],
        .document: ["txt", "text", "md", "markdown", "rtf", "doc", "docx", "odt"],
        .subtitle: ["srt", "vtt"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar"],
    ]

    public static func of(extension ext: String) -> FileKind {
        let lower = ext.lowercased()
        for (kind, set) in extensions where set.contains(lower) { return kind }
        return .unknown
    }

    public static func detect(_ url: URL) -> FileKind {
        of(extension: url.pathExtension)
    }

    public var displayName: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .subtitle: return "Subtitles"
        case .archive: return "Archive"
        case .unknown: return "Other"
        }
    }

    /// SF Symbol used by the GUI.
    public var symbolName: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .unknown: return "doc"
        }
    }
}

/// Cheap header checks performed before a file is handed to an engine.
enum ContentSniffer {
    /// Text-based stream descriptions that could make ffmpeg open other
    /// files or network resources. They are never accepted as media input.
    static let blockedMediaPrefixes = ["#extm3u", "ffconcat", "[playlist]", "v=0", "<?xml", "<smil", "<mpd", "<asx"]

    static func head(_ url: URL, count: Int = 2048) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw OrbitError.invalidInput("Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func verify(_ url: URL, kind: FileKind) throws {
        switch kind {
        case .pdf:
            let data = try head(url)
            guard data.range(of: Data("%PDF-".utf8)) != nil else {
                throw OrbitError.malformed("\(url.lastPathComponent) is not a valid PDF.")
            }
        case .video, .audio:
            let data = try head(url)
            guard !data.isEmpty else {
                throw OrbitError.malformed("\(url.lastPathComponent) is empty.")
            }
            let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
            let text = String(decoding: data.prefix(512), as: UTF8.self)
                .trimmingCharacters(in: trimSet)
                .lowercased()
            for prefix in blockedMediaPrefixes where text.hasPrefix(prefix) {
                throw OrbitError.invalidInput(
                    "\(url.lastPathComponent) is a playlist or stream description, not a media file. Such inputs are not accepted.")
            }
        default:
            break
        }
    }
}
