import Foundation
import CoreGraphics
import ImageIO

public struct BatchTargets: Sendable {
    /// Formats every supported file in the batch can be converted to.
    public let formats: [OutputFormat]
    /// Files OrbitDrop has no conversion for.
    public let unsupported: [URL]
}

public enum BatchAction: Sendable {
    case convert(formatID: String, options: ToolOptions)
    case tool(id: String, options: ToolOptions)
}

public enum JobStatus {
    case running(Double?)
    case succeeded(JobResult)
    case skipped(String)
    case failed(String)
    case cancelled
}

public struct JobOutcome {
    public let sources: [URL]
    public let status: JobStatus
}

public struct FileReport {
    public let url: URL
    public let kind: FileKind
    public let sizeBytes: UInt64
    public let details: [(key: String, value: String)]
    public let targets: [OutputFormat]
    public let tools: [ToolDescriptor]
}

/// The single entry point shared by the GUI, the CLI and the tests.
public final class OrbitEngine: @unchecked Sendable {
    public let capabilities: Capabilities
    public let tools: [ToolDescriptor]
    let validator: OutputValidator

    public init(capabilities: Capabilities) {
        self.capabilities = capabilities
        self.tools = ToolCatalog.all(capabilities)
        self.validator = OutputValidator(toolchain: capabilities.media)
    }

    // MARK: What is offered

    /// Every format a file with this extension can become, including its own.
    public func allTargets(forExtension ext: String) -> [OutputFormat] {
        let lower = ext.lowercased()
        switch FileKind.of(extension: lower) {
        case .image:
            return FormatRegistry.imageFormats.filter(capabilities.canWrite).map { $0.outputFormat } + [FormatRegistry.pdfFormat]
        case .pdf:
            return FormatRegistry.pdfRasterIDs
                .compactMap { FormatRegistry.imageSpec(id: $0) }
                .filter(capabilities.canWrite)
                .map { $0.outputFormat } + [FormatRegistry.textFormat]
        case .document:
            return FormatRegistry.documentFormats
        case .subtitle:
            return FormatRegistry.subtitleFormats
        case .video:
            if let toolchain = capabilities.media {
                return FormatRegistry.mediaFormats.filter { $0.isAvailable(in: toolchain) }.map { $0.outputFormat }
            }
            guard NativeMedia.videoExtensions.contains(lower) else { return [] }
            return NativeMedia.videoTargets.compactMap { FormatRegistry.mediaSpec(id: $0)?.outputFormat }
        case .audio:
            if let toolchain = capabilities.media {
                return FormatRegistry.mediaFormats
                    .filter { !$0.isVideo && $0.isAvailable(in: toolchain) }
                    .map { $0.outputFormat }
            }
            guard NativeMedia.audioExtensions.contains(lower) else { return [] }
            return NativeMedia.audioTargets.compactMap { FormatRegistry.mediaSpec(id: $0)?.outputFormat }
        case .archive, .unknown:
            return []
        }
    }

    /// Conversion targets for one file (its own format excluded).
    public func targets(for url: URL) -> [OutputFormat] {
        commonTargets(for: [url]).formats
    }

    /// The intersection of targets across a batch. Files without any
    /// conversion are reported separately instead of emptying the list.
    /// A format is dropped only when every file already has it.
    public func commonTargets(for urls: [URL]) -> BatchTargets {
        var unsupported: [URL] = []
        var lists: [[OutputFormat]] = []
        var ownIDs: [String] = []
        for url in urls {
            let all = allTargets(forExtension: url.pathExtension)
            if all.isEmpty {
                unsupported.append(url)
            } else {
                lists.append(all)
                ownIDs.append(FormatRegistry.canonicalID(url.pathExtension))
            }
        }
        guard var common = lists.first else {
            return BatchTargets(formats: [], unsupported: unsupported)
        }
        for list in lists.dropFirst() {
            let ids = Set(list.map { $0.id })
            common = common.filter { ids.contains($0.id) }
        }
        common = common.filter { format in !ownIDs.allSatisfy { $0 == format.id } }
        return BatchTargets(formats: common, unsupported: unsupported)
    }

    public func tools(for url: URL) -> [ToolDescriptor] {
        commonTools(for: [url])
    }

    /// Tools that accept every file in the batch.
    public func commonTools(for urls: [URL]) -> [ToolDescriptor] {
        guard !urls.isEmpty else { return [] }
        let kinds = Set(urls.map { FileKind.detect($0) })
        return tools.filter { tool in
            guard urls.count >= tool.minimumInputs else { return false }
            if tool.id == "media-join" && kinds.count != 1 { return false }
            return urls.allSatisfy { tool.accepts(kind: FileKind.detect($0), ext: $0.pathExtension) }
        }
    }

    public func tool(id: String) -> ToolDescriptor? {
        tools.first { $0.id == id }
    }

    // MARK: Conversion

    public func convert(
        _ url: URL, to formatName: String, options: ToolOptions = .none, outputDirectory: URL? = nil,
        token: CancellationToken? = nil, progress: ((Double) -> Void)? = nil
    ) throws -> JobResult {
        let source = try SourceFile(url)
        let formatID = FormatRegistry.canonicalID(formatName)
        guard let format = allTargets(forExtension: source.ext).first(where: { $0.id == formatID }) else {
            throw OrbitError.unsupported("\(source.name) cannot be converted to \(formatID.uppercased()) on this Mac.")
        }
        guard FormatRegistry.canonicalID(source.ext) != formatID else {
            throw OrbitError.unsupported("\(source.name) is already \(formatID.uppercased()).")
        }
        try ContentSniffer.verify(source.url, kind: source.kind)
        return try JobRunner.perform(
            sources: [source], outputDirectory: outputDirectory, token: token, validator: validator
        ) { staging in
            switch source.kind {
            case .image:
                return try stageImageConversion(source, format, options, staging)
            case .pdf:
                return try stagePDFConversion(source, format, options, staging, token, progress)
            case .document:
                let text = try DocumentEngine.read(source.url, ext: source.ext)
                let output = staging.newFile(ext: format.ext)
                try DocumentEngine.write(text, formatID: format.id, to: output)
                let notes = format.id == "pdf" ? ["PDF layout is basic: fonts and paragraphs carry over, images and text colours do not."] : []
                return .single(output, stem: source.stem, ext: format.ext, check: format.id == "pdf" ? .pdf : .nonEmpty, notes: notes)
            case .subtitle:
                let text = try DocumentEngine.readText(source.url)
                let cues = try SubtitleEngine.parse(text, format: SubtitleEngine.format(forExtension: source.ext, text: text))
                let output = staging.newFile(ext: format.ext)
                let rendered: String
                switch format.id {
                case "srt": rendered = SubtitleEngine.serialize(cues, format: .srt)
                case "vtt": rendered = SubtitleEngine.serialize(cues, format: .vtt)
                default: rendered = SubtitleEngine.plainText(cues)
                }
                try Data(rendered.utf8).write(to: output)
                return .single(output, stem: source.stem, ext: format.ext, check: .nonEmpty)
            case .video, .audio:
                return try stageMediaConversion(source, format, staging, token, progress)
            case .archive, .unknown:
                throw OrbitError.unsupported("\(source.name) has no conversions.")
            }
        }
    }

    func animationNotes(_ loaded: LoadedImage) -> [String] {
        loaded.frameCount > 1
            ? ["The source has \(loaded.frameCount) frames or pages; only the first was used (animation is not preserved)."]
            : []
    }

    private func stageImageConversion(
        _ source: SourceFile, _ format: OutputFormat, _ options: ToolOptions, _ staging: StagingArea
    ) throws -> StagedResult {
        let loaded = try ImageEngine.load(source.url)
        var notes = animationNotes(loaded)
        let output = staging.newFile(ext: format.ext)
        if format.id == "pdf" {
            try ImageEngine.writePDF(images: [loaded.image], to: output)
            return .single(output, stem: source.stem, ext: "pdf", check: .pdf, notes: notes)
        }
        guard let spec = FormatRegistry.imageSpec(id: format.id), capabilities.canWrite(spec) else {
            throw OrbitError.unsupported("This Mac cannot write \(format.ext.uppercased()) images.")
        }
        var image = loaded.image
        if spec.id == "ico" {
            image = try ImageEngine.fitSquare(image, side: 256)
            notes.append("ICO output is scaled to fit a 256×256 canvas.")
        }
        try ImageEngine.write(
            image, to: output, spec: spec, quality: try options.double("quality"),
            metadata: ImageEngine.preservedMetadata(loaded.properties))
        return .single(output, stem: source.stem, ext: spec.ext, check: .image, notes: notes)
    }

    static func padded(_ number: Int, of total: Int) -> String {
        let digits = max(2, String(total).count)
        return String(format: "%0\(digits)d", number)
    }

    private func stagePDFConversion(
        _ source: SourceFile, _ format: OutputFormat, _ options: ToolOptions, _ staging: StagingArea,
        _ token: CancellationToken?, _ progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        if format.id == "txt" {
            let text = try PDFEngine.pageTexts(source.url).joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OrbitError.unsupported(
                    "\(source.name) has no extractable text (it may be scanned). OCR is not available.")
            }
            let output = staging.newFile(ext: "txt")
            try Data(text.utf8).write(to: output)
            return .single(output, stem: source.stem, ext: "txt", check: .nonEmpty)
        }
        guard let spec = FormatRegistry.imageSpec(id: format.id), capabilities.canWrite(spec) else {
            throw OrbitError.unsupported("This Mac cannot write \(format.ext.uppercased()) images.")
        }
        // 300 dpi unless the caller asks otherwise. An explicit dpi that makes
        // a page exceed the pixel limits is an error; the default is lowered
        // for such a page and the job says so.
        let requestedDPI = try options.double("dpi")
        let dpi = min(max(requestedDPI ?? 300, 36), 600)
        let quality = try options.double("quality")
        let document = try PDFEngine.openForDrawing(source.url)
        let total = document.numberOfPages
        var outputs: [StagedOutput] = []
        var notes: [String] = []
        for number in 1...total {
            try token?.check()
            guard let page = document.page(at: number) else {
                throw OrbitError.malformed("Page \(number) of \(source.name) could not be read.")
            }
            var pageDPI = dpi
            if requestedDPI == nil {
                pageDPI = PDFEngine.fittingDPI(points: PDFEngine.displaySize(page), dpi: dpi)
                if pageDPI < dpi {
                    notes.append("Page \(number) is very large and was rendered at \(Int(pageDPI)) dpi instead of \(Int(dpi)).")
                }
            }
            let output = staging.newFile(ext: spec.ext)
            try ImageEngine.write(try PDFEngine.renderPage(page, dpi: pageDPI), to: output, spec: spec, quality: quality)
            let stem = total == 1 ? source.stem : "\(source.stem)-p\(OrbitEngine.padded(number, of: total))"
            outputs.append(StagedOutput(url: output, stem: stem, ext: spec.ext, check: .image))
            progress?(Double(number) / Double(total))
        }
        return StagedResult(outputs: outputs, notes: notes)
    }

    private func stageMediaConversion(
        _ source: SourceFile, _ format: OutputFormat, _ staging: StagingArea, _ token: CancellationToken?,
        _ progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        if let toolchain = capabilities.media {
            guard let spec = FormatRegistry.mediaSpec(id: format.id), spec.isAvailable(in: toolchain) else {
                throw OrbitError.unsupported("The installed ffmpeg cannot write \(format.ext.uppercased()).")
            }
            return try FFmpegEngine(toolchain: toolchain)
                .convert(source, to: spec, staging: staging, token: token, progress: progress)
        }
        let output = staging.newFile(ext: format.ext)
        let note = "Converted with AVFoundation (ffmpeg not installed)."
        if source.kind == .video {
            try NativeMedia.exportVideo(
                source.url, to: output, fileType: NativeMedia.fileType(forExtension: format.ext),
                token: token, progress: progress)
        } else {
            try NativeMedia.convertAudio(source.url, to: output, formatID: format.id, token: token, progress: progress)
        }
        return .single(output, stem: source.stem, ext: format.ext, check: .media, notes: [note])
    }

    // MARK: Tools

    public func runTool(
        _ id: String, sources urls: [URL], options: ToolOptions = .none, outputDirectory: URL? = nil,
        token: CancellationToken? = nil, progress: ((Double) -> Void)? = nil
    ) throws -> JobResult {
        guard let tool = self.tool(id: id) else {
            throw OrbitError.unsupported("Unknown or unavailable tool: \(id). Run list-tools to see what this Mac offers.")
        }
        let sources = try urls.map { try SourceFile($0) }
        guard !sources.isEmpty else {
            throw OrbitError.invalidInput("No input files.")
        }
        if !tool.combinesInputs && sources.count != 1 {
            throw OrbitError.invalidInput("\(tool.title) takes one file per job.")
        }
        guard sources.count >= tool.minimumInputs else {
            throw OrbitError.invalidInput("\(tool.title) needs at least \(tool.minimumInputs) files.")
        }
        for source in sources {
            guard tool.accepts(kind: source.kind, ext: source.ext) else {
                throw OrbitError.unsupported("\(tool.title) does not apply to \(source.name).")
            }
            try ContentSniffer.verify(source.url, kind: source.kind)
        }
        return try JobRunner.perform(
            sources: sources, outputDirectory: outputDirectory, token: token, validator: validator
        ) { staging in
            try stageTool(tool, sources: sources, options: options, staging: staging, token: token, progress: progress)
        }
    }

    // MARK: Batches

    private static func status(for error: Error) -> JobStatus {
        if let orbit = error as? OrbitError, orbit == .cancelled { return .cancelled }
        return .failed(OrbitError.describe(error))
    }

    /// Runs jobs one after another. Each job is all-or-nothing, but a batch
    /// is partial by design: finished files stay when a later file fails or
    /// the batch is cancelled. `onUpdate` receives source indices and status.
    @discardableResult
    public func runBatch(
        sources: [URL], action: BatchAction, outputDirectory: URL? = nil, token: CancellationToken? = nil,
        onUpdate: (([Int], JobStatus) -> Void)? = nil
    ) -> [JobOutcome] {
        var outcomes: [JobOutcome] = []
        func record(_ indices: [Int], _ status: JobStatus) {
            outcomes.append(JobOutcome(sources: indices.map { sources[$0] }, status: status))
            onUpdate?(indices, status)
        }

        func runEach(_ job: (URL, @escaping (Double) -> Void) throws -> JobStatus) {
            for (index, url) in sources.enumerated() {
                if token?.isCancelled == true {
                    record([index], .cancelled)
                    continue
                }
                onUpdate?([index], .running(nil))
                do {
                    let status = try job(url, { fraction in onUpdate?([index], .running(fraction)) })
                    record([index], status)
                } catch {
                    record([index], OrbitEngine.status(for: error))
                }
            }
        }

        switch action {
        case .convert(let formatName, let options):
            let formatID = FormatRegistry.canonicalID(formatName)
            runEach { url, progress in
                if FormatRegistry.canonicalID(url.pathExtension) == formatID,
                   self.allTargets(forExtension: url.pathExtension).contains(where: { $0.id == formatID }) {
                    return .skipped("Already \(formatID.uppercased()).")
                }
                let result = try self.convert(
                    url, to: formatID, options: options, outputDirectory: outputDirectory, token: token, progress: progress)
                return .succeeded(result)
            }
        case .tool(let id, let options):
            guard let tool = self.tool(id: id) else {
                record(Array(sources.indices), .failed("Unknown or unavailable tool: \(id)."))
                return outcomes
            }
            if tool.combinesInputs {
                let indices = Array(sources.indices)
                onUpdate?(indices, .running(nil))
                do {
                    let result = try runTool(
                        id, sources: sources, options: options, outputDirectory: outputDirectory, token: token,
                        progress: { fraction in onUpdate?(indices, .running(fraction)) })
                    record(indices, .succeeded(result))
                } catch {
                    record(indices, OrbitEngine.status(for: error))
                }
            } else {
                runEach { url, progress in
                    let result = try self.runTool(
                        id, sources: [url], options: options, outputDirectory: outputDirectory, token: token, progress: progress)
                    return .succeeded(result)
                }
            }
        }
        return outcomes
    }

    // MARK: Inspection

    public func inspect(_ url: URL) throws -> FileReport {
        let source = try SourceFile(url)
        var details: [(key: String, value: String)] = []
        switch source.kind {
        case .image:
            if let imageSource = CGImageSourceCreateWithURL(source.url as CFURL, nil), CGImageSourceGetCount(imageSource) > 0 {
                let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
                if let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                   let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                    details.append(("Pixels", "\(width) × \(height)"))
                }
                details.append(("Frames", "\(CGImageSourceGetCount(imageSource))"))
                if let type = CGImageSourceGetType(imageSource) { details.append(("Type", type as String)) }
                let metadataKeys: [(CFString, String)] = [
                    (kCGImagePropertyExifDictionary, "EXIF"), (kCGImagePropertyGPSDictionary, "GPS"),
                    (kCGImagePropertyIPTCDictionary, "IPTC"),
                ]
                let present = metadataKeys.filter { properties[$0.0] != nil }.map { $0.1 }
                details.append(("Metadata", present.isEmpty ? "none found" : present.joined(separator: ", ")))
            } else {
                details.append(("Problem", "not a decodable image"))
            }
        case .pdf:
            if let count = try? PDFEngine.pageCount(source.url) {
                details.append(("Pages", "\(count)"))
            } else {
                details.append(("Problem", "damaged, locked or not a PDF"))
            }
        case .video, .audio:
            var info: MediaInfo?
            if (try? ContentSniffer.verify(source.url, kind: source.kind)) != nil {
                if let toolchain = capabilities.media {
                    info = try? FFmpegEngine(toolchain: toolchain).inspect(source.url)
                } else {
                    info = NativeMedia.probe(source.url)
                }
            }
            if let info {
                details.append(("Container", info.formatName))
                if let duration = info.duration { details.append(("Duration", String(format: "%.2f s", duration))) }
                if info.hasVideo {
                    details.append(("Video", "\(info.videoCodec ?? "yes") \(info.width ?? 0)×\(info.height ?? 0)"))
                }
                if info.hasAudio {
                    details.append(("Audio", "\(info.audioCodec ?? "yes")" + (info.channels.map { ", \($0) ch" } ?? "")))
                }
            } else {
                details.append(("Problem", capabilities.media == nil
                    ? "not readable by AVFoundation (ffmpeg not installed)" : "not readable media"))
            }
        case .subtitle:
            if let text = try? DocumentEngine.readText(source.url),
               let cues = try? SubtitleEngine.parse(text, format: SubtitleEngine.format(forExtension: source.ext, text: text)) {
                details.append(("Cues", "\(cues.count)"))
            } else {
                details.append(("Problem", "no valid subtitle cues"))
            }
        case .archive:
            if let entries = try? ArchiveEngine.list(source.url) {
                details.append(("Entries", "\(entries.count)"))
            } else {
                details.append(("Problem", "not a readable archive"))
            }
        case .document, .unknown:
            break
        }
        return FileReport(
            url: source.url, kind: source.kind, sizeBytes: source.fingerprint.size, details: details,
            targets: targets(for: source.url), tools: tools(for: source.url))
    }
}
