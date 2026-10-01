import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var lines: [String]

    public init(startMs: Int, endMs: Int, lines: [String]) {
        self.startMs = startMs
        self.endMs = endMs
        self.lines = lines
    }
}

public enum SubtitleFormat: String, Sendable {
    case srt, vtt
}

/// Structure-aware SRT / WebVTT conversion: cues are parsed into timed
/// records and re-serialized, rather than rewritten with text substitution.
public enum SubtitleEngine {
    /// Parses `HH:MM:SS,mmm`, `HH:MM:SS.mmm` or `MM:SS.mmm` into milliseconds.
    public static func parseTimestamp(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        func number(_ digits: Substring) -> Int? {
            guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(digits)
        }

        let secondParts = parts[parts.count - 1]
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
        guard secondParts.count == 1 || secondParts.count == 2,
              let seconds = number(secondParts[0]), seconds < 60,
              let minutes = number(parts[parts.count - 2]), minutes < 60 else { return nil }

        var millis = 0
        if secondParts.count == 2 {
            let fraction = secondParts[1].prefix(3)
            guard let value = number(fraction) else { return nil }
            millis = value * [100, 10, 1][fraction.count - 1]
        }
        var hours = 0
        if parts.count == 3 {
            guard let value = number(parts[0]) else { return nil }
            hours = value
        }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    public static func formatTimestamp(_ milliseconds: Int, format: SubtitleFormat) -> String {
        let clamped = max(milliseconds, 0)
        return String(
            format: "%02d:%02d:%02d%@%03d",
            clamped / 3_600_000, (clamped / 60_000) % 60, (clamped / 1000) % 60,
            format == .srt ? "," : ".", clamped % 1000)
    }

    public static func format(forExtension ext: String, text: String) -> SubtitleFormat {
        if ext.lowercased() == "vtt" { return .vtt }
        if ext.lowercased() == "srt" { return .srt }
        return text.hasPrefix("WEBVTT") || text.hasPrefix("\u{FEFF}WEBVTT") ? .vtt : .srt
    }

    public static func parse(_ text: String, format: SubtitleFormat) throws -> [SubtitleCue] {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }

        var blocks: [[String]] = []
        var current: [String] = []
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { blocks.append(current) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        var cues: [SubtitleCue] = []
        for block in blocks {
            guard let timingIndex = block.prefix(2).firstIndex(where: { $0.contains("-->") }) else {
                // SRT text may contain blank lines; keep such text with its cue.
                // WebVTT header, NOTE, STYLE and REGION blocks are skipped.
                if format == .srt, !cues.isEmpty {
                    cues[cues.count - 1].lines.append(contentsOf: block)
                }
                continue
            }
            let timing = block[timingIndex]
            let sides = timing.components(separatedBy: "-->")
            guard sides.count == 2,
                  let start = parseTimestamp(sides[0]),
                  let endToken = sides[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  let end = parseTimestamp(String(endToken)),
                  end >= start else {
                throw OrbitError.malformed("Invalid subtitle timing line: \"\(timing)\"")
            }
            cues.append(SubtitleCue(startMs: start, endMs: end, lines: Array(block[(timingIndex + 1)...])))
        }
        guard !cues.isEmpty else {
            throw OrbitError.malformed("No subtitle cues were found.")
        }
        return cues
    }

    private static func strip(_ pattern: String, from line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        return regex.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
    }

    /// Removes WebVTT-only tags (voice, class, timestamps) but keeps i/b/u.
    static func srtSafe(_ line: String) -> String {
        strip("<(?!/?(?:i|b|u)>)[^>]+>", from: line)
    }

    static func withoutTags(_ line: String) -> String {
        strip("<[^>]+>", from: line)
    }

    public static func serialize(_ cues: [SubtitleCue], format: SubtitleFormat) -> String {
        var output = format == .vtt ? "WEBVTT\n\n" : ""
        for (index, cue) in cues.enumerated() {
            if format == .srt { output += "\(index + 1)\n" }
            output += formatTimestamp(cue.startMs, format: format) + " --> " + formatTimestamp(cue.endMs, format: format) + "\n"
            let lines = format == .srt ? cue.lines.map(srtSafe) : cue.lines
            output += lines.joined(separator: "\n") + "\n\n"
        }
        return output
    }

    public static func plainText(_ cues: [SubtitleCue]) -> String {
        cues.map { cue in cue.lines.map(withoutTags).joined(separator: "\n") }.joined(separator: "\n") + "\n"
    }

    /// Shifts every cue; cues that would end at or before zero are dropped.
    public static func shift(_ cues: [SubtitleCue], byMilliseconds offset: Int) -> [SubtitleCue] {
        cues.compactMap { cue in
            let end = cue.endMs + offset
            guard end > 0 else { return nil }
            return SubtitleCue(startMs: max(cue.startMs + offset, 0), endMs: end, lines: cue.lines)
        }
    }
}
