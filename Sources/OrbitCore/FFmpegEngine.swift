import Foundation

public struct MediaInfo: Sendable {
    public var formatName: String
    public var duration: Double?
    public var hasVideo = false
    public var hasAudio = false
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var channels: Int?
    public var videoCodec: String?
    public var audioCodec: String?
}

enum FFprobe {
    /// Demuxers that read other files or the network on behalf of the input.
    static let blockedFormats: Set<String> = [
        "hls", "applehttp", "concat", "sdp", "dash", "rtsp", "rtp", "lavfi", "webm_dash_manifest", "tty",
    ]

    static func arguments(for url: URL) -> [String] {
        ["-v", "error", "-protocol_whitelist", "file,pipe", "-print_format", "json",
         "-show_format", "-show_streams", "-i", url.path]
    }

    static func probe(executable: URL, url: URL) throws -> MediaInfo {
        let result = try ProcessRunner.run(executable, arguments(for: url))
        guard result.status == 0 else {
            throw OrbitError.malformed("\(url.lastPathComponent) is not readable media: \(result.stderrTail)")
        }
        return try parse(result.stdout, name: url.lastPathComponent)
    }

    static func parse(_ data: Data, name: String) throws -> MediaInfo {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = root["format"] as? [String: Any] else {
            throw OrbitError.malformed("\(name) is not readable media.")
        }
        let formatName = (format["format_name"] as? String) ?? ""
        for part in formatName.split(separator: ",") where blockedFormats.contains(String(part)) {
            throw OrbitError.invalidInput("\(name) is a playlist or stream description (\(part)); such inputs are not accepted.")
        }
        var info = MediaInfo(formatName: formatName)
        if let text = format["duration"] as? String, let duration = Double(text),
           duration.isFinite, duration > 0, duration <= ToolOptions.maximumSeconds {
            info.duration = duration
        }
        for stream in (root["streams"] as? [[String: Any]]) ?? [] {
            let type = stream["codec_type"] as? String
            let disposition = stream["disposition"] as? [String: Any]
            let isCoverArt = (disposition?["attached_pic"] as? NSNumber)?.intValue == 1
            if type == "video", !isCoverArt, !info.hasVideo {
                info.hasVideo = true
                info.width = saneDimension((stream["width"] as? NSNumber)?.doubleValue)
                info.height = saneDimension((stream["height"] as? NSNumber)?.doubleValue)
                info.videoCodec = stream["codec_name"] as? String
                info.frameRate = parseRate(stream["avg_frame_rate"] as? String) ?? parseRate(stream["r_frame_rate"] as? String)
            } else if type == "audio", !info.hasAudio {
                info.hasAudio = true
                info.channels = (stream["channels"] as? NSNumber)?.intValue
                info.audioCodec = stream["codec_name"] as? String
            }
        }
        guard info.hasVideo || info.hasAudio else {
            throw OrbitError.malformed("\(name) contains no audio or video.")
        }
        return info
    }

    static func parseRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/")
        guard let numerator = parts.first.flatMap({ Double($0) }) else { return nil }
        let denominator = parts.count > 1 ? (Double(parts[1]) ?? 0) : 1
        guard denominator > 0, numerator > 0 else { return nil }
        let rate = numerator / denominator
        return rate.isFinite && rate <= 1000 ? rate : nil
    }

    /// Frame dimensions outside 1…32768 are treated as unknown.
    static func saneDimension(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 1, value <= 32_768 else { return nil }
        return Int(value)
    }

    // MARK: Inspection without ffprobe

    /// `ffmpeg -i <file>` with no output prints the real stream list to
    /// stderr and exits non-zero; that report is parsed instead of guessing.
    static func bannerArguments(for url: URL) -> [String] {
        ["-nostdin", "-hide_banner", "-protocol_whitelist", "file,pipe", "-i", url.path]
    }

    static func probeWithFFmpeg(executable: URL, url: URL) throws -> MediaInfo {
        let result = try ProcessRunner.run(executable, bannerArguments(for: url))
        return try parseBanner(String(decoding: result.stderr, as: UTF8.self), name: url.lastPathComponent)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func parseBanner(_ text: String, name: String) throws -> MediaInfo {
        var info: MediaInfo?
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Input #0, ") {
                var formatName = String(line.dropFirst("Input #0, ".count))
                if let end = formatName.range(of: ", from ") { formatName = String(formatName[..<end.lowerBound]) }
                for part in formatName.split(separator: ",") where blockedFormats.contains(String(part)) {
                    throw OrbitError.invalidInput(
                        "\(name) is a playlist or stream description (\(part)); such inputs are not accepted.")
                }
                info = MediaInfo(formatName: formatName)
            } else if line.hasPrefix("Duration: "), info != nil {
                let token = line.dropFirst("Duration: ".count).prefix { $0 != "," }
                if let seconds = ToolOptions.parseTime(String(token)), seconds > 0 { info?.duration = seconds }
            } else if line.hasPrefix("Stream #0:"), info != nil {
                if let video = line.range(of: ": Video: "), !line.contains("(attached pic)"), info?.hasVideo == false {
                    info?.hasVideo = true
                    info?.videoCodec = line[video.upperBound...].split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init)
                    if let size = firstMatch(#", (\d{2,5})x(\d{2,5})[ ,\[]"#, in: line + " ") {
                        info?.width = saneDimension(Double(size[1]))
                        info?.height = saneDimension(Double(size[2]))
                    }
                    if let rate = firstMatch(#"([0-9.]+) fps"#, in: line) { info?.frameRate = parseRate(rate[1]) }
                } else if let audio = line.range(of: ": Audio: "), info?.hasAudio == false {
                    info?.hasAudio = true
                    info?.audioCodec = line[audio.upperBound...].split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init)
                    if line.contains(", mono") { info?.channels = 1 } else if line.contains(", stereo") { info?.channels = 2 }
                }
            }
        }
        guard let result = info, result.hasVideo || result.hasAudio else {
            throw OrbitError.malformed("\(name) is not readable media.")
        }
        return result
    }
}

enum QualityLevel: String {
    case standard, high, medium, low

    var crf: Int {
        switch self {
        case .standard: return 20
        case .high: return 23
        case .medium: return 28
        case .low: return 33
        }
    }

    var bitrateFactor: Double {
        switch self {
        case .standard: return 1.0
        case .high: return 0.6
        case .medium: return 0.35
        case .low: return 0.2
        }
    }
}

struct EncodeRequest {
    /// Output-side `-ss` / `-t` arguments (frame accurate).
    var timing: [String] = []
    var videoFilters: [String] = []
    var audioFilters: [String] = []
    var level: QualityLevel = .standard
    var audioBitrateKbps: Int?
    var expectedDuration: Double?
}

/// Media work through an externally installed ffmpeg. Every invocation uses
/// an argument array, `-nostdin`, and a `file,pipe` protocol whitelist on
/// each input; outputs are relative names inside the job's staging directory.
struct FFmpegEngine {
    let toolchain: MediaToolchain

    // MARK: Argument builders

    static func globalArguments() -> [String] {
        ["-nostdin", "-hide_banner", "-loglevel", "error", "-nostats"]
    }

    static func inputArguments(_ url: URL, seek: Double? = nil) -> [String] {
        var arguments = ["-protocol_whitelist", "file,pipe"]
        if let seek { arguments += ["-ss", formatTime(seek)] }
        return arguments + ["-i", url.path]
    }

    static func outputArguments(muxer: String, name: String) -> [String] {
        ["-progress", "pipe:1", "-n", "-f", muxer, name]
    }

    static func formatTime(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    /// `atempo` accepts 0.5–2.0 per instance, so larger changes are chained.
    static func tempoChain(_ factor: Double) -> [String] {
        var remaining = factor
        var filters: [String] = []
        while remaining > 2.0 {
            filters.append("atempo=2.0")
            remaining /= 2.0
        }
        while remaining < 0.5 {
            filters.append("atempo=0.5")
            remaining /= 0.5
        }
        filters.append(String(format: "atempo=%.4f", remaining))
        return filters
    }

    static func hardwareBitrate(info: MediaInfo?, factor: Double) -> String {
        let width = Double(info?.width ?? 1920), height = Double(info?.height ?? 1080)
        let rate = min(max(info?.frameRate ?? 30, 1), 120)
        let bitsPerSecond = min(max(width * height * rate * 0.1 * factor, 500_000), 60_000_000)
        return "\(Int(bitsPerSecond / 1000))k"
    }

    static func needsEvenDimensions(_ encoder: String) -> Bool {
        ["h264_videotoolbox", "libx264", "mpeg4"].contains(encoder)
    }

    static func videoArguments(encoder: String, level: QualityLevel, info: MediaInfo?) -> [String] {
        switch encoder {
        case "h264_videotoolbox":
            return ["-c:v", encoder, "-b:v", hardwareBitrate(info: info, factor: level.bitrateFactor), "-pix_fmt", "yuv420p"]
        case "libx264":
            return ["-c:v", encoder, "-preset", "medium", "-crf", String(level.crf), "-pix_fmt", "yuv420p"]
        case "mpeg4":
            return ["-c:v", encoder, "-q:v", level == .standard ? "4" : "8"]
        case "libvpx-vp9":
            return ["-c:v", encoder, "-crf", String(level.crf + 12), "-b:v", "0"]
        case "libvpx":
            return ["-c:v", encoder, "-crf", "10", "-b:v", level == .standard ? "2M" : "1M"]
        default:
            return ["-c:v", encoder]
        }
    }

    static func audioArguments(encoder: String, bitrateKbps: Int?) -> [String] {
        switch encoder {
        case "aac", "aac_at":
            return ["-c:a", encoder, "-b:a", "\(bitrateKbps ?? 192)k"]
        case "libmp3lame":
            return bitrateKbps.map { ["-c:a", encoder, "-b:a", "\($0)k"] } ?? ["-c:a", encoder, "-q:a", "2"]
        case "libvorbis":
            return bitrateKbps.map { ["-c:a", encoder, "-b:a", "\($0)k"] } ?? ["-c:a", encoder, "-q:a", "5"]
        case "libopus":
            return ["-c:a", encoder, "-b:a", "\(bitrateKbps ?? 128)k"]
        default:
            return ["-c:a", encoder]
        }
    }

    /// Filter graph that silences the given ranges and mixes in a tone there.
    static func bleepFilter(ranges: [(start: Double, end: Double)], frequency: Int) -> String {
        let expression = ranges
            .map { "between(t,\(formatTime($0.start)),\(formatTime($0.end)))" }
            .joined(separator: "+")
        return "[0:a:0]volume=0:enable='\(expression)'[voice];"
            + "sine=frequency=\(frequency):sample_rate=48000[tone];"
            + "[tone]volume=0:enable='not(\(expression))'[beep];"
            + "[voice][beep]amix=inputs=2:duration=first:normalize=0[out]"
    }

    static func progressSeconds(fromLine line: String) -> Double? {
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            if let value = Double(line.dropFirst(key.count)) { return value / 1_000_000 }
        }
        return nil
    }

    // MARK: Running

    func run(
        _ arguments: [String], in directory: URL, duration: Double?, token: CancellationToken?,
        progress: ((Double) -> Void)?
    ) throws {
        let result = try ProcessRunner.run(
            toolchain.ffmpeg, arguments, currentDirectory: directory, token: token,
            onStdoutLine: { line in
                guard let progress, let duration, duration > 0,
                      let seconds = FFmpegEngine.progressSeconds(fromLine: line) else { return }
                progress(min(max(seconds / duration, 0), 1))
            })
        guard result.status == 0 else {
            throw OrbitError.engineFailure("ffmpeg failed: \(result.stderrTail)")
        }
    }

    /// Reads the actual streams of a file: ffprobe when installed, otherwise
    /// ffmpeg's own stream report. Playlist-style formats are rejected.
    func inspect(_ url: URL) throws -> MediaInfo {
        if let probe = toolchain.ffprobe {
            return try FFprobe.probe(executable: probe, url: url)
        }
        return try FFprobe.probeWithFFmpeg(executable: toolchain.ffmpeg, url: url)
    }

    /// Always returns real stream information; nothing about the input's
    /// audio or video is assumed.
    func inspectInput(_ source: SourceFile) throws -> MediaInfo? {
        try inspect(source.url)
    }

    /// Builds an ffmpeg crop filter after checking the rectangle is finite,
    /// representable and inside the probed frame.
    static func cropFilter(rect: CGRect, info: MediaInfo?) throws -> String {
        let values = [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 32_768 }), rect.width >= 2, rect.height >= 2 else {
            throw OrbitError.invalidOptions("The crop rectangle must use sizes between 2 and 32768 pixels.")
        }
        let x = Int(rect.minX), y = Int(rect.minY), width = Int(rect.width), height = Int(rect.height)
        if let frameWidth = info?.width, let frameHeight = info?.height {
            guard x + width <= frameWidth, y + height <= frameHeight else {
                throw OrbitError.invalidOptions(
                    "The crop rectangle \(width)×\(height) at \(x),\(y) does not fit inside the \(frameWidth)×\(frameHeight) video.")
            }
        }
        return "crop=\(width):\(height):\(x):\(y)"
    }

    /// Tries each available video encoder in order of preference and records
    /// any fallback as a note. `build` receives the encoder to use.
    private func runWithEncoderFallback(
        spec: MediaFormatSpec, needsVideoEncoder: Bool, output: URL, directory: URL, duration: Double?,
        token: CancellationToken?, progress: ((Double) -> Void)?, build: (String?) -> [String]
    ) throws -> [String] {
        guard needsVideoEncoder else {
            try run(build(nil), in: directory, duration: duration, token: token, progress: progress)
            return []
        }
        let candidates = spec.videoEncoders.filter(toolchain.encoders.contains)
        guard !candidates.isEmpty else {
            throw OrbitError.unsupported("The installed ffmpeg has no encoder for \(spec.ext.uppercased()).")
        }
        var notes: [String] = []
        if spec.videoEncoders.first == "h264_videotoolbox", candidates[0] != "h264_videotoolbox" {
            notes.append("Hardware H.264 (h264_videotoolbox) is not available in this ffmpeg; used \(candidates[0]).")
        }
        var lastError: Error = OrbitError.engineFailure("ffmpeg failed.")
        for (index, encoder) in candidates.enumerated() {
            try? FileManager.default.removeItem(at: output)
            do {
                try run(build(encoder), in: directory, duration: duration, token: token, progress: progress)
                if index > 0 {
                    notes.append("\(candidates[0]) failed on this file; fell back to \(encoder).")
                }
                return notes
            } catch OrbitError.cancelled {
                throw OrbitError.cancelled
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func audioEncoder(for spec: MediaFormatSpec) -> String? {
        spec.audioEncoders.first(where: toolchain.encoders.contains)
    }

    /// The container to use when a tool re-encodes: the source's own if this
    /// ffmpeg can write it, otherwise MP4 / M4A.
    func reencodeSpec(for source: SourceFile) throws -> MediaFormatSpec {
        let isVideo = source.kind == .video
        if let own = FormatRegistry.mediaSpec(id: FormatRegistry.canonicalID(source.ext)),
           own.isVideo == isVideo, own.id != "gif", own.isAvailable(in: toolchain) {
            return own
        }
        guard let fallback = FormatRegistry.mediaSpec(id: isVideo ? "mp4" : "m4a"), fallback.isAvailable(in: toolchain) else {
            throw OrbitError.unsupported("The installed ffmpeg cannot encode a suitable output for \(source.name).")
        }
        return fallback
    }

    /// The container to use for stream copies: the source's own, or Matroska
    /// for video containers this build cannot name.
    func copySpec(for source: SourceFile) throws -> MediaFormatSpec {
        let isVideo = source.kind == .video
        if let own = FormatRegistry.mediaSpec(id: FormatRegistry.canonicalID(source.ext)),
           own.isVideo == isVideo, toolchain.muxers.contains(own.muxer) {
            return own
        }
        if isVideo, let matroska = FormatRegistry.mediaSpec(id: "mkv"), toolchain.muxers.contains(matroska.muxer) {
            return matroska
        }
        throw OrbitError.unsupported("Stream copy is not supported for .\(source.ext) files.")
    }

    // MARK: Encoding operations

    func encode(
        _ source: SourceFile, spec: MediaFormatSpec, request: EncodeRequest, staging: StagingArea, suffix: String?,
        token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        let info = try inspectInput(source)
        let sourceHasVideo = info?.hasVideo ?? (source.kind == .video)
        let sourceHasAudio = info?.hasAudio ?? true
        if spec.isVideo && !sourceHasVideo {
            throw OrbitError.unsupported("\(source.name) has no video track.")
        }
        if !spec.isVideo && !sourceHasAudio {
            throw OrbitError.unsupported("\(source.name) has no audio track.")
        }
        let audioEncoder = self.audioEncoder(for: spec)
        // Sound is never dropped silently: a container that carries audio
        // needs an encoder for it. GIF has no audio by definition and says so.
        if spec.isVideo && sourceHasAudio && !spec.audioEncoders.isEmpty && audioEncoder == nil {
            throw OrbitError.unsupported(
                "The installed ffmpeg has no audio encoder for \(spec.ext.uppercased()), so the sound of \(source.name) would be lost.")
        }
        let includeAudio = sourceHasAudio && audioEncoder != nil
        let output = staging.newFile(ext: spec.ext)

        var notes = try runWithEncoderFallback(
            spec: spec, needsVideoEncoder: spec.isVideo, output: output, directory: staging.directory,
            duration: request.expectedDuration ?? info?.duration, token: token, progress: progress
        ) { encoder in
            var arguments = FFmpegEngine.globalArguments() + FFmpegEngine.inputArguments(source.url) + request.timing
            if spec.isVideo, let encoder {
                arguments += ["-map", "0:v:0"]
                arguments += includeAudio ? ["-map", "0:a:0"] : ["-an"]
                var filters = request.videoFilters
                if FFmpegEngine.needsEvenDimensions(encoder) {
                    filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
                }
                if !filters.isEmpty { arguments += ["-vf", filters.joined(separator: ",")] }
                arguments += FFmpegEngine.videoArguments(encoder: encoder, level: request.level, info: info)
                if spec.id == "mp4" || spec.id == "mov" { arguments += ["-movflags", "+faststart"] }
            } else {
                arguments += ["-map", "0:a:0", "-vn"]
            }
            if includeAudio, let audioEncoder {
                if !request.audioFilters.isEmpty { arguments += ["-af", request.audioFilters.joined(separator: ",")] }
                arguments += FFmpegEngine.audioArguments(encoder: audioEncoder, bitrateKbps: request.audioBitrateKbps)
            }
            return arguments + ["-sn", "-dn"] + FFmpegEngine.outputArguments(muxer: spec.muxer, name: output.lastPathComponent)
        }
        if spec.isVideo && sourceHasAudio && spec.audioEncoders.isEmpty {
            notes.append("\(spec.ext.uppercased()) cannot carry sound; the audio track was left out.")
        }
        let stem = suffix.map { "\(source.stem)-\($0)" } ?? source.stem
        return .single(output, stem: stem, ext: spec.ext, check: .media, notes: notes)
    }

    func convert(
        _ source: SourceFile, to spec: MediaFormatSpec, staging: StagingArea, token: CancellationToken?,
        progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        var request = EncodeRequest()
        if spec.id == "gif" {
            request.videoFilters = [
                "fps=12", "scale='min(480,iw)':-2:flags=lanczos",
                "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
            ]
        }
        return try encode(source, spec: spec, request: request, staging: staging, suffix: nil, token: token, progress: progress)
    }

    func compress(
        _ source: SourceFile, options: ToolOptions, staging: StagingArea, token: CancellationToken?,
        progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        let levelName = options.string("quality") ?? "medium"
        guard let level = QualityLevel(rawValue: levelName), level != .standard else {
            throw OrbitError.invalidOptions("Quality must be high, medium or low.")
        }
        var request = EncodeRequest()
        request.level = level
        let spec: MediaFormatSpec
        if source.kind == .video {
            spec = try reencodeSpec(for: source)
            if let maxHeight = try options.int("maxHeight") {
                guard (16...8640).contains(maxHeight) else {
                    throw OrbitError.invalidOptions("Max video height must be between 16 and 8640 pixels.")
                }
                request.videoFilters = ["scale=-2:'min(ih,\(maxHeight))'"]
            }
            request.audioBitrateKbps = try options.int("audioBitrate") ?? 128
        } else {
            // Lossless or unknown audio is compressed to a lossy container.
            let lossy = ["mp3", "m4a", "ogg", "opus"]
            let own = FormatRegistry.canonicalID(source.ext)
            let candidates = (lossy.contains(own) ? [own] : []) + ["m4a", "mp3", "ogg"]
            guard let chosen = candidates.compactMap({ FormatRegistry.mediaSpec(id: $0) })
                .first(where: { $0.isAvailable(in: toolchain) }) else {
                throw OrbitError.unsupported("The installed ffmpeg has no lossy audio encoder.")
            }
            spec = chosen
            let defaults: [QualityLevel: Int] = [.high: 160, .medium: 112, .low: 64]
            request.audioBitrateKbps = try options.int("audioBitrate") ?? defaults[level] ?? 112
        }
        if let bitrate = request.audioBitrateKbps, !(8...512).contains(bitrate) {
            throw OrbitError.invalidOptions("Audio bitrate must be between 8 and 512 kbps.")
        }
        return try encode(source, spec: spec, request: request, staging: staging, suffix: "compressed", token: token, progress: progress)
    }

    func trim(
        _ source: SourceFile, start: Double, end: Double?, precise: Bool, staging: StagingArea,
        token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        if let end, end <= start {
            throw OrbitError.invalidOptions("The end time must be after the start time.")
        }
        let length = end.map { $0 - start }
        if precise {
            var request = EncodeRequest()
            request.timing = ["-ss", FFmpegEngine.formatTime(start)]
            if let length { request.timing += ["-t", FFmpegEngine.formatTime(length)] }
            request.expectedDuration = length
            return try encode(source, spec: try reencodeSpec(for: source), request: request, staging: staging,
                              suffix: "trimmed", token: token, progress: progress)
        }
        _ = try inspectInput(source)
        let spec = try copySpec(for: source)
        let output = staging.newFile(ext: spec.ext)
        var arguments = FFmpegEngine.globalArguments() + FFmpegEngine.inputArguments(source.url, seek: start)
        if let length { arguments += ["-t", FFmpegEngine.formatTime(length)] }
        arguments += ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero", "-sn", "-dn"]
        arguments += FFmpegEngine.outputArguments(muxer: spec.muxer, name: output.lastPathComponent)
        try run(arguments, in: staging.directory, duration: length, token: token, progress: progress)
        return .single(output, stem: "\(source.stem)-trimmed", ext: spec.ext, check: .media,
                       notes: ["Stream copy cuts at the nearest keyframes, so the start may be slightly early."])
    }

    func crop(
        _ source: SourceFile, rect: CGRect, staging: StagingArea, token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        var request = EncodeRequest()
        request.videoFilters = [try FFmpegEngine.cropFilter(rect: rect, info: try inspectInput(source))]
        return try encode(source, spec: try reencodeSpec(for: source), request: request, staging: staging,
                          suffix: "cropped", token: token, progress: progress)
    }

    func speed(
        _ source: SourceFile, factor: Double, staging: StagingArea, token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        guard (0.25...4).contains(factor) else {
            throw OrbitError.invalidOptions("Speed factor must be between 0.25 and 4.")
        }
        var request = EncodeRequest()
        if source.kind == .video { request.videoFilters = [String(format: "setpts=PTS/%.4f", factor)] }
        request.audioFilters = FFmpegEngine.tempoChain(factor)
        let info = try inspectInput(source)
        request.expectedDuration = info?.duration.map { $0 / factor }
        return try encode(source, spec: try reencodeSpec(for: source), request: request, staging: staging,
                          suffix: "speed", token: token, progress: progress)
    }

    // MARK: Stream-copy operations

    private func copyOperation(
        _ source: SourceFile, suffix: String, extra: [String], staging: StagingArea, token: CancellationToken?,
        progress: ((Double) -> Void)?, notes: [String] = []
    ) throws -> StagedResult {
        let info = try inspectInput(source)
        let spec = try copySpec(for: source)
        let output = staging.newFile(ext: spec.ext)
        let arguments = FFmpegEngine.globalArguments() + FFmpegEngine.inputArguments(source.url) + extra
            + ["-sn", "-dn"] + FFmpegEngine.outputArguments(muxer: spec.muxer, name: output.lastPathComponent)
        try run(arguments, in: staging.directory, duration: info?.duration, token: token, progress: progress)
        return .single(output, stem: "\(source.stem)-\(suffix)", ext: spec.ext, check: .media, notes: notes)
    }

    func mute(
        _ source: SourceFile, staging: StagingArea, token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        try copyOperation(source, suffix: "muted", extra: ["-map", "0:v:0", "-c:v", "copy", "-an"],
                          staging: staging, token: token, progress: progress)
    }

    func stripMetadata(
        _ source: SourceFile, staging: StagingArea, token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        try copyOperation(
            source, suffix: "clean",
            extra: ["-map", "0:v?", "-map", "0:a?", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy",
                    "-fflags", "+bitexact"],
            staging: staging, token: token, progress: progress,
            notes: ["Container tags and chapters were removed; audio and video streams were copied unchanged."])
    }

    func snapshot(
        _ source: SourceFile, at time: Double, staging: StagingArea, token: CancellationToken?
    ) throws -> StagedResult {
        _ = try inspectInput(source)
        let output = staging.newFile(ext: "png")
        let arguments = FFmpegEngine.globalArguments() + FFmpegEngine.inputArguments(source.url, seek: time)
            + ["-map", "0:v:0", "-frames:v", "1", "-update", "1", "-n", "-f", "image2", output.lastPathComponent]
        try run(arguments, in: staging.directory, duration: nil, token: token, progress: nil)
        return .single(output, stem: "\(source.stem)-snapshot", ext: "png", check: .image)
    }

    func split(
        _ source: SourceFile, segmentSeconds: Double, staging: StagingArea, token: CancellationToken?,
        progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        guard segmentSeconds.isFinite, segmentSeconds >= 1, segmentSeconds <= ToolOptions.maximumSeconds else {
            throw OrbitError.invalidOptions("Segment length must be at least 1 second.")
        }
        guard toolchain.muxers.contains("segment") else {
            throw OrbitError.unsupported("The installed ffmpeg lacks the segment muxer.")
        }
        let info = try inspectInput(source)
        let spec = try copySpec(for: source)
        // The pattern is a relative name in a private folder, so a "%" in the
        // user's own folder names can never be read as a pattern.
        let parts = try staging.subdirectory(named: "parts")
        let arguments = FFmpegEngine.globalArguments() + FFmpegEngine.inputArguments(source.url)
            + ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-sn", "-dn", "-progress", "pipe:1",
               "-f", "segment", "-segment_format", spec.muxer, "-segment_time", FFmpegEngine.formatTime(segmentSeconds),
               "-reset_timestamps", "1", "part-%04d.\(spec.ext)"]
        try run(arguments, in: parts, duration: info?.duration, token: token, progress: progress)
        let files = try FileManager.default.contentsOfDirectory(at: parts, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let outputs = files.enumerated().map { index, url in
            StagedOutput(url: url, stem: String(format: "%@-part%02d", source.stem, index + 1), ext: spec.ext, check: .media)
        }
        return StagedResult(outputs: outputs,
                            notes: ["Segments are cut at keyframes without re-encoding, so lengths are approximate."])
    }

    // MARK: Audio operations

    /// Re-encodes the audio through a filter. For videos the picture is
    /// copied untouched into the same container.
    func audioEdit(
        _ source: SourceFile, suffix: String, filters: [String] = [], filterComplex: String? = nil,
        extra: [String] = [], staging: StagingArea, token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        let info = try inspectInput(source)
        guard info?.hasAudio ?? true else {
            throw OrbitError.unsupported("\(source.name) has no audio track.")
        }
        let isVideo = source.kind == .video
        let spec = try (isVideo ? copySpec(for: source) : reencodeSpec(for: source))
        guard let encoder = audioEncoder(for: spec) else {
            throw OrbitError.unsupported("The installed ffmpeg has no audio encoder for \(spec.ext.uppercased()).")
        }
        let output = staging.newFile(ext: spec.ext)
        var arguments = FFmpegEngine.globalArguments() + FFmpegEngine.inputArguments(source.url)
        if let filterComplex {
            arguments += ["-filter_complex", filterComplex, "-map", "[out]"]
        } else {
            arguments += ["-map", "0:a:0"]
            if !filters.isEmpty { arguments += ["-af", filters.joined(separator: ",")] }
        }
        arguments += isVideo ? ["-map", "0:v:0", "-c:v", "copy"] : ["-vn"]
        arguments += FFmpegEngine.audioArguments(encoder: encoder, bitrateKbps: nil) + extra + ["-sn", "-dn"]
        arguments += FFmpegEngine.outputArguments(muxer: spec.muxer, name: output.lastPathComponent)
        try run(arguments, in: staging.directory, duration: info?.duration, token: token, progress: progress)
        return .single(output, stem: "\(source.stem)-\(suffix)", ext: spec.ext, check: .media)
    }

    /// Joins clips end to end with the concat *filter* (no script files),
    /// re-encoding to the first clip's container and frame size.
    func join(
        _ sources: [SourceFile], staging: StagingArea, token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws -> StagedResult {
        let first = sources[0]
        let isVideo = first.kind == .video
        guard sources.allSatisfy({ $0.kind == first.kind }) else {
            throw OrbitError.unsupported("Join needs files of one kind: all video or all audio.")
        }
        let infos = try sources.map { try inspectInput($0) }
        let spec = try reencodeSpec(for: first)
        let audioEncoder = self.audioEncoder(for: spec)
        let withAudio = infos.map { $0?.hasAudio ?? true }
        if isVideo && withAudio.contains(true) && withAudio.contains(false) {
            throw OrbitError.unsupported("Join cannot mix clips with and without sound.")
        }
        if withAudio[0] && audioEncoder == nil {
            throw OrbitError.unsupported(
                "The installed ffmpeg has no audio encoder for \(spec.ext.uppercased()), so the clips' sound would be lost.")
        }
        let includeAudio = withAudio[0]

        var graph = ""
        var concatInputs = ""
        if isVideo {
            let width = max(2, (infos[0]?.width ?? 1280) / 2 * 2)
            let height = max(2, (infos[0]?.height ?? 720) / 2 * 2)
            let rate = Int(min(max((infos[0]?.frameRate ?? 30).rounded(), 1), 60))
            for index in sources.indices {
                graph += "[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                    + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(rate)[v\(index)];"
                concatInputs += "[v\(index)]"
                if includeAudio {
                    graph += "[\(index):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)];"
                    concatInputs += "[a\(index)]"
                }
            }
            graph += "\(concatInputs)concat=n=\(sources.count):v=1:a=\(includeAudio ? 1 : 0)[v]" + (includeAudio ? "[a]" : "")
        } else {
            for index in sources.indices {
                graph += "[\(index):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)];"
                concatInputs += "[a\(index)]"
            }
            graph += "\(concatInputs)concat=n=\(sources.count):v=0:a=1[a]"
        }

        let durations = infos.compactMap { $0?.duration }
        let total = durations.count == sources.count ? durations.reduce(0, +) : nil
        let output = staging.newFile(ext: spec.ext)
        let notes = try runWithEncoderFallback(
            spec: spec, needsVideoEncoder: isVideo, output: output, directory: staging.directory, duration: total,
            token: token, progress: progress
        ) { encoder in
            var arguments = FFmpegEngine.globalArguments()
            for source in sources { arguments += FFmpegEngine.inputArguments(source.url) }
            arguments += ["-filter_complex", graph]
            if isVideo, let encoder {
                arguments += ["-map", "[v]"] + FFmpegEngine.videoArguments(encoder: encoder, level: .standard, info: infos[0])
                if spec.id == "mp4" || spec.id == "mov" { arguments += ["-movflags", "+faststart"] }
            }
            if (includeAudio || !isVideo), let audioEncoder {
                arguments += ["-map", "[a]"] + FFmpegEngine.audioArguments(encoder: audioEncoder, bitrateKbps: nil)
            }
            return arguments + FFmpegEngine.outputArguments(muxer: spec.muxer, name: output.lastPathComponent)
        }
        return .single(output, stem: "\(first.stem)-joined", ext: spec.ext, check: .media, notes: notes)
    }
}
