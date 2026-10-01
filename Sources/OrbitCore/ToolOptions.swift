import Foundation
import CoreGraphics

/// Loosely typed option bag shared by the CLI (`--options JSON`), the GUI
/// parameter sheet and tests. Values may be JSON numbers or numeric strings.
public struct ToolOptions: @unchecked Sendable {
    public private(set) var values: [String: Any]

    public static let none = ToolOptions()

    public init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    public init(json: String) throws {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.values = [:]
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw OrbitError.invalidOptions("Options must be a JSON object, for example {\"quality\": 0.6}.")
        }
        self.values = dictionary
    }

    private func raw(_ key: String) -> Any? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        if let text = value as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return value
    }

    public func has(_ key: String) -> Bool {
        raw(key) != nil
    }

    public func double(_ key: String) throws -> Double? {
        guard let value = raw(key) else { return nil }
        if let text = value as? String {
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else {
                throw OrbitError.invalidOptions("Option \"\(key)\" must be a number.")
            }
            return number
        }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
        throw OrbitError.invalidOptions("Option \"\(key)\" must be a number.")
    }

    public func int(_ key: String) throws -> Int? {
        guard let number = try double(key) else { return nil }
        guard number == number.rounded(), abs(number) < 1e9 else {
            throw OrbitError.invalidOptions("Option \"\(key)\" must be a whole number.")
        }
        return Int(number)
    }

    public func string(_ key: String) -> String? {
        guard let value = raw(key) else { return nil }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = raw(key) else { return nil }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return nil
            }
        }
        return (value as? NSNumber)?.boolValue
    }

    /// Seconds, given as a number or as `MM:SS(.fff)` / `HH:MM:SS(.fff)`.
    public func time(_ key: String) throws -> Double? {
        guard let value = raw(key) else { return nil }
        if let text = value as? String {
            guard let seconds = ToolOptions.parseTime(text) else {
                throw OrbitError.invalidOptions("Option \"\(key)\" must be a time in seconds or HH:MM:SS.")
            }
            return seconds
        }
        guard let seconds = try double(key) else { return nil }
        guard seconds >= 0, seconds <= ToolOptions.maximumSeconds else {
            throw OrbitError.invalidOptions("Option \"\(key)\" must be a time between 0 and \(Int(ToolOptions.maximumSeconds)) seconds.")
        }
        return seconds
    }

    /// Upper bound for any time value (about 115 days), far beyond real media.
    static let maximumSeconds = 10_000_000.0

    /// Plain seconds (`90`, `1.5`), `MM:SS(.fff)` or `HH:MM:SS(.fff)`. With
    /// colons, hours and minutes must be whole and minutes/seconds below 60.
    public static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var values: [Double] = []
        for part in parts {
            guard let first = part.first, first.isNumber || first == ".",
                  let value = Double(part), value.isFinite, value >= 0 else { return nil }
            values.append(value)
        }
        if values.count > 1 {
            for (index, value) in values.enumerated() {
                if index < values.count - 1, value != value.rounded() { return nil }
                if index > 0, value >= 60 { return nil }
            }
        }
        let total = values.reduce(0) { $0 * 60 + $1 }
        return total <= maximumSeconds ? total : nil
    }

    /// Rectangles as `[[x, y, w, h]]`, `[{"x":..,"y":..,"width":..,"height":..}]`
    /// or the string form `"x,y,w,h; x,y,w,h"`. Origin is the top-left corner.
    public func rects(_ key: String) throws -> [CGRect] {
        guard let value = raw(key) else { return [] }
        let failure = OrbitError.invalidOptions(
            "Option \"\(key)\" must list rectangles as x,y,width,height separated by semicolons.")
        var quads: [[Double]] = []
        if let text = value as? String {
            for part in text.split(whereSeparator: { $0 == ";" || $0 == "\n" }) {
                let numbers = part.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard numbers.count == 4, !numbers.contains(where: { $0 == nil }) else { throw failure }
                quads.append(numbers.compactMap { $0 })
            }
        } else if let list = value as? [Any] {
            for item in list {
                if let numbers = item as? [NSNumber], numbers.count == 4 {
                    quads.append(numbers.map { $0.doubleValue })
                } else if let dictionary = item as? [String: NSNumber],
                          let x = dictionary["x"], let y = dictionary["y"],
                          let width = dictionary["width"], let height = dictionary["height"] {
                    quads.append([x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue])
                } else {
                    throw failure
                }
            }
        } else {
            throw failure
        }
        return try quads.map { quad in
            guard quad[2] > 0, quad[3] > 0, quad.allSatisfy({ $0.isFinite }) else { throw failure }
            return CGRect(x: quad[0], y: quad[1], width: quad[2], height: quad[3])
        }
    }

    /// Time ranges as `[[start, end]]` or the string form `"1.5-2.5; 7-8"`.
    public func timeRanges(_ key: String) throws -> [(start: Double, end: Double)] {
        guard let value = raw(key) else { return [] }
        let failure = OrbitError.invalidOptions(
            "Option \"\(key)\" must list time ranges as start-end separated by semicolons, for example 1.5-2.5; 7-8.")
        var ranges: [(start: Double, end: Double)] = []
        if let text = value as? String {
            for part in text.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "\n" }) {
                let ends = part.split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count == 2,
                      let start = ToolOptions.parseTime(String(ends[0])),
                      let end = ToolOptions.parseTime(String(ends[1])) else { throw failure }
                ranges.append((start, end))
            }
        } else if let list = value as? [Any] {
            for item in list {
                guard let numbers = item as? [NSNumber], numbers.count == 2 else { throw failure }
                ranges.append((numbers[0].doubleValue, numbers[1].doubleValue))
            }
        } else {
            throw failure
        }
        for range in ranges {
            guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end > range.start,
                  range.end <= ToolOptions.maximumSeconds else { throw failure }
        }
        return ranges
    }
}

/// Parser for 1-based page selections such as `"3,1-2"`.
public enum PageRanges {
    /// Each comma-separated group becomes one list: `"1-3,5"` -> `[[1,2,3],[5]]`.
    public static func parseGroups(_ text: String, pageCount: Int) throws -> [[Int]] {
        guard pageCount > 0 else {
            throw OrbitError.invalidOptions("The document has no pages to select.")
        }
        var groups: [[Int]] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            let ends = token.split(separator: "-", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard ends.count == 1 || ends.count == 2, let first = ends[0], let last = ends[ends.count - 1] else {
                throw OrbitError.invalidOptions("\"\(token)\" is not a page or page range.")
            }
            guard (1...pageCount).contains(first), (1...pageCount).contains(last) else {
                throw OrbitError.invalidOptions("Page selection \"\(token)\" is outside 1-\(pageCount).")
            }
            groups.append(first <= last ? Array(first...last) : Array((last...first).reversed()))
        }
        guard !groups.isEmpty else {
            throw OrbitError.invalidOptions("No pages were selected.")
        }
        return groups
    }

    public static func parseFlat(_ text: String, pageCount: Int) throws -> [Int] {
        try parseGroups(text, pageCount: pageCount).flatMap { $0 }
    }
}
