import XCTest
import CoreGraphics
import PDFKit
@testable import OrbitCore

final class PDFTests: XCTestCase {
    private var directory: URL!
    private var fixture: URL!
    private let engine = Fixtures.engine

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
        fixture = try Fixtures.pdf(pages: ["ALPHA", "BRAVO", "CHARLIE"], at: directory.appendingPathComponent("letters.pdf"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func words(_ url: URL) throws -> [String] {
        try PDFEngine.pageTexts(url).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func testFixtureTextIsExtractableInPageOrder() throws {
        XCTAssertEqual(try words(fixture), ["ALPHA", "BRAVO", "CHARLIE"])
    }

    func testPDFToTextContainsEveryPageInOrder() throws {
        let result = try engine.convert(fixture, to: "txt")
        XCTAssertEqual(result.outputs.map { $0.lastPathComponent }, ["letters.txt"])
        let text = try String(contentsOf: result.outputs[0])
        let alpha = try XCTUnwrap(text.range(of: "ALPHA"))
        let bravo = try XCTUnwrap(text.range(of: "BRAVO"))
        let charlie = try XCTUnwrap(text.range(of: "CHARLIE"))
        XCTAssertTrue(alpha.lowerBound < bravo.lowerBound && bravo.lowerBound < charlie.lowerBound)
    }

    func testReorderProducesRequestedPageOrder() throws {
        let result = try engine.runTool("pdf-reorder", sources: [fixture], options: ToolOptions(["order": "3,1,2"]))
        XCTAssertEqual(result.outputs.map { $0.lastPathComponent }, ["letters-reordered.pdf"])
        XCTAssertEqual(try words(result.outputs[0]), ["CHARLIE", "ALPHA", "BRAVO"])
        XCTAssertEqual(try words(fixture), ["ALPHA", "BRAVO", "CHARLIE"], "the source must be unchanged")
    }

    func testReorderCanExtractAndReverseRanges() throws {
        let result = try engine.runTool("pdf-reorder", sources: [fixture], options: ToolOptions(["order": "3-2"]))
        XCTAssertEqual(try words(result.outputs[0]), ["CHARLIE", "BRAVO"])
    }

    func testReorderRejectsPagesOutsideTheDocument() throws {
        assertOrbitError(try self.engine.runTool("pdf-reorder", sources: [self.fixture], options: ToolOptions(["order": "1,9"]))) {
            if case .invalidOptions = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["letters.pdf"])
    }

    func testSplitWritesOneFilePerPage() throws {
        let result = try engine.runTool("pdf-split", sources: [fixture])
        XCTAssertEqual(
            result.outputs.map { $0.lastPathComponent },
            ["letters-part01.pdf", "letters-part02.pdf", "letters-part03.pdf"])
        XCTAssertEqual(try words(result.outputs[0]), ["ALPHA"])
        XCTAssertEqual(try words(result.outputs[2]), ["CHARLIE"])
    }

    func testSplitByGroups() throws {
        let result = try engine.runTool("pdf-split", sources: [fixture], options: ToolOptions(["ranges": "1-2,3"]))
        XCTAssertEqual(result.outputs.count, 2)
        XCTAssertEqual(try words(result.outputs[0]), ["ALPHA", "BRAVO"])
        XCTAssertEqual(try words(result.outputs[1]), ["CHARLIE"])
    }

    func testMergeAppendsInInputOrder() throws {
        let second = try Fixtures.pdf(pages: ["DELTA"], at: directory.appendingPathComponent("more.pdf"))
        let result = try engine.runTool("pdf-merge", sources: [second, fixture])
        XCTAssertEqual(result.outputs.map { $0.lastPathComponent }, ["more-merged.pdf"])
        XCTAssertEqual(try words(result.outputs[0]), ["DELTA", "ALPHA", "BRAVO", "CHARLIE"])
    }

    func testMergeNeedsTwoFiles() {
        assertOrbitError(try self.engine.runTool("pdf-merge", sources: [self.fixture])) {
            if case .invalidInput = $0 { return true }
            return false
        }
    }

    func testRotateSelectedPages() throws {
        let result = try engine.runTool("pdf-rotate", sources: [fixture], options: ToolOptions(["degrees": "90", "pages": "2"]))
        let document = try XCTUnwrap(PDFDocument(url: result.outputs[0]))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(document.page(at: 0)?.rotation, 0)
        XCTAssertEqual(document.page(at: 1)?.rotation, 90)
        XCTAssertEqual(document.page(at: 2)?.rotation, 0)
    }

    func testRasterizeWritesOneImagePerPageAtRequestedResolution() throws {
        let result = try engine.convert(fixture, to: "png", options: ToolOptions(["dpi": 72]))
        XCTAssertEqual(
            result.outputs.map { $0.lastPathComponent },
            ["letters-p01.png", "letters-p02.png", "letters-p03.png"])
        for output in result.outputs {
            let image = try Fixtures.decode(output)
            XCTAssertEqual(image.width, 200)
            XCTAssertEqual(image.height, 100)
        }
        let doubled = try engine.convert(fixture, to: "jpg", options: ToolOptions(["dpi": 144]))
        XCTAssertEqual(try Fixtures.decode(doubled.outputs[0]).width, 400)

        // The text is dark ink on a white page.
        let grid = try ImageEngine.pixels(of: try Fixtures.decode(result.outputs[0]))
        assertPixel(grid, 190, 90, is: (255, 255, 255))
        var darkPixels = 0
        for y in 0..<grid.height {
            for x in 0..<grid.width where grid.rgba(x: x, y: y).r < 100 { darkPixels += 1 }
        }
        XCTAssertGreaterThan(darkPixels, 50, "the page text should have been drawn")
    }

    func testRasterizedRedactionRemovesAllTextAndPaintsTheBox() throws {
        let result = try engine.runTool(
            "pdf-redact-rasterize", sources: [fixture],
            options: ToolOptions(["rects": "0,0,100,50", "pages": "1", "dpi": 72]))
        let output = result.outputs[0]
        XCTAssertEqual(output.lastPathComponent, "letters-redacted.pdf")
        XCTAssertFalse(result.notes.isEmpty, "the rasterization must be disclosed")

        // No page keeps extractable text, redacted or not.
        let texts = try words(output)
        XCTAssertEqual(texts.count, 3)
        XCTAssertFalse(texts.joined().contains("ALPHA"))
        XCTAssertFalse(texts.joined().contains("BRAVO"))
        let bytes = try Data(contentsOf: output)
        XCTAssertNil(bytes.range(of: Data("ALPHA".utf8)))

        let document = try PDFEngine.openForDrawing(output)
        let first = try ImageEngine.pixels(of: try PDFEngine.renderPage(try XCTUnwrap(document.page(at: 1)), dpi: 72))
        XCTAssertEqual(first.width, 200)
        assertPixel(first, 50, 25, is: (0, 0, 0), tolerance: 30)
        assertPixel(first, 150, 75, is: (255, 255, 255), tolerance: 30)
        // Page 2 was not selected for boxes, so the same spot stays white.
        let second = try ImageEngine.pixels(of: try PDFEngine.renderPage(try XCTUnwrap(document.page(at: 2)), dpi: 72))
        assertPixel(second, 50, 5, is: (255, 255, 255), tolerance: 30)
    }

    func testMalformedPDFFailsCleanly() throws {
        let headerOnly = directory.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4\nthis is not really a pdf".utf8).write(to: headerOnly)
        let notPDF = directory.appendingPathComponent("fake.pdf")
        try Data("plain text".utf8).write(to: notPDF)

        for source in [headerOnly, notPDF] {
            assertOrbitError(try self.engine.convert(source, to: "png")) {
                if case .malformed = $0 { return true }
                return false
            }
            assertOrbitError(try self.engine.runTool("pdf-split", sources: [source])) {
                if case .malformed = $0 { return true }
                return false
            }
        }
        XCTAssertEqual(Fixtures.listing(directory), ["broken.pdf", "fake.pdf", "letters.pdf"])
    }

    func testPageRangeParsing() throws {
        XCTAssertEqual(try PageRanges.parseGroups("1-3, 5", pageCount: 6), [[1, 2, 3], [5]])
        XCTAssertEqual(try PageRanges.parseFlat("3,1-2", pageCount: 3), [3, 1, 2])
        XCTAssertEqual(try PageRanges.parseFlat("3-1", pageCount: 3), [3, 2, 1])
        XCTAssertThrowsError(try PageRanges.parseFlat("0", pageCount: 3))
        XCTAssertThrowsError(try PageRanges.parseFlat("a-b", pageCount: 3))
        XCTAssertThrowsError(try PageRanges.parseFlat("", pageCount: 3))
    }
}
