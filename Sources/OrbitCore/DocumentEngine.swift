import Foundation
import AppKit
import CoreText

/// Text documents through NSAttributedString's built-in importers and
/// exporters. Nothing here executes document macros. HTML is write-only:
/// importing HTML can fetch remote resources, which OrbitDrop never does.
public enum DocumentEngine {
    static let plainTextExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    static func documentType(forID id: String) -> NSAttributedString.DocumentType? {
        switch id {
        case "rtf": return .rtf
        case "doc": return .docFormat
        case "docx": return .officeOpenXML
        case "odt": return .openDocument
        case "html": return .html
        default: return nil
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OrbitError.invalidInput("Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let hasUTF16Mark = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if hasUTF16Mark, let text = String(data: data, encoding: .utf16) { return text }
        if !data.contains(0), let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw OrbitError.malformed("\(url.lastPathComponent) is not readable text.")
    }

    static func read(_ url: URL, ext: String) throws -> NSAttributedString {
        if plainTextExtensions.contains(ext) {
            return NSAttributedString(string: try readText(url))
        }
        guard ext != "html", let type = documentType(forID: FormatRegistry.canonicalID(ext)) else {
            throw OrbitError.unsupported("\(url.lastPathComponent) is not a supported document type.")
        }
        do {
            // An explicit type stops the importer from sniffing its way into another format.
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw OrbitError.malformed("\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
        }
    }

    static func write(_ text: NSAttributedString, formatID: String, to url: URL) throws {
        switch formatID {
        case "txt":
            try Data(text.string.utf8).write(to: url)
        case "pdf":
            try renderPDF(text, to: url)
        default:
            guard let type = documentType(forID: formatID) else {
                throw OrbitError.unsupported("Documents cannot be written as \(formatID).")
            }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if formatID == "html" {
                attributes[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            let data: Data
            do {
                data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            } catch {
                throw OrbitError.engineFailure("Writing the \(formatID.uppercased()) document failed: \(error.localizedDescription)")
            }
            try data.write(to: url)
        }
    }

    /// Lays the text out on US Letter pages with Core Text. Fonts and
    /// paragraph styles carry over; images and text colours do not.
    static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw OrbitError.engineFailure("Could not create the PDF.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let path = CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }
            location += visible.length
        } while location < text.length
        context.closePDF()
    }
}
