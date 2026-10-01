import XCTest
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
@testable import OrbitCore

/// Fixtures are generated at test time; nothing is downloaded or bundled.
enum Fixtures {
    static let engine = OrbitEngine(capabilities: .native())

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbitdrop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every entry in a directory, hidden ones included, sorted.
    static func listing(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Quadrants: top-left red, top-right green, bottom-left blue, bottom-right white.
    static func quadrantImage(width: Int = 64, height: Int = 48) throws -> CGImage {
        let context = try ImageEngine.context(width: width, height: height)
        let halfWidth = CGFloat(width) / 2, halfHeight = CGFloat(height) / 2
        // Core Graphics has its origin at the bottom-left.
        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        ]
        for (rect, color) in quadrants {
            context.setFillColor(color)
            context.fill(rect)
        }
        return try ImageEngine.finish(context)
    }

    @discardableResult
    static func writeImage(
        _ image: CGImage, id: String, to url: URL, metadata: [CFString: Any]? = nil
    ) throws -> URL {
        let spec = try XCTUnwrap(FormatRegistry.imageSpec(id: id))
        try ImageEngine.write(image, to: url, spec: spec, quality: 0.95, metadata: metadata)
        return url
    }

    @discardableResult
    static func quadrantPNG(in directory: URL, name: String = "photo.png") throws -> URL {
        try writeImage(try quadrantImage(), id: "png", to: directory.appendingPathComponent(name))
    }

    /// A PDF with one 200×100 pt page per string, each drawn as real text.
    @discardableResult
    static func pdf(pages: [String], at url: URL) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let created = CGContext(url as CFURL, mediaBox: &box, nil)
        let context = try XCTUnwrap(created)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            context.textPosition = CGPoint(x: 20, y: 40)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A mono 16-bit WAV containing a sine tone.
    @discardableResult
    static func wav(at url: URL, seconds: Double = 0.5, sampleRate: Double = 8000) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate)) * 0.5
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    static func decode(_ url: URL) throws -> CGImage {
        try ImageEngine.load(url).image
    }
}

/// Asserts that a pixel is within `tolerance` of an RGB colour.
func assertPixel(
    _ grid: PixelGrid, _ x: Int, _ y: Int, is expected: (Int, Int, Int), tolerance: Int = 12,
    file: StaticString = #filePath, line: UInt = #line
) {
    let pixel = grid.rgba(x: x, y: y)
    let actual = (Int(pixel.r), Int(pixel.g), Int(pixel.b))
    let close = abs(actual.0 - expected.0) <= tolerance
        && abs(actual.1 - expected.1) <= tolerance
        && abs(actual.2 - expected.2) <= tolerance
    XCTAssertTrue(close, "pixel (\(x),\(y)) is \(actual), expected \(expected)", file: file, line: line)
}

func assertOrbitError(
    _ expression: @autoclosure () throws -> Any, _ matches: (OrbitError) -> Bool,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        guard let orbit = error as? OrbitError else {
            XCTFail("expected OrbitError, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(matches(orbit), "unexpected error \(orbit)", file: file, line: line)
    }
}
