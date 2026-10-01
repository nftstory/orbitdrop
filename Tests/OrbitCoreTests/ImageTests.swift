import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import PDFKit
@testable import OrbitCore

final class ImageTests: XCTestCase {
    private var directory: URL!
    private let engine = Fixtures.engine

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func soleOutput(_ result: JobResult, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        XCTAssertEqual(result.outputs.count, 1, file: file, line: line)
        return try XCTUnwrap(result.outputs.first, file: file, line: line)
    }

    private func tool(_ id: String, _ source: URL, _ options: [String: Any] = [:]) throws -> URL {
        try soleOutput(try engine.runTool(id, sources: [source], options: ToolOptions(options)))
    }

    // MARK: Conversion

    func testFixtureLayoutIsWhatTheTestsAssume() throws {
        let grid = try ImageEngine.pixels(of: try Fixtures.quadrantImage())
        assertPixel(grid, 10, 10, is: (255, 0, 0))
        assertPixel(grid, 50, 10, is: (0, 255, 0))
        assertPixel(grid, 10, 40, is: (0, 0, 255))
        assertPixel(grid, 50, 40, is: (255, 255, 255))
    }

    func testPNGToJPEGKeepsDimensionsAndLeavesSourceUntouched() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let before = try Data(contentsOf: source)

        let output = try soleOutput(try engine.convert(source, to: "jpg"))

        XCTAssertEqual(output.lastPathComponent, "photo.jpg")
        let image = try Fixtures.decode(output)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        let grid = try ImageEngine.pixels(of: image)
        assertPixel(grid, 10, 10, is: (255, 0, 0), tolerance: 50)
        assertPixel(grid, 50, 40, is: (255, 255, 255), tolerance: 50)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(Fixtures.listing(directory), ["photo.jpg", "photo.png"])
    }

    func testEveryCoreFormatRoundTripsThroughImageIO() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let offered = Set(engine.targets(for: source).map { $0.id })
        for id in ["jpg", "tiff", "gif", "bmp"] {
            XCTAssertTrue(offered.contains(id), "\(id) should be offered for PNG input")
            let output = try soleOutput(try engine.convert(source, to: id))
            let image = try Fixtures.decode(output)
            XCTAssertEqual(image.width, 64, id)
            XCTAssertEqual(image.height, 48, id)
        }
        XCTAssertFalse(offered.contains("png"), "a PNG must not be offered PNG")
    }

    func testOfferedImageFormatsMatchRuntimeImageIO() {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        for format in engine.allTargets(forExtension: "png") where format.resultKind == .image {
            let spec = FormatRegistry.imageSpec(id: format.id)
            XCTAssertNotNil(spec)
            XCTAssertTrue(writable.contains(spec?.uti ?? ""), "\(format.id) is offered but ImageIO cannot write it")
        }
    }

    func testFormatAliasesAndIdentityConversion() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let output = try soleOutput(try engine.convert(source, to: "JPEG"))
        XCTAssertEqual(output.pathExtension, "jpg")
        assertOrbitError(try self.engine.convert(source, to: "png")) {
            if case .unsupported = $0 { return true }
            return false
        }
    }

    func testSecondConversionGetsCounterInsteadOfOverwriting() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let first = try soleOutput(try engine.convert(source, to: "jpg"))
        let firstBytes = try Data(contentsOf: first)
        let second = try soleOutput(try engine.convert(source, to: "jpg"))
        XCTAssertEqual(second.lastPathComponent, "photo-2.jpg")
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
    }

    func testImageToPDFHasOnePageOfImageSize() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let output = try soleOutput(try engine.convert(source, to: "pdf"))
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 1)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 64, accuracy: 0.5)
        XCTAssertEqual(bounds.height, 48, accuracy: 0.5)
    }

    func testImagesCombineIntoOnePDFInOrder() throws {
        let first = try Fixtures.quadrantPNG(in: directory, name: "a.png")
        let wide = try ImageEngine.redraw(try Fixtures.quadrantImage(), width: 120, height: 30)
        let second = try Fixtures.writeImage(wide, id: "png", to: directory.appendingPathComponent("b.png"))

        let result = try engine.runTool("images-to-pdf", sources: [first, second])
        let output = try soleOutput(result)
        XCTAssertEqual(output.lastPathComponent, "a-combined.pdf")
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).width, 64, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox).width, 120, accuracy: 0.5)
    }

    // MARK: Tools

    func testCropKeepsRequestedRegion() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let output = try tool("image-crop", source, ["x": 32, "y": 0, "width": 32, "height": 24])
        XCTAssertEqual(output.lastPathComponent, "photo-cropped.png")
        let image = try Fixtures.decode(output)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 24)
        let grid = try ImageEngine.pixels(of: image)
        assertPixel(grid, 2, 2, is: (0, 255, 0))
        assertPixel(grid, 29, 21, is: (0, 255, 0))
    }

    func testCropOutsideImageIsRejectedAndLeavesNothing() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        assertOrbitError(try self.engine.runTool(
            "image-crop", sources: [source], options: ToolOptions(["x": 500, "y": 500, "width": 10, "height": 10]))
        ) {
            if case .invalidOptions = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["photo.png"])
    }

    func testResizeByWidthKeepsAspectRatio() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let image = try Fixtures.decode(try tool("image-resize", source, ["width": 32]))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 24)
        let exact = try Fixtures.decode(try tool("image-resize", source, ["width": "10", "height": "20"]))
        XCTAssertEqual(exact.width, 10)
        XCTAssertEqual(exact.height, 20)
        let scaled = try Fixtures.decode(try tool("image-resize", source, ["scale": 200]))
        XCTAssertEqual(scaled.width, 128)
        XCTAssertEqual(scaled.height, 96)
    }

    func testRotateClockwiseMovesQuadrants() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let image = try Fixtures.decode(try tool("image-rotate", source, ["degrees": 90]))
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 64)
        let grid = try ImageEngine.pixels(of: image)
        // Clockwise: the old bottom-left (blue) is now top-left, old top-left (red) is top-right.
        assertPixel(grid, 8, 8, is: (0, 0, 255))
        assertPixel(grid, 40, 8, is: (255, 0, 0))
        assertPixel(grid, 40, 56, is: (0, 255, 0))
        assertPixel(grid, 8, 56, is: (255, 255, 255))
    }

    func testFlipHorizontalMirrorsQuadrants() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let image = try Fixtures.decode(try tool("image-rotate", source, ["degrees": 0, "flip": "horizontal"]))
        XCTAssertEqual(image.width, 64)
        let grid = try ImageEngine.pixels(of: image)
        assertPixel(grid, 10, 10, is: (0, 255, 0))
        assertPixel(grid, 50, 10, is: (255, 0, 0))
    }

    func testRedactPaintsOpaqueBlackOnlyInsideTheBox() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let output = try tool("image-redact", source, ["rects": "0,0,32,24"])
        let grid = try ImageEngine.pixels(of: try Fixtures.decode(output))
        assertPixel(grid, 10, 10, is: (0, 0, 0))
        assertPixel(grid, 50, 10, is: (0, 255, 0))
        assertPixel(grid, 10, 40, is: (0, 0, 255))
        XCTAssertEqual(grid.rgba(x: 10, y: 10).a, 255)
    }

    func testAnnotateBoxChangesPixelsOnTheOutline() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let output = try tool("image-annotate", source, ["boxes": [[40, 30, 16, 12]], "color": "#000000", "lineWidth": 4])
        let grid = try ImageEngine.pixels(of: try Fixtures.decode(output))
        assertPixel(grid, 40, 36, is: (0, 0, 0), tolerance: 40)
        assertPixel(grid, 48, 36, is: (255, 255, 255))
    }

    func testBackgroundFillReplacesTransparency() throws {
        let context = try ImageEngine.context(width: 20, height: 20)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        let source = try Fixtures.writeImage(
            try ImageEngine.finish(context), id: "png", to: directory.appendingPathComponent("alpha.png"))

        let output = try tool("image-background", source, ["mode": "fill", "color": "#0000FF"])
        let grid = try ImageEngine.pixels(of: try Fixtures.decode(output))
        assertPixel(grid, 4, 10, is: (255, 0, 0))
        assertPixel(grid, 15, 10, is: (0, 0, 255))
        XCTAssertEqual(grid.rgba(x: 15, y: 10).a, 255)
    }

    func testAdjustBrightnessDarkens() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let output = try tool("image-adjust", source, ["brightness": -0.7])
        let image = try Fixtures.decode(output)
        XCTAssertEqual(image.width, 64)
        let pixel = try ImageEngine.pixels(of: image).rgba(x: 50, y: 40)
        XCTAssertLessThan(Int(pixel.r), 200, "white should have become darker")
    }

    func testCompressProducesSmallerDimensionJPEG() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        let output = try tool("image-compress", source, ["quality": 0.3, "maxDimension": 16])
        XCTAssertEqual(output.lastPathComponent, "photo-compressed.jpg")
        let image = try Fixtures.decode(output)
        XCTAssertEqual(max(image.width, image.height), 16)
    }

    func testMetadataIsPreservedByConversionAndRemovedByStrip() throws {
        let metadata: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "OrbitTestCam"] as [CFString: Any],
        ]
        let source = try Fixtures.writeImage(
            try Fixtures.quadrantImage(), id: "jpg", to: directory.appendingPathComponent("tagged.jpg"), metadata: metadata)

        func make(_ url: URL) throws -> String? {
            let tiff = try ImageEngine.load(url).properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            return tiff?[kCGImagePropertyTIFFMake] as? String
        }
        XCTAssertEqual(try make(source), "OrbitTestCam", "fixture should carry the tag")

        let converted = try soleOutput(try engine.convert(source, to: "tiff"))
        XCTAssertEqual(try make(converted), "OrbitTestCam")

        let stripped = try tool("image-strip-metadata", source)
        XCTAssertEqual(stripped.lastPathComponent, "tagged-clean.jpg")
        XCTAssertNil(try make(stripped))
        XCTAssertEqual(try Fixtures.decode(stripped).width, 64)
    }

    func testOrientationIsBakedIntoPixels() throws {
        // Orientation 6: the stored pixels must be rotated 90° clockwise for display.
        let metadata: [CFString: Any] = [kCGImagePropertyOrientation: 6]
        let source = try Fixtures.writeImage(
            try Fixtures.quadrantImage(), id: "jpg", to: directory.appendingPathComponent("turned.jpg"), metadata: metadata)
        let image = try Fixtures.decode(try soleOutput(try engine.convert(source, to: "png")))
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 64)
        assertPixel(try ImageEngine.pixels(of: image), 8, 8, is: (0, 0, 255), tolerance: 50)
    }

    func testQRCodeIsRead() throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("orbitdrop-qr-payload".utf8), forKey: "inputMessage")
        let code = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rendered = try XCTUnwrap(CIContext(options: nil).createCGImage(code, from: code.extent))
        let context = try ImageEngine.context(width: rendered.width + 80, height: rendered.height + 80)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: rendered.width + 80, height: rendered.height + 80))
        context.interpolationQuality = .none
        context.draw(rendered, in: CGRect(x: 40, y: 40, width: rendered.width, height: rendered.height))
        let source = try Fixtures.writeImage(
            try ImageEngine.finish(context), id: "png", to: directory.appendingPathComponent("code.png"))

        let output: URL
        do {
            output = try tool("image-read-codes", source)
        } catch {
            // Vision may be unavailable in headless or virtualised runners.
            throw XCTSkip("Vision barcode detection unavailable here: \(OrbitError.describe(error))")
        }
        XCTAssertEqual(output.lastPathComponent, "code-codes.txt")
        XCTAssertTrue(try String(contentsOf: output).contains("orbitdrop-qr-payload"))
    }

    // MARK: Malformed input

    func testGarbageImageFailsCleanly() throws {
        let source = directory.appendingPathComponent("broken.png")
        try Data("this is not a png".utf8).write(to: source)
        assertOrbitError(try self.engine.convert(source, to: "jpg")) {
            if case .malformed = $0 { return true }
            return false
        }
        assertOrbitError(try self.engine.runTool("image-resize", sources: [source], options: ToolOptions(["width": 10]))) {
            if case .malformed = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["broken.png"], "no output and no staging folder may remain")
    }

    func testInvalidOptionsAreRejected() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        assertOrbitError(try self.engine.runTool("image-resize", sources: [source], options: ToolOptions(["width": "wide"]))) {
            if case .invalidOptions = $0 { return true }
            return false
        }
        assertOrbitError(try self.engine.runTool("image-redact", sources: [source], options: ToolOptions(["rects": "1,2,3"]))) {
            if case .invalidOptions = $0 { return true }
            return false
        }
        assertOrbitError(try ToolOptions(json: "[1,2]")) {
            if case .invalidOptions = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["photo.png"])
    }
}
