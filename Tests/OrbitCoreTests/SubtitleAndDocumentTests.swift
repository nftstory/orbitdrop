import XCTest
import AppKit
import PDFKit
@testable import OrbitCore

final class SubtitleTests: XCTestCase {
    private var directory: URL!
    private let engine = Fixtures.engine

    private let srt = """
    1
    00:00:01,500 --> 00:00:04,000
    Hello <i>there</i>

    2
    01:02:03,004 --> 01:02:05,678
    Second cue
    spans two lines

    """

    private let vtt = """
    WEBVTT - sample

    NOTE this block is a comment

    intro
    00:01.250 --> 00:03.000 align:start position:10%
    <v Roger>Short <b>hours</b> form

    01:00:00.000 --> 01:00:02.500
    Later cue

    """

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTimestampParsingAndFormatting() {
        XCTAssertEqual(SubtitleEngine.parseTimestamp("00:00:01,500"), 1500)
        XCTAssertEqual(SubtitleEngine.parseTimestamp("01:02:03.004"), 3_723_004)
        XCTAssertEqual(SubtitleEngine.parseTimestamp("01:02.250"), 62_250)
        XCTAssertEqual(SubtitleEngine.parseTimestamp("00:00:07.5"), 7500)
        XCTAssertEqual(SubtitleEngine.parseTimestamp("00:00:07"), 7000)
        XCTAssertNil(SubtitleEngine.parseTimestamp("00:61:00,000"))
        XCTAssertNil(SubtitleEngine.parseTimestamp("12"))
        XCTAssertNil(SubtitleEngine.parseTimestamp("aa:bb:cc,ddd"))
        XCTAssertEqual(SubtitleEngine.formatTimestamp(3_723_004, format: .srt), "01:02:03,004")
        XCTAssertEqual(SubtitleEngine.formatTimestamp(3_723_004, format: .vtt), "01:02:03.004")
        XCTAssertEqual(SubtitleEngine.formatTimestamp(62_250, format: .vtt), "00:01:02.250")
    }

    func testSRTParsesIntoCues() throws {
        let cues = try SubtitleEngine.parse(srt, format: .srt)
        XCTAssertEqual(cues, [
            SubtitleCue(startMs: 1500, endMs: 4000, lines: ["Hello <i>there</i>"]),
            SubtitleCue(startMs: 3_723_004, endMs: 3_725_678, lines: ["Second cue", "spans two lines"]),
        ])
    }

    func testSRTToVTTUsesDotTimestampsAndHeader() throws {
        let output = SubtitleEngine.serialize(try SubtitleEngine.parse(srt, format: .srt), format: .vtt)
        XCTAssertTrue(output.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(output.contains("00:00:01.500 --> 00:00:04.000\nHello <i>there</i>\n"))
        XCTAssertTrue(output.contains("01:02:03.004 --> 01:02:05.678\nSecond cue\nspans two lines\n"))
        XCTAssertFalse(output.contains(","), "no SRT-style timestamps may remain")
    }

    func testVTTToSRTNumbersCuesExpandsHoursAndDropsVTTOnlySyntax() throws {
        let cues = try SubtitleEngine.parse(vtt, format: .vtt)
        XCTAssertEqual(cues.count, 2, "header and NOTE blocks are not cues")
        XCTAssertEqual(cues[0].startMs, 1250)
        XCTAssertEqual(cues[0].endMs, 3000)

        let output = SubtitleEngine.serialize(cues, format: .srt)
        XCTAssertEqual(output, """
        1
        00:00:01,250 --> 00:00:03,000
        Short <b>hours</b> form

        2
        01:00:00,000 --> 01:00:02,500
        Later cue


        """)
    }

    func testRoundTripPreservesTimingAndText() throws {
        let original = try SubtitleEngine.parse(srt, format: .srt)
        let viaVTT = try SubtitleEngine.parse(SubtitleEngine.serialize(original, format: .vtt), format: .vtt)
        XCTAssertEqual(viaVTT, original)
    }

    func testWindowsLineEndingsAndBOM() throws {
        let text = "\u{FEFF}" + srt.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try SubtitleEngine.parse(text, format: .srt).count, 2)
    }

    func testMalformedSubtitlesAreRejected() {
        assertOrbitError(try SubtitleEngine.parse("just some words\nwithout timing", format: .srt)) {
            if case .malformed = $0 { return true }
            return false
        }
        assertOrbitError(try SubtitleEngine.parse("1\n00:00:05,000 --> 00:00:02,000\nends before it starts\n", format: .srt)) {
            if case .malformed = $0 { return true }
            return false
        }
        assertOrbitError(try SubtitleEngine.parse("1\n00:00:xx,000 --> 00:00:02,000\nbad digits\n", format: .srt)) {
            if case .malformed = $0 { return true }
            return false
        }
    }

    func testShiftMovesAndDropsCues() throws {
        let cues = try SubtitleEngine.parse(srt, format: .srt)
        let later = SubtitleEngine.shift(cues, byMilliseconds: 2000)
        XCTAssertEqual(later[0].startMs, 3500)
        XCTAssertEqual(later[1].endMs, 3_727_678)
        let earlier = SubtitleEngine.shift(cues, byMilliseconds: -5000)
        XCTAssertEqual(earlier.count, 1, "a cue that would end before zero is dropped")
        XCTAssertEqual(earlier[0].startMs, 3_718_004)
    }

    func testEngineConvertsFilesBothWaysAndShifts() throws {
        let source = directory.appendingPathComponent("movie.srt")
        try Data(srt.utf8).write(to: source)

        let toVTT = try engine.convert(source, to: "vtt")
        XCTAssertEqual(toVTT.outputs.map { $0.lastPathComponent }, ["movie.vtt"])
        XCTAssertTrue(try String(contentsOf: toVTT.outputs[0]).hasPrefix("WEBVTT"))

        let back = try engine.convert(toVTT.outputs[0], to: "srt")
        XCTAssertEqual(back.outputs.map { $0.lastPathComponent }, ["movie-2.srt"], "movie.srt exists and must not be replaced")
        XCTAssertEqual(try String(contentsOf: source), srt)

        let shifted = try engine.runTool("subtitle-shift", sources: [source], options: ToolOptions(["offset": 1.5]))
        XCTAssertEqual(shifted.outputs.map { $0.lastPathComponent }, ["movie-shifted.srt"])
        XCTAssertTrue(try String(contentsOf: shifted.outputs[0]).contains("00:00:03,000 --> 00:00:05,500"))

        let text = try engine.convert(source, to: "txt")
        XCTAssertEqual(try String(contentsOf: text.outputs[0]), "Hello there\nSecond cue\nspans two lines\n")
    }

    func testMalformedSubtitleFileLeavesNothingBehind() throws {
        let source = directory.appendingPathComponent("broken.srt")
        try Data("no cues here".utf8).write(to: source)
        assertOrbitError(try self.engine.convert(source, to: "vtt")) {
            if case .malformed = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["broken.srt"])
    }
}

final class DocumentTests: XCTestCase {
    private var directory: URL!
    private let engine = Fixtures.engine
    private let sample = "OrbitDrop document sample.\nSecond paragraph with ünïcödé.\n"

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func textSource() throws -> URL {
        let url = directory.appendingPathComponent("notes.txt")
        try Data(sample.utf8).write(to: url)
        return url
    }

    func testTextToRTFAndBack() throws {
        let rtf = try engine.convert(try textSource(), to: "rtf").outputs[0]
        XCTAssertEqual(rtf.lastPathComponent, "notes.rtf")
        XCTAssertTrue(try Data(contentsOf: rtf).starts(with: Data("{\\rtf".utf8)))

        let text = try engine.convert(rtf, to: "txt").outputs[0]
        XCTAssertEqual(text.lastPathComponent, "notes-2.txt")
        XCTAssertTrue(try String(contentsOf: text).contains("Second paragraph with ünïcödé."))
    }

    func testTextToDOCXRoundTrip() throws {
        let docx = try engine.convert(try textSource(), to: "docx").outputs[0]
        // DOCX is a ZIP container.
        XCTAssertTrue(try Data(contentsOf: docx).starts(with: [0x50, 0x4B]))
        let reread = try NSAttributedString(
            url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(reread.string.contains("OrbitDrop document sample."))
    }

    func testTextToPDFHasSelectableText() throws {
        let pdf = try engine.convert(try textSource(), to: "pdf").outputs[0]
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue((document.string ?? "").contains("OrbitDrop document sample."))
    }

    func testLongTextPaginates() throws {
        let url = directory.appendingPathComponent("long.txt")
        let body = (1...400).map { "Line number \($0) of a long document." }.joined(separator: "\n")
        try Data(body.utf8).write(to: url)
        let pdf = try engine.convert(url, to: "pdf").outputs[0]
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(document.pageCount, 3)
        XCTAssertTrue((document.string ?? "").contains("Line number 400"))
    }

    func testHTMLIsWriteOnly() throws {
        let html = try engine.convert(try textSource(), to: "html").outputs[0]
        XCTAssertTrue(try String(contentsOf: html).lowercased().contains("<html"))
        XCTAssertEqual(FileKind.detect(html), .unknown, "HTML is never accepted as input")
        XCTAssertTrue(engine.targets(for: html).isEmpty)
    }

    func testBinaryGarbageIsNotTreatedAsText() throws {
        let url = directory.appendingPathComponent("blob.txt")
        try Data([0xFF, 0x00, 0xC3, 0x28, 0x00, 0x9F]).write(to: url)
        assertOrbitError(try self.engine.convert(url, to: "rtf")) {
            if case .malformed = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["blob.txt"])
    }
}
