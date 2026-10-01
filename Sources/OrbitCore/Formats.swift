import Foundation

/// A conversion target offered to the user.
public struct OutputFormat: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let ext: String
    public let title: String
    public let resultKind: FileKind

    public init(id: String, ext: String, title: String, resultKind: FileKind) {
        self.id = id
        self.ext = ext
        self.title = title
        self.resultKind = resultKind
    }
}

/// An image container ImageIO may be able to write. Availability is checked
/// at runtime against `CGImageDestinationCopyTypeIdentifiers`.
public struct ImageFormatSpec: Sendable {
    public let id: String
    public let ext: String
    public let uti: String
    public let title: String
    public let supportsAlpha: Bool
    public let lossy: Bool

    var outputFormat: OutputFormat {
        OutputFormat(id: id, ext: ext, title: title, resultKind: .image)
    }
}

/// A media container plus the encoders OrbitDrop is willing to use for it,
/// in order of preference. Availability depends on the installed ffmpeg.
public struct MediaFormatSpec: Sendable {
    public let id: String
    public let ext: String
    public let title: String
    public let muxer: String
    public let isVideo: Bool
    public let videoEncoders: [String]
    public let audioEncoders: [String]

    public func isAvailable(in toolchain: MediaToolchain) -> Bool {
        guard toolchain.muxers.contains(muxer) else { return false }
        if isVideo && !videoEncoders.contains(where: toolchain.encoders.contains) { return false }
        // A container that carries sound is offered only when its audio can
        // be encoded too, so audio is never dropped silently. (GIF lists no
        // audio encoders: it has no sound by definition.)
        if !audioEncoders.isEmpty && !audioEncoders.contains(where: toolchain.encoders.contains) { return false }
        if !isVideo && audioEncoders.isEmpty { return false }
        return true
    }

    var outputFormat: OutputFormat {
        OutputFormat(id: id, ext: ext, title: title, resultKind: isVideo ? .video : .audio)
    }
}

public enum FormatRegistry {
    public static let imageFormats: [ImageFormatSpec] = [
        ImageFormatSpec(id: "png", ext: "png", uti: "public.png", title: "PNG image", supportsAlpha: true, lossy: false),
        ImageFormatSpec(id: "jpg", ext: "jpg", uti: "public.jpeg", title: "JPEG image", supportsAlpha: false, lossy: true),
        ImageFormatSpec(id: "heic", ext: "heic", uti: "public.heic", title: "HEIC image", supportsAlpha: true, lossy: true),
        ImageFormatSpec(id: "tiff", ext: "tiff", uti: "public.tiff", title: "TIFF image", supportsAlpha: true, lossy: false),
        ImageFormatSpec(id: "gif", ext: "gif", uti: "com.compuserve.gif", title: "GIF image", supportsAlpha: true, lossy: false),
        ImageFormatSpec(id: "bmp", ext: "bmp", uti: "com.microsoft.bmp", title: "BMP image", supportsAlpha: false, lossy: false),
        ImageFormatSpec(id: "jp2", ext: "jp2", uti: "public.jpeg-2000", title: "JPEG 2000 image", supportsAlpha: true, lossy: true),
        ImageFormatSpec(id: "webp", ext: "webp", uti: "org.webmproject.webp", title: "WebP image", supportsAlpha: true, lossy: true),
        ImageFormatSpec(id: "avif", ext: "avif", uti: "public.avif", title: "AVIF image", supportsAlpha: true, lossy: true),
        ImageFormatSpec(id: "ico", ext: "ico", uti: "com.microsoft.ico", title: "ICO icon (256 px)", supportsAlpha: true, lossy: false),
        ImageFormatSpec(id: "psd", ext: "psd", uti: "com.adobe.photoshop-image", title: "Photoshop image", supportsAlpha: true, lossy: false),
        ImageFormatSpec(id: "tga", ext: "tga", uti: "com.truevision.tga-image", title: "TGA image", supportsAlpha: true, lossy: false),
    ]

    private static let h264Family = ["h264_videotoolbox", "libx264", "mpeg4"]

    public static let mediaFormats: [MediaFormatSpec] = [
        MediaFormatSpec(id: "mp4", ext: "mp4", title: "MP4 video", muxer: "mp4", isVideo: true,
                        videoEncoders: h264Family, audioEncoders: ["aac", "aac_at"]),
        MediaFormatSpec(id: "mov", ext: "mov", title: "QuickTime movie", muxer: "mov", isVideo: true,
                        videoEncoders: h264Family, audioEncoders: ["aac", "aac_at"]),
        MediaFormatSpec(id: "mkv", ext: "mkv", title: "Matroska video", muxer: "matroska", isVideo: true,
                        videoEncoders: h264Family, audioEncoders: ["aac", "aac_at", "libopus", "libvorbis"]),
        MediaFormatSpec(id: "webm", ext: "webm", title: "WebM video", muxer: "webm", isVideo: true,
                        videoEncoders: ["libvpx-vp9", "libvpx"], audioEncoders: ["libopus", "libvorbis"]),
        MediaFormatSpec(id: "gif", ext: "gif", title: "Animated GIF", muxer: "gif", isVideo: true,
                        videoEncoders: ["gif"], audioEncoders: []),
        MediaFormatSpec(id: "mp3", ext: "mp3", title: "MP3 audio", muxer: "mp3", isVideo: false,
                        videoEncoders: [], audioEncoders: ["libmp3lame"]),
        MediaFormatSpec(id: "m4a", ext: "m4a", title: "M4A (AAC) audio", muxer: "ipod", isVideo: false,
                        videoEncoders: [], audioEncoders: ["aac", "aac_at"]),
        MediaFormatSpec(id: "wav", ext: "wav", title: "WAV audio", muxer: "wav", isVideo: false,
                        videoEncoders: [], audioEncoders: ["pcm_s16le"]),
        MediaFormatSpec(id: "flac", ext: "flac", title: "FLAC audio", muxer: "flac", isVideo: false,
                        videoEncoders: [], audioEncoders: ["flac"]),
        MediaFormatSpec(id: "ogg", ext: "ogg", title: "Ogg Vorbis audio", muxer: "ogg", isVideo: false,
                        videoEncoders: [], audioEncoders: ["libvorbis"]),
        MediaFormatSpec(id: "opus", ext: "opus", title: "Opus audio", muxer: "opus", isVideo: false,
                        videoEncoders: [], audioEncoders: ["libopus"]),
        MediaFormatSpec(id: "aiff", ext: "aiff", title: "AIFF audio", muxer: "aiff", isVideo: false,
                        videoEncoders: [], audioEncoders: ["pcm_s16be"]),
    ]

    public static let documentFormats: [OutputFormat] = [
        OutputFormat(id: "txt", ext: "txt", title: "Plain text", resultKind: .document),
        OutputFormat(id: "rtf", ext: "rtf", title: "Rich Text (RTF)", resultKind: .document),
        OutputFormat(id: "docx", ext: "docx", title: "Word document (DOCX)", resultKind: .document),
        OutputFormat(id: "odt", ext: "odt", title: "OpenDocument text", resultKind: .document),
        OutputFormat(id: "doc", ext: "doc", title: "Word 97 document (DOC)", resultKind: .document),
        OutputFormat(id: "html", ext: "html", title: "HTML page", resultKind: .document),
        OutputFormat(id: "pdf", ext: "pdf", title: "PDF document", resultKind: .pdf),
    ]

    public static let subtitleFormats: [OutputFormat] = [
        OutputFormat(id: "srt", ext: "srt", title: "SubRip subtitles (SRT)", resultKind: .subtitle),
        OutputFormat(id: "vtt", ext: "vtt", title: "WebVTT subtitles", resultKind: .subtitle),
        OutputFormat(id: "txt", ext: "txt", title: "Plain text", resultKind: .document),
    ]

    static let pdfFormat = OutputFormat(id: "pdf", ext: "pdf", title: "PDF document", resultKind: .pdf)
    static let textFormat = OutputFormat(id: "txt", ext: "txt", title: "Plain text", resultKind: .document)

    /// Image formats a PDF page can be rasterized to.
    static let pdfRasterIDs = ["png", "jpg", "tiff"]

    private static let aliases: [String: String] = [
        "jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "heif": "heic", "jpf": "jp2", "j2k": "jp2",
        "m4v": "mp4", "aif": "aiff", "aifc": "aiff", "oga": "ogg", "text": "txt", "htm": "html",
    ]

    /// Maps an extension or user-typed format name to a canonical format id.
    public static func canonicalID(_ name: String) -> String {
        var lower = name.lowercased()
        if lower.hasPrefix(".") { lower.removeFirst() }
        return aliases[lower] ?? lower
    }

    public static func imageSpec(id: String) -> ImageFormatSpec? {
        imageFormats.first { $0.id == id }
    }

    public static func mediaSpec(id: String) -> MediaFormatSpec? {
        mediaFormats.first { $0.id == id }
    }
}
