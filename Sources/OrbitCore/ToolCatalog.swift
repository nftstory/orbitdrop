import Foundation

/// One user-editable option of a tool. The GUI builds its parameter sheet
/// from these; the CLI passes the same keys in `--options`.
public struct ToolParameter: Sendable {
    public enum Kind: Sendable {
        case number(Double?)
        case text(String)
        case choice([String], String)
        case toggle(Bool)
    }

    public let key: String
    public let label: String
    public let kind: Kind
    public let help: String

    static func number(_ key: String, _ label: String, _ value: Double? = nil, help: String = "") -> ToolParameter {
        ToolParameter(key: key, label: label, kind: .number(value), help: help)
    }

    static func text(_ key: String, _ label: String, _ value: String = "", help: String = "") -> ToolParameter {
        ToolParameter(key: key, label: label, kind: .text(value), help: help)
    }

    static func choice(_ key: String, _ label: String, _ options: [String], help: String = "") -> ToolParameter {
        ToolParameter(key: key, label: label, kind: .choice(options, options[0]), help: help)
    }

    static func toggle(_ key: String, _ label: String, _ value: Bool, help: String = "") -> ToolParameter {
        ToolParameter(key: key, label: label, kind: .toggle(value), help: help)
    }
}

public struct ToolDescriptor: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// SF Symbol name for the GUI.
    public let symbol: String
    public let kinds: Set<FileKind>
    /// When set, only sources with these extensions are accepted.
    public let extensions: Set<String>?
    /// True when all inputs become a single output (merge, join, archive).
    public let combinesInputs: Bool
    public let minimumInputs: Int
    public let parameters: [ToolParameter]

    init(
        _ id: String, _ title: String, symbol: String, kinds: Set<FileKind>, extensions: Set<String>? = nil,
        combines: Bool = false, minimumInputs: Int = 1, parameters: [ToolParameter] = [], summary: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.kinds = kinds
        self.extensions = extensions
        self.combinesInputs = combines
        self.minimumInputs = minimumInputs
        self.parameters = parameters
    }

    public func accepts(kind: FileKind, ext: String) -> Bool {
        kinds.contains(kind) && (extensions == nil || extensions!.contains(ext.lowercased()))
    }
}

public enum ToolCatalog {
    static let rectHelp = "x,y,width,height from the top-left corner; separate several with semicolons."

    /// Every tool that can actually run with the given capabilities.
    public static func all(_ capabilities: Capabilities) -> [ToolDescriptor] {
        var tools: [ToolDescriptor] = []
        let image: Set<FileKind> = [.image]
        let pdf: Set<FileKind> = [.pdf]

        // Images (native)
        var compressFormats = ["auto", "jpg"]
        if let heic = FormatRegistry.imageSpec(id: "heic"), capabilities.canWrite(heic) { compressFormats.append("heic") }
        tools.append(ToolDescriptor(
            "image-compress", "Compress Image", symbol: "arrow.down.right.and.arrow.up.left", kinds: image,
            parameters: [
                .number("quality", "Quality (0.05–1)", 0.6),
                .number("maxDimension", "Longest side (px)", help: "Leave empty to keep the size."),
                .choice("format", "Format", compressFormats, help: "auto keeps JPEG/HEIC and turns other formats into JPEG."),
            ],
            summary: "Re-encodes with lossy compression, optionally downscaling. Transparency is flattened onto white for JPEG."))
        tools.append(ToolDescriptor(
            "image-strip-metadata", "Remove Image Metadata", symbol: "eye.slash", kinds: image,
            summary: "Rewrites the pixels without EXIF, GPS, IPTC or TIFF metadata. JPEG/HEIC are re-encoded at high quality."))
        tools.append(ToolDescriptor(
            "image-resize", "Resize Image", symbol: "arrow.up.left.and.arrow.down.right", kinds: image,
            parameters: [
                .number("width", "Width (px)"),
                .number("height", "Height (px)"),
                .number("scale", "Scale (%)", help: "Set width and/or height, or a scale. One dimension keeps the aspect ratio."),
            ],
            summary: "Resamples the image to a new pixel size."))
        tools.append(ToolDescriptor(
            "image-crop", "Crop Image", symbol: "crop", kinds: image,
            parameters: [
                .number("x", "Left (px)", 0), .number("y", "Top (px)", 0),
                .number("width", "Width (px)"), .number("height", "Height (px)"),
            ],
            summary: "Keeps a rectangle measured from the top-left corner."))
        tools.append(ToolDescriptor(
            "image-rotate", "Rotate / Flip Image", symbol: "rotate.right", kinds: image,
            parameters: [
                .choice("degrees", "Rotate clockwise", ["90", "180", "270", "0"]),
                .choice("flip", "Flip", ["none", "horizontal", "vertical"]),
            ],
            summary: "Rotates in quarter turns and optionally mirrors."))
        tools.append(ToolDescriptor(
            "image-adjust", "Adjust Image", symbol: "slider.horizontal.3", kinds: image,
            parameters: [
                .number("brightness", "Brightness (−1…1)", 0), .number("contrast", "Contrast (0…4)", 1),
                .number("saturation", "Saturation (0…2)", 1), .number("exposure", "Exposure (EV)", 0),
            ],
            summary: "Core Image colour controls and exposure."))
        tools.append(ToolDescriptor(
            "image-annotate", "Annotate Image", symbol: "pencil.tip", kinds: image,
            parameters: [
                .text("text", "Text"), .number("x", "Text left (px)", 16), .number("y", "Text top (px)", 16),
                .number("fontSize", "Font size (px)", 32), .text("color", "Colour", "#FF3B30"),
                .text("boxes", "Outlined boxes", help: rectHelp), .number("lineWidth", "Line width (px)", 4),
            ],
            summary: "Draws a line of text and/or outlined boxes onto the image."))
        tools.append(ToolDescriptor(
            "image-redact", "Redact Image", symbol: "rectangle.fill", kinds: image,
            parameters: [.text("rects", "Areas to black out", help: rectHelp)],
            summary: "Paints opaque black boxes into a new bitmap and drops metadata; the covered pixels are gone from the output."))
        var backgroundModes = ["fill"]
        if capabilities.supportsSubjectMask { backgroundModes.append("remove") }
        tools.append(ToolDescriptor(
            "image-background", "Image Background", symbol: "person.crop.rectangle", kinds: image,
            parameters: [
                .choice("mode", "Mode", backgroundModes,
                        help: "fill replaces transparency with a colour." + (capabilities.supportsSubjectMask ? " remove keeps the subject (Vision) and saves a PNG." : "")),
                .text("color", "Fill colour", "#FFFFFF"),
            ],
            summary: "Fills transparent areas with a colour" + (capabilities.supportsSubjectMask ? ", or removes the background around the main subject." : ".")))
        tools.append(ToolDescriptor(
            "image-frame", "Frame on Canvas", symbol: "square.on.square", kinds: image,
            parameters: [
                .number("paddingPercent", "Padding (% of longer side)", 8, help: "Or pass \"padding\" in pixels from the command line."),
                .number("cornerPercent", "Rounded corners (0–50 %)", 0, help: "Percent of the shorter side; \"cornerRadius\" in pixels also works."),
                .number("shadow", "Shadow (0–100)", 40),
                .text("color", "Canvas colour", "#F2F2F7"),
                .choice("aspect", "Canvas shape", ["original", "1:1", "4:3", "3:2", "16:9", "9:16", "4:5"],
                        help: "The canvas grows to this ratio; the image is never cropped or resampled."),
            ],
            summary: "Places the unchanged image on a larger solid-colour canvas with padding, rounded corners and a soft shadow."))
        tools.append(ToolDescriptor(
            "image-read-codes", "Read QR / Barcodes", symbol: "qrcode.viewfinder", kinds: image,
            summary: "Saves the payloads of QR codes and barcodes found by Vision to a text file."))
        tools.append(ToolDescriptor(
            "images-to-pdf", "Combine Images into PDF", symbol: "doc.on.doc", kinds: image, combines: true,
            summary: "One PDF with one page per image, in list order."))

        // PDF (native)
        tools.append(ToolDescriptor(
            "pdf-merge", "Merge PDFs", symbol: "square.stack.3d.up", kinds: pdf, combines: true, minimumInputs: 2,
            summary: "Appends the PDFs in list order."))
        tools.append(ToolDescriptor(
            "pdf-split", "Split PDF", symbol: "square.split.2x1", kinds: pdf,
            parameters: [.text("ranges", "Page groups", help: "For example 1-3,4-6. Empty makes one file per page.")],
            summary: "Writes one PDF per page or per page group."))
        tools.append(ToolDescriptor(
            "pdf-reorder", "Reorder / Extract Pages", symbol: "arrow.up.arrow.down", kinds: pdf,
            parameters: [.text("order", "New page order", help: "For example 3,1,2 or 5-1. Pages left out are removed.")],
            summary: "Builds a PDF from the listed pages in the listed order."))
        tools.append(ToolDescriptor(
            "pdf-rotate", "Rotate PDF Pages", symbol: "rotate.right", kinds: pdf,
            parameters: [
                .choice("degrees", "Rotate clockwise", ["90", "180", "270"]),
                .text("pages", "Pages", help: "For example 1,3-4. Empty rotates every page."),
            ],
            summary: "Rotates pages in quarter turns."))
        tools.append(ToolDescriptor(
            "pdf-redact-rasterize", "Redact PDF (Rasterize)", symbol: "rectangle.fill", kinds: pdf,
            parameters: [
                .text("rects", "Areas to black out (points)", help: rectHelp),
                .text("pages", "Pages to redact", help: "Empty applies the areas to every page."),
                .number("dpi", "Resolution (dpi)", 150),
            ],
            summary: "Turns every page into an image with black boxes painted in. No text or vector content remains; the result is not searchable."))

        // Media
        let nativeVideo = NativeMedia.videoExtensions
        if capabilities.media != nil {
            let media: Set<FileKind> = [.video, .audio]
            let video: Set<FileKind> = [.video]
            tools.append(ToolDescriptor(
                "media-compress", "Compress Media", symbol: "arrow.down.right.and.arrow.up.left", kinds: media,
                parameters: [
                    .choice("quality", "Quality", ["medium", "high", "low"]),
                    .number("maxHeight", "Max video height (px)", help: "Leave empty to keep the frame size."),
                    .number("audioBitrate", "Audio bitrate (kbps)"),
                ],
                summary: "Re-encodes at a lower bitrate. Lossless audio becomes M4A/MP3."))
            tools.append(ToolDescriptor(
                "media-trim", "Trim", symbol: "scissors", kinds: media,
                parameters: [
                    .text("start", "Start", "0", help: "Seconds or HH:MM:SS."),
                    .text("end", "End", help: "Empty keeps everything to the end."),
                    .toggle("precise", "Frame-accurate (re-encode)", true, help: "Off copies streams and cuts at keyframes."),
                ],
                summary: "Keeps the part between start and end."))
            tools.append(ToolDescriptor(
                "media-mute", "Mute Video", symbol: "speaker.slash", kinds: video,
                summary: "Removes the audio track; the picture is copied unchanged."))
            tools.append(ToolDescriptor(
                "media-crop", "Crop Video", symbol: "crop", kinds: video,
                parameters: [
                    .number("x", "Left (px)", 0), .number("y", "Top (px)", 0),
                    .number("width", "Width (px)"), .number("height", "Height (px)"),
                ],
                summary: "Crops the picture and re-encodes."))
            tools.append(ToolDescriptor(
                "media-speed", "Change Speed", symbol: "speedometer", kinds: media,
                parameters: [.number("factor", "Speed factor (0.25–4)", 2)],
                summary: "Speeds up or slows down, keeping audio pitch."))
            tools.append(ToolDescriptor(
                "media-snapshot", "Snapshot Frame", symbol: "camera", kinds: video,
                parameters: [.text("time", "Time", "0", help: "Seconds or HH:MM:SS.")],
                summary: "Saves one frame as PNG."))
            tools.append(ToolDescriptor(
                "media-split", "Split into Segments", symbol: "square.split.2x1", kinds: media,
                parameters: [.number("segmentSeconds", "Segment length (s)", 60)],
                summary: "Cuts into equal segments at keyframes without re-encoding."))
            tools.append(ToolDescriptor(
                "media-join", "Join Clips", symbol: "link", kinds: media, combines: true, minimumInputs: 2,
                summary: "Joins clips of one kind end to end, re-encoding to the first clip's format."))
            tools.append(ToolDescriptor(
                "media-strip-metadata", "Remove Media Metadata", symbol: "eye.slash", kinds: media,
                summary: "Removes container tags and chapters; streams are copied."))
            tools.append(ToolDescriptor(
                "audio-normalize", "Normalize Loudness", symbol: "waveform.path.ecg", kinds: media,
                parameters: [.number("target", "Target loudness (LUFS)", -16)],
                summary: "Single-pass EBU R128 loudness normalization of the audio track."))
            tools.append(ToolDescriptor(
                "audio-channels", "Audio Channels", symbol: "hifispeaker.2", kinds: media,
                parameters: [.choice("mode", "Mode", ["mono", "stereo", "left", "right", "swap"])],
                summary: "Downmixes, upmixes, isolates or swaps channels."))
            tools.append(ToolDescriptor(
                "audio-bleep", "Bleep Audio", symbol: "waveform.badge.minus", kinds: media,
                parameters: [
                    .text("ranges", "Time ranges", help: "start-end in seconds; separate several with semicolons, e.g. 1.5-2.5; 7-8."),
                    .number("frequency", "Tone (Hz)", 1000),
                ],
                summary: "Replaces the given ranges with a tone."))
        } else {
            // AVFoundation fallback: QuickTime/MPEG-4 video only.
            let video: Set<FileKind> = [.video]
            tools.append(ToolDescriptor(
                "media-trim", "Trim", symbol: "scissors", kinds: video, extensions: nativeVideo,
                parameters: [
                    .text("start", "Start", "0", help: "Seconds or HH:MM:SS."),
                    .text("end", "End", help: "Empty keeps everything to the end."),
                ],
                summary: "Keeps the part between start and end (AVFoundation re-export)."))
            tools.append(ToolDescriptor(
                "media-mute", "Mute Video", symbol: "speaker.slash", kinds: video, extensions: nativeVideo,
                summary: "Removes the audio track (AVFoundation re-export)."))
            tools.append(ToolDescriptor(
                "media-snapshot", "Snapshot Frame", symbol: "camera", kinds: video, extensions: nativeVideo,
                parameters: [.text("time", "Time", "0", help: "Seconds or HH:MM:SS.")],
                summary: "Saves one frame as PNG."))
        }

        // Subtitles (native)
        tools.append(ToolDescriptor(
            "subtitle-shift", "Shift Subtitles", symbol: "clock.arrow.2.circlepath", kinds: [.subtitle],
            parameters: [.number("offset", "Offset (seconds)", 0, help: "Negative values make subtitles appear earlier.")],
            summary: "Moves every cue earlier or later."))

        // Archives (system ditto / tar / gzip)
        let anything = Set(FileKind.allCases)
        tools.append(ToolDescriptor(
            "archive-zip", "Create ZIP", symbol: "archivebox", kinds: anything, combines: true,
            summary: "Packs the files into one ZIP archive."))
        tools.append(ToolDescriptor(
            "archive-tar", "Create TAR", symbol: "archivebox", kinds: anything, combines: true,
            summary: "Packs the files into one TAR archive."))
        tools.append(ToolDescriptor(
            "archive-tgz", "Create TAR.GZ", symbol: "archivebox", kinds: anything, combines: true,
            summary: "Packs the files into one gzip-compressed TAR archive."))
        tools.append(ToolDescriptor(
            "archive-gzip", "GZIP File", symbol: "archivebox", kinds: anything,
            summary: "Compresses a single file to .gz."))
        tools.append(ToolDescriptor(
            "archive-list", "List Archive Contents", symbol: "list.bullet.rectangle", kinds: [.archive],
            summary: "Saves the archive's entry names to a text file. Nothing is extracted."))
        return tools
    }
}
