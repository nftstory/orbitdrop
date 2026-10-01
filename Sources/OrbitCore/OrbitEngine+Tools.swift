import Foundation
import CoreGraphics

extension OrbitEngine {
    /// Runs one tool inside a staging area and returns the staged outputs.
    func stageTool(
        _ tool: ToolDescriptor, sources: [SourceFile], options: ToolOptions, staging: StagingArea,
        token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        let source = sources[0]
        switch tool.id {
        case let id where id.hasPrefix("image"):
            return try stageImageTool(id, sources, options, staging, token)
        case let id where id.hasPrefix("pdf-"):
            return try stagePDFTool(id, sources, options, staging, token, progress)
        case let id where id.hasPrefix("media-") || id.hasPrefix("audio-"):
            return try stageMediaTool(id, sources, options, staging, token, progress)
        case "subtitle-shift":
            let seconds = try options.double("offset") ?? 0
            guard abs(seconds) <= ToolOptions.maximumSeconds else {
                throw OrbitError.invalidOptions("The subtitle offset is out of range.")
            }
            let text = try DocumentEngine.readText(source.url)
            let format = SubtitleEngine.format(forExtension: source.ext, text: text)
            let shifted = SubtitleEngine.shift(
                try SubtitleEngine.parse(text, format: format), byMilliseconds: Int((seconds * 1000).rounded()))
            guard !shifted.isEmpty else {
                throw OrbitError.invalidOptions("That offset would move every subtitle before the start.")
            }
            let output = staging.newFile(ext: format.rawValue)
            try Data(SubtitleEngine.serialize(shifted, format: format).utf8).write(to: output)
            return .single(output, stem: "\(source.stem)-shifted", ext: format.rawValue, check: .nonEmpty)
        case "archive-zip", "archive-tar", "archive-tgz":
            let payload = try ArchiveEngine.preparePayload(sources, staging: staging, token: token)
            let ext = tool.id == "archive-zip" ? "zip" : (tool.id == "archive-tar" ? "tar" : "tgz")
            let output = staging.newFile(ext: ext)
            if ext == "zip" {
                try ArchiveEngine.createZip(payload: payload, output: output, token: token)
            } else {
                try ArchiveEngine.createTar(payload: payload, output: output, compressed: ext == "tgz", token: token)
            }
            let stem = sources.count == 1 ? source.stem : "\(source.stem)-archive"
            return .single(output, stem: stem, ext: ext, check: .nonEmpty)
        case "archive-gzip":
            let output = staging.newFile(ext: "gz")
            try ArchiveEngine.gzipFile(source.url, output: output, token: token)
            // Keeps the full original name: report.txt -> report.txt.gz
            return .single(output, stem: source.name, ext: "gz", check: .nonEmpty)
        case "archive-list":
            let entries = try ArchiveEngine.list(source.url, token: token)
            guard !entries.isEmpty else {
                throw OrbitError.malformed("\(source.name) contains no entries.")
            }
            let output = staging.newFile(ext: "txt")
            try Data((entries.joined(separator: "\n") + "\n").utf8).write(to: output)
            return .single(output, stem: "\(source.stem)-contents", ext: "txt", check: .nonEmpty)
        default:
            throw OrbitError.unsupported("Unknown tool: \(tool.id)")
        }
    }

    // MARK: Images

    /// Loads, transforms and re-encodes one image. The source format is kept
    /// when this Mac can write it; otherwise PNG is used and noted.
    private func imageTool(
        _ source: SourceFile, _ staging: StagingArea, suffix: String, format: String? = nil,
        keepMetadata: Bool = true, quality: Double? = nil, transform: (LoadedImage) throws -> CGImage
    ) throws -> StagedResult {
        let loaded = try ImageEngine.load(source.url)
        let image = try transform(loaded)
        var notes = animationNotes(loaded)

        let ownID = FormatRegistry.canonicalID(source.ext)
        let wanted = format ?? ownID
        let spec: ImageFormatSpec
        if let candidate = FormatRegistry.imageSpec(id: wanted), capabilities.canWrite(candidate) {
            spec = candidate
        } else if let png = FormatRegistry.imageSpec(id: "png") {
            spec = png
            notes.append("Saved as PNG because this Mac cannot write .\(source.ext) images.")
        } else {
            throw OrbitError.unsupported("No writable image format is available.")
        }
        let output = staging.newFile(ext: spec.ext)
        try ImageEngine.write(
            image, to: output, spec: spec, quality: quality,
            metadata: keepMetadata ? ImageEngine.preservedMetadata(loaded.properties) : nil)
        return .single(output, stem: "\(source.stem)-\(suffix)", ext: spec.ext, check: .image, notes: notes)
    }

    private func stageImageTool(
        _ id: String, _ sources: [SourceFile], _ options: ToolOptions, _ staging: StagingArea, _ token: CancellationToken?
    ) throws -> StagedResult {
        let source = sources[0]
        switch id {
        case "image-compress":
            let quality = min(max(try options.double("quality") ?? 0.6, 0.01), 1)
            let maxDimension = try options.double("maxDimension")
            let requested = options.string("format") ?? "auto"
            let ownID = FormatRegistry.canonicalID(source.ext)
            let formatID = requested == "auto"
                ? ((ownID == "jpg" || ownID == "heic") ? ownID : "jpg")
                : FormatRegistry.canonicalID(requested)
            guard let spec = FormatRegistry.imageSpec(id: formatID), spec.lossy, capabilities.canWrite(spec) else {
                throw OrbitError.invalidOptions("Compression format \"\(requested)\" is not a lossy format this Mac can write.")
            }
            return try imageTool(source, staging, suffix: "compressed", format: spec.id, quality: quality) { loaded in
                guard let maxDimension, maxDimension >= 1 else { return loaded.image }
                let longest = Double(max(loaded.image.width, loaded.image.height))
                guard longest > maxDimension else { return loaded.image }
                let factor = maxDimension / longest
                return try ImageEngine.redraw(
                    loaded.image,
                    width: max(1, Int((Double(loaded.image.width) * factor).rounded())),
                    height: max(1, Int((Double(loaded.image.height) * factor).rounded())))
            }
        case "image-strip-metadata":
            return try imageTool(source, staging, suffix: "clean", keepMetadata: false, quality: 0.95) { $0.image }
        case "image-resize":
            return try imageTool(source, staging, suffix: "resized") { loaded in
                let size = try ImageEngine.targetSize(for: loaded.image, options: options)
                return try ImageEngine.redraw(loaded.image, width: size.width, height: size.height)
            }
        case "image-crop":
            guard let width = try options.double("width"), let height = try options.double("height") else {
                throw OrbitError.invalidOptions("Crop needs a width and a height.")
            }
            let x = try options.double("x") ?? 0
            let y = try options.double("y") ?? 0
            return try imageTool(source, staging, suffix: "cropped") { loaded in
                try ImageEngine.crop(loaded.image, to: CGRect(x: x, y: y, width: width, height: height))
            }
        case "image-rotate":
            let degrees = try options.int("degrees") ?? 90
            let flip = options.string("flip") ?? "none"
            guard ["none", "horizontal", "vertical"].contains(flip) else {
                throw OrbitError.invalidOptions("Flip must be none, horizontal or vertical.")
            }
            return try imageTool(source, staging, suffix: "rotated") { loaded in
                try ImageEngine.rotate(
                    loaded.image, degrees: degrees, flipHorizontal: flip == "horizontal", flipVertical: flip == "vertical")
            }
        case "image-adjust":
            let brightness = try options.double("brightness") ?? 0
            let contrast = try options.double("contrast") ?? 1
            let saturation = try options.double("saturation") ?? 1
            let exposure = try options.double("exposure") ?? 0
            return try imageTool(source, staging, suffix: "adjusted") { loaded in
                try ImageEngine.adjust(
                    loaded.image, brightness: brightness, contrast: contrast, saturation: saturation, exposure: exposure)
            }
        case "image-annotate":
            let text = options.string("text")
            let boxes = try options.rects("boxes")
            guard (text?.isEmpty == false) || !boxes.isEmpty else {
                throw OrbitError.invalidOptions("Give some text or at least one box to draw.")
            }
            let origin = CGPoint(x: try options.double("x") ?? 16, y: try options.double("y") ?? 16)
            let fontSize = min(max(try options.double("fontSize") ?? 32, 1), 4000)
            let lineWidth = min(max(try options.double("lineWidth") ?? 4, 0.25), 2000)
            let color = try ImageEngine.color(hex: options.string("color") ?? "#FF3B30")
            return try imageTool(source, staging, suffix: "annotated") { loaded in
                try ImageEngine.annotate(
                    loaded.image, text: text, origin: origin, fontSize: fontSize, color: color,
                    boxes: boxes, lineWidth: lineWidth)
            }
        case "image-redact":
            let rects = try options.rects("rects")
            guard !rects.isEmpty else {
                throw OrbitError.invalidOptions("Give at least one area to black out.")
            }
            return try imageTool(source, staging, suffix: "redacted", keepMetadata: false, quality: 0.95) { loaded in
                try ImageEngine.redact(loaded.image, rects: rects)
            }
        case "image-background":
            let mode = options.string("mode") ?? "fill"
            if mode == "remove" {
                guard capabilities.supportsSubjectMask else {
                    throw OrbitError.unsupported("Background removal needs macOS 14 or later.")
                }
                return try imageTool(source, staging, suffix: "subject", format: "png", keepMetadata: false) { loaded in
                    try ImageEngine.removeBackground(loaded.image)
                }
            }
            guard mode == "fill" else {
                throw OrbitError.invalidOptions("Background mode must be fill or remove.")
            }
            let color = try ImageEngine.color(hex: options.string("color") ?? "#FFFFFF")
            return try imageTool(source, staging, suffix: "background") { loaded in
                try ImageEngine.redraw(
                    loaded.image, width: loaded.image.width, height: loaded.image.height, background: color)
            }
        case "image-frame":
            let color = try ImageEngine.color(hex: options.string("color") ?? "#F2F2F7")
            let aspect = try ImageEngine.aspectRatio(options.string("aspect"))
            let shadow = try options.double("shadow") ?? 40
            let paddingPixels = try options.double("padding")
            let paddingPercent = try options.double("paddingPercent") ?? 8
            let cornerPixels = try options.double("cornerRadius")
            let cornerPercent = try options.double("cornerPercent") ?? 0
            guard (0...200).contains(paddingPercent), (0...50).contains(cornerPercent) else {
                throw OrbitError.invalidOptions("Padding must be 0–200 % and corners 0–50 %.")
            }
            return try imageTool(source, staging, suffix: "framed") { loaded in
                let longer = Double(max(loaded.image.width, loaded.image.height))
                let shorter = Double(min(loaded.image.width, loaded.image.height))
                // Pixel values win over the relative ones when both are given.
                return try ImageEngine.frame(
                    loaded.image,
                    padding: paddingPixels ?? (longer * paddingPercent / 100).rounded(),
                    cornerRadius: cornerPixels ?? shorter * cornerPercent / 100,
                    shadow: shadow, color: color, aspect: aspect)
            }
        case "image-read-codes":
            let payloads = try ImageEngine.readCodes(try ImageEngine.load(source.url).image)
            guard !payloads.isEmpty else {
                throw OrbitError.engineFailure("No QR code or barcode was found in \(source.name).")
            }
            let output = staging.newFile(ext: "txt")
            try Data((payloads.joined(separator: "\n") + "\n").utf8).write(to: output)
            return .single(output, stem: "\(source.stem)-codes", ext: "txt", check: .nonEmpty)
        case "images-to-pdf":
            var images: [CGImage] = []
            var notes: [String] = []
            for item in sources {
                try token?.check()
                let loaded = try ImageEngine.load(item.url)
                images.append(loaded.image)
                if loaded.frameCount > 1 { notes.append("\(item.name): only the first frame was used.") }
            }
            let output = staging.newFile(ext: "pdf")
            try ImageEngine.writePDF(images: images, to: output)
            let stem = sources.count == 1 ? source.stem : "\(source.stem)-combined"
            return .single(output, stem: stem, ext: "pdf", check: .pdf, notes: notes)
        default:
            throw OrbitError.unsupported("Unknown tool: \(id)")
        }
    }

    // MARK: PDF

    private func stagePDFTool(
        _ id: String, _ sources: [SourceFile], _ options: ToolOptions, _ staging: StagingArea,
        _ token: CancellationToken?, _ progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        let source = sources[0]
        switch id {
        case "pdf-merge":
            let output = staging.newFile(ext: "pdf")
            try PDFEngine.merge(sources.map { $0.url }, to: output, token: token)
            return .single(output, stem: "\(source.stem)-merged", ext: "pdf", check: .pdf)
        case "pdf-split":
            let document = try PDFEngine.open(source.url)
            let groups: [[Int]]
            if let ranges = options.string("ranges") {
                groups = try PageRanges.parseGroups(ranges, pageCount: document.pageCount)
            } else {
                groups = (1...document.pageCount).map { [$0] }
            }
            var outputs: [StagedOutput] = []
            for (index, group) in groups.enumerated() {
                try token?.check()
                let output = staging.newFile(ext: "pdf")
                try PDFEngine.write(pages: group, from: document, to: output)
                let stem = "\(source.stem)-part\(OrbitEngine.padded(index + 1, of: groups.count))"
                outputs.append(StagedOutput(url: output, stem: stem, ext: "pdf", check: .pdf))
                progress?(Double(index + 1) / Double(groups.count))
            }
            return StagedResult(outputs: outputs)
        case "pdf-reorder":
            guard let order = options.string("order") else {
                throw OrbitError.invalidOptions("Give the new page order, for example 3,1,2.")
            }
            let document = try PDFEngine.open(source.url)
            let pages = try PageRanges.parseFlat(order, pageCount: document.pageCount)
            let output = staging.newFile(ext: "pdf")
            try PDFEngine.write(pages: pages, from: document, to: output)
            return .single(output, stem: "\(source.stem)-reordered", ext: "pdf", check: .pdf)
        case "pdf-rotate":
            let degrees = try options.int("degrees") ?? 90
            var pages: Set<Int>?
            if let selection = options.string("pages") {
                pages = Set(try PageRanges.parseFlat(selection, pageCount: try PDFEngine.pageCount(source.url)))
            }
            let output = staging.newFile(ext: "pdf")
            try PDFEngine.rotate(source.url, degrees: degrees, pages: pages, to: output)
            return .single(output, stem: "\(source.stem)-rotated", ext: "pdf", check: .pdf)
        case "pdf-redact-rasterize":
            let rects = try options.rects("rects")
            guard !rects.isEmpty else {
                throw OrbitError.invalidOptions("Give at least one area to black out.")
            }
            let dpi = min(max(try options.double("dpi") ?? 150, 72), 400)
            var pages: Set<Int>?
            if let selection = options.string("pages") {
                pages = Set(try PageRanges.parseFlat(selection, pageCount: try PDFEngine.pageCount(source.url)))
            }
            let output = staging.newFile(ext: "pdf")
            try PDFEngine.redactRasterized(
                source.url, rects: rects, pages: pages, dpi: dpi, to: output, token: token, progress: progress)
            return .single(
                output, stem: "\(source.stem)-redacted", ext: "pdf", check: .pdf,
                notes: ["Every page was rasterized at \(Int(dpi)) dpi: the PDF no longer contains selectable text."])
        default:
            throw OrbitError.unsupported("Unknown tool: \(id)")
        }
    }

    // MARK: Media

    private func stageMediaTool(
        _ id: String, _ sources: [SourceFile], _ options: ToolOptions, _ staging: StagingArea,
        _ token: CancellationToken?, _ progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        let source = sources[0]
        guard let toolchain = capabilities.media else {
            return try stageNativeMediaTool(id, source, options, staging, token, progress)
        }
        let ffmpeg = FFmpegEngine(toolchain: toolchain)
        switch id {
        case "media-compress":
            return try ffmpeg.compress(source, options: options, staging: staging, token: token, progress: progress)
        case "media-trim":
            let start = try options.time("start") ?? 0
            let end = try options.time("end")
            return try ffmpeg.trim(
                source, start: start, end: end, precise: options.bool("precise") ?? true,
                staging: staging, token: token, progress: progress)
        case "media-mute":
            return try ffmpeg.mute(source, staging: staging, token: token, progress: progress)
        case "media-crop":
            guard let width = try options.double("width"), let height = try options.double("height"),
                  width >= 2, height >= 2 else {
                throw OrbitError.invalidOptions("Crop needs a width and a height of at least 2 pixels.")
            }
            let x = max(try options.double("x") ?? 0, 0)
            let y = max(try options.double("y") ?? 0, 0)
            return try ffmpeg.crop(
                source, rect: CGRect(x: x, y: y, width: width, height: height),
                staging: staging, token: token, progress: progress)
        case "media-speed":
            let factor = try options.double("factor") ?? 2
            return try ffmpeg.speed(source, factor: factor, staging: staging, token: token, progress: progress)
        case "media-snapshot":
            return try ffmpeg.snapshot(source, at: try options.time("time") ?? 0, staging: staging, token: token)
        case "media-split":
            let seconds = try options.double("segmentSeconds") ?? 60
            return try ffmpeg.split(source, segmentSeconds: seconds, staging: staging, token: token, progress: progress)
        case "media-join":
            return try ffmpeg.join(sources, staging: staging, token: token, progress: progress)
        case "media-strip-metadata":
            return try ffmpeg.stripMetadata(source, staging: staging, token: token, progress: progress)
        case "audio-normalize":
            let target = try options.double("target") ?? -16
            guard (-70.0 ... -5.0).contains(target) else {
                throw OrbitError.invalidOptions("Target loudness must be between -70 and -5 LUFS.")
            }
            return try ffmpeg.audioEdit(
                source, suffix: "normalized", filters: [String(format: "loudnorm=I=%.1f:TP=-1.5:LRA=11", target)],
                extra: ["-ar", "48000"], staging: staging, token: token, progress: progress)
        case "audio-channels":
            let mode = options.string("mode") ?? "mono"
            var filters: [String] = []
            var extra: [String] = []
            switch mode {
            case "mono": extra = ["-ac", "1"]
            case "stereo": extra = ["-ac", "2"]
            case "left": filters = ["pan=mono|c0=FL"]
            case "right": filters = ["pan=mono|c0=FR"]
            case "swap": filters = ["pan=stereo|c0=FR|c1=FL"]
            default: throw OrbitError.invalidOptions("Channel mode must be mono, stereo, left, right or swap.")
            }
            return try ffmpeg.audioEdit(
                source, suffix: "channels", filters: filters, extra: extra, staging: staging, token: token, progress: progress)
        case "audio-bleep":
            let ranges = try options.timeRanges("ranges")
            guard !ranges.isEmpty else {
                throw OrbitError.invalidOptions("Give at least one time range to bleep, for example 1.5-2.5.")
            }
            let frequency = try options.int("frequency") ?? 1000
            guard (50...8000).contains(frequency) else {
                throw OrbitError.invalidOptions("Tone frequency must be between 50 and 8000 Hz.")
            }
            return try ffmpeg.audioEdit(
                source, suffix: "bleeped",
                filterComplex: FFmpegEngine.bleepFilter(ranges: ranges, frequency: frequency),
                staging: staging, token: token, progress: progress)
        default:
            throw OrbitError.unsupported("Unknown tool: \(id)")
        }
    }

    /// AVFoundation versions of trim, mute and snapshot for MOV/MP4 when no
    /// ffmpeg is installed.
    private func stageNativeMediaTool(
        _ id: String, _ source: SourceFile, _ options: ToolOptions, _ staging: StagingArea,
        _ token: CancellationToken?, _ progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        let ext = source.ext == "mov" ? "mov" : "mp4"
        let note = "Processed with AVFoundation (ffmpeg not installed)."
        switch id {
        case "media-trim":
            let start = try options.time("start") ?? 0
            let end = try options.time("end")
            if let end, end <= start {
                throw OrbitError.invalidOptions("The end time must be after the start time.")
            }
            let output = staging.newFile(ext: ext)
            try NativeMedia.exportVideo(
                source.url, to: output, fileType: NativeMedia.fileType(forExtension: ext), start: start, end: end,
                token: token, progress: progress)
            return .single(output, stem: "\(source.stem)-trimmed", ext: ext, check: .media, notes: [note])
        case "media-mute":
            let output = staging.newFile(ext: ext)
            try NativeMedia.exportVideo(
                source.url, to: output, fileType: NativeMedia.fileType(forExtension: ext), dropAudio: true,
                token: token, progress: progress)
            return .single(output, stem: "\(source.stem)-muted", ext: ext, check: .media, notes: [note])
        case "media-snapshot":
            let image = try NativeMedia.snapshot(source.url, at: try options.time("time") ?? 0)
            guard let png = FormatRegistry.imageSpec(id: "png") else {
                throw OrbitError.unsupported("PNG output is unavailable.")
            }
            let output = staging.newFile(ext: "png")
            try ImageEngine.write(image, to: output, spec: png)
            return .single(output, stem: "\(source.stem)-snapshot", ext: "png", check: .image, notes: [note])
        default:
            throw OrbitError.missingTool("This tool needs ffmpeg, which is not installed.")
        }
    }
}
