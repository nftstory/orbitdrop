import XCTest
import CoreGraphics
@testable import OrbitCore

/// Regression tests for the review findings: bounds traps, allocation
/// limits, strict no-overwrite, real media inspection, and the frame tool.
final class RegressionTests: XCTestCase {
    private var directory: URL!
    private let engine = Fixtures.engine

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func isInvalidOptions(_ error: OrbitError) -> Bool {
        if case .invalidOptions = error { return true }
        return false
    }

    // MARK: Numeric bounds

    func testAbsurdResizeValuesAreRejectedInsteadOfTrapping() throws {
        let source = try Fixtures.quadrantPNG(in: directory)
        for options: [String: Any] in [
            ["width": 1e300], ["height": 1e300], ["width": 1e300, "height": 1e300], ["scale": 1e15],
            ["width": 0], ["width": -5], ["maxDimension": -1], ["width": 20_000, "height": 20_000],
        ] {
            assertOrbitError(
                try self.engine.runTool("image-resize", sources: [source], options: ToolOptions(options)),
                isInvalidOptions)
        }
        XCTAssertEqual(Fixtures.listing(directory), ["photo.png"])
    }

    func testBitmapAllocationIsBudgeted() {
        XCTAssertThrowsError(try ImageEngine.context(width: 20_000, height: 20_000), "400 MP exceeds the 100 MP budget")
        XCTAssertThrowsError(try ImageEngine.context(width: 40_000, height: 10))
        XCTAssertNoThrow(try ImageEngine.context(width: 2000, height: 1000))
        XCTAssertThrowsError(try ImageEngine.checkedSize(width: .infinity, height: 10, what: "x"))
        XCTAssertThrowsError(try ImageEngine.checkedSize(width: .nan, height: 10, what: "x"))
        XCTAssertThrowsError(try ImageEngine.checkedSize(width: 1e300, height: 1e300, what: "x"))
    }

    func testPDFPagePixelSizeIsValidatedBeforeConversion() throws {
        XCTAssertThrowsError(try PDFEngine.pixelSize(points: CGSize(width: 1e30, height: 1e30), dpi: 300))
        XCTAssertThrowsError(try PDFEngine.pixelSize(points: CGSize(width: CGFloat.infinity, height: 100), dpi: 72))
        XCTAssertThrowsError(try PDFEngine.pixelSize(points: CGSize(width: 0, height: 100), dpi: 72))
        XCTAssertThrowsError(try PDFEngine.pixelSize(points: CGSize(width: 100, height: 100), dpi: .nan))
        XCTAssertThrowsError(try PDFEngine.pixelSize(points: CGSize(width: 5000, height: 5000), dpi: 600), "over budget")
        let size = try PDFEngine.pixelSize(points: CGSize(width: 612, height: 792), dpi: 300)
        XCTAssertEqual(size.width, 2550)
        XCTAssertEqual(size.height, 3300)

        // The default resolution backs off for huge pages instead of failing.
        let fitted = PDFEngine.fittingDPI(points: CGSize(width: 5000, height: 5000), dpi: 300)
        XCTAssertLessThan(fitted, 300)
        XCTAssertNoThrow(try PDFEngine.pixelSize(points: CGSize(width: 5000, height: 5000), dpi: fitted))
        XCTAssertEqual(PDFEngine.fittingDPI(points: CGSize(width: 612, height: 792), dpi: 300), 300)
    }

    func testPDFToImageDefaultsTo300DPIAndStaysConfigurable() throws {
        let pdf = try Fixtures.pdf(pages: ["ONE"], at: directory.appendingPathComponent("doc.pdf"))
        let standard = try Fixtures.decode(try engine.convert(pdf, to: "jpg").outputs[0])
        XCTAssertEqual(standard.width, 833, "200 pt at 300 dpi")
        XCTAssertEqual(standard.height, 417, "100 pt at 300 dpi")
        let custom = try Fixtures.decode(try engine.convert(pdf, to: "jpg", options: ToolOptions(["dpi": 72])).outputs[0])
        XCTAssertEqual(custom.width, 200)
    }

    func testPageRangesWithNoPagesThrowInsteadOfTrapping() {
        XCTAssertThrowsError(try PageRanges.parseGroups("1", pageCount: 0))
        XCTAssertThrowsError(try PageRanges.parseFlat("1-2", pageCount: -3))
    }

    func testPixelGridOutOfRangeReadsAreSafe() throws {
        let grid = try ImageEngine.pixels(of: try Fixtures.quadrantImage())
        XCTAssertEqual(grid.rgba(x: -1, y: 0).a, 0)
        XCTAssertEqual(grid.rgba(x: 64, y: 0).a, 0)
        XCTAssertEqual(grid.rgba(x: 0, y: 48).a, 0)
        XCTAssertEqual(grid.rgba(x: 63, y: 47).a, 255)
    }

    func testTimeParsingIsStrictAboutColonSyntaxAndFiniteness() throws {
        XCTAssertEqual(ToolOptions.parseTime("90"), 90)
        XCTAssertEqual(ToolOptions.parseTime("90.5"), 90.5)
        XCTAssertEqual(ToolOptions.parseTime("1:30"), 90)
        XCTAssertEqual(ToolOptions.parseTime("01:02:03.5"), 3723.5)
        XCTAssertNil(ToolOptions.parseTime("1:75"), "seconds must be below 60 with colons")
        XCTAssertNil(ToolOptions.parseTime("1:60:00"))
        XCTAssertNil(ToolOptions.parseTime("1.5:30"), "minutes must be whole")
        XCTAssertNil(ToolOptions.parseTime("inf"))
        XCTAssertNil(ToolOptions.parseTime("nan"))
        XCTAssertNil(ToolOptions.parseTime("-5"))
        XCTAssertNil(ToolOptions.parseTime("1e300"))
        XCTAssertNil(ToolOptions.parseTime(""))

        XCTAssertThrowsError(try ToolOptions(["t": -1]).time("t"))
        XCTAssertThrowsError(try ToolOptions(["t": Double.infinity]).time("t"))
        XCTAssertThrowsError(try ToolOptions(["t": 1e300]).time("t"))
        XCTAssertEqual(try ToolOptions(["t": 12.5]).time("t"), 12.5)
    }

    func testTimeRangesRejectNonFiniteAndReversedValues() throws {
        XCTAssertThrowsError(try ToolOptions(["r": [[1.0, Double.infinity]]]).timeRanges("r"))
        XCTAssertThrowsError(try ToolOptions(["r": [[Double.nan, 2.0]]]).timeRanges("r"))
        XCTAssertThrowsError(try ToolOptions(["r": [[3.0, 2.0]]]).timeRanges("r"))
        XCTAssertThrowsError(try ToolOptions(["r": "1-1e300"]).timeRanges("r"))
        let ranges = try ToolOptions(["r": "1.5-2.5; 0:07-0:08"]).timeRanges("r")
        XCTAssertEqual(ranges.map { $0.start }, [1.5, 7])
        XCTAssertEqual(ranges.map { $0.end }, [2.5, 8])
    }

    func testHugeSubtitleOffsetIsRejected() throws {
        let source = directory.appendingPathComponent("a.srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: source)
        assertOrbitError(
            try self.engine.runTool("subtitle-shift", sources: [source], options: ToolOptions(["offset": 1e300])),
            isInvalidOptions)
        XCTAssertEqual(Fixtures.listing(directory), ["a.srt"])
    }

    // MARK: Strict no-overwrite

    func testCommitRejectsFilesOutsideItsStagingFolderAndOddExtensions() throws {
        let staging = try StagingArea(outputDirectory: directory)
        defer { staging.discard() }
        let outsider = directory.appendingPathComponent("outsider.txt")
        try Data("not staged".utf8).write(to: outsider)
        XCTAssertThrowsError(try staging.commit(outsider, stem: "stolen", ext: "txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsider.path), "the outside file must not be moved")

        let staged = staging.newFile(ext: "txt")
        try Data("staged".utf8).write(to: staged)
        XCTAssertThrowsError(try staging.commit(staged, stem: "x", ext: "../evil"))
        XCTAssertThrowsError(try staging.commit(staged, stem: "x", ext: "a/b"))
        let traversal = staging.directory.appendingPathComponent("../outsider.txt")
        XCTAssertThrowsError(try staging.commit(traversal, stem: "x", ext: "txt"))

        // Path separators and dot names in a stem cannot escape the folder.
        let committed = try staging.commit(staged, stem: "../up/and/away", ext: "txt")
        XCTAssertEqual(committed.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(committed.lastPathComponent, ".._up_and_away.txt")
        let second = staging.newFile(ext: "txt")
        try Data("staged".utf8).write(to: second)
        XCTAssertEqual(try staging.commit(second, stem: "..", ext: "txt").lastPathComponent, "output.txt")
    }

    func testFailedMultiOutputCommitRollsBackItsOwnFirstFile() throws {
        let sourceURL = directory.appendingPathComponent("in.txt")
        try Data("source".utf8).write(to: sourceURL)
        let source = try SourceFile(sourceURL)
        let first = directory.appendingPathComponent("in-a.txt")

        // The second output has an invalid extension, so the commit fails
        // after the first file is in place and the job rolls back.
        XCTAssertThrowsError(try JobRunner.perform(
            sources: [source], outputDirectory: nil, token: nil, validator: OutputValidator(toolchain: nil)
        ) { staging in
            let one = staging.newFile(ext: "txt"), two = staging.newFile(ext: "txt")
            try Data("one".utf8).write(to: one)
            try Data("two".utf8).write(to: two)
            return StagedResult(outputs: [
                StagedOutput(url: one, stem: "in-a", ext: "txt", check: .nonEmpty),
                StagedOutput(url: two, stem: "in-b", ext: "bad/ext", check: .nonEmpty),
            ])
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the job's own first output is rolled back")
        XCTAssertEqual(Fixtures.listing(directory), ["in.txt"])
    }

    // MARK: Media inspection and audio preservation

    func testVideoContainersAreNotOfferedWithoutAnAudioEncoder() throws {
        let silent = MediaToolchain(
            ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), ffprobe: nil,
            encoders: ["libx264", "mpeg4", "gif"], muxers: ["mp4", "mov", "matroska", "gif"])
        let ids = Set(FormatRegistry.mediaFormats.filter { $0.isAvailable(in: silent) }.map { $0.id })
        XCTAssertEqual(ids, ["gif"], "MP4/MOV/MKV would drop the sound; GIF is the explicit silent format")

        let withAudio = MediaToolchain(
            ffmpeg: silent.ffmpeg, ffprobe: nil, encoders: ["libx264", "aac", "gif"], muxers: ["mp4", "gif"])
        XCTAssertEqual(
            Set(FormatRegistry.mediaFormats.filter { $0.isAvailable(in: withAudio) }.map { $0.id }), ["mp4", "gif"])
    }

    func testStreamReportParsingWhenFFprobeIsMissing() throws {
        let banner = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from '/tmp/clip.mov':
          Metadata:
            major_brand     : qt
          Duration: 00:00:05.04, start: 0.000000, bitrate: 1203 kb/s
          Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709), 1280x720 [SAR 1:1 DAR 16:9], 1100 kb/s, 29.97 fps, 29.97 tbr (default)
          Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 96 kb/s (default)
        At least one output file must be specified
        """
        let info = try FFprobe.parseBanner(banner, name: "clip.mov")
        XCTAssertTrue(info.hasVideo)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.width, 1280)
        XCTAssertEqual(info.height, 720)
        XCTAssertEqual(info.duration ?? 0, 5.04, accuracy: 0.001)
        XCTAssertEqual(info.frameRate ?? 0, 29.97, accuracy: 0.001)
        XCTAssertEqual(info.videoCodec, "h264")
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(info.channels, 2)

        let silent = """
        Input #0, matroska,webm, from 'a.mkv':
          Duration: N/A, start: 0.000000, bitrate: N/A
          Stream #0:0: Video: vp9, yuv420p, 640x360, 30 fps
        """
        let silentInfo = try FFprobe.parseBanner(silent, name: "a.mkv")
        XCTAssertTrue(silentInfo.hasVideo)
        XCTAssertFalse(silentInfo.hasAudio, "a silent video is reported as silent, not assumed to have sound")
        XCTAssertNil(silentInfo.duration)

        let cover = """
        Input #0, mp3, from 'song.mp3':
          Duration: 00:03:00.00, start: 0.0, bitrate: 128 kb/s
          Stream #0:0: Audio: mp3, 44100 Hz, mono, fltp, 128 kb/s
          Stream #0:1: Video: mjpeg, yuvj420p, 600x600, 90k tbr (attached pic)
        """
        let coverInfo = try FFprobe.parseBanner(cover, name: "song.mp3")
        XCTAssertFalse(coverInfo.hasVideo, "cover art is not a video track")
        XCTAssertEqual(coverInfo.channels, 1)
        XCTAssertEqual(coverInfo.duration, 180)

        assertOrbitError(try FFprobe.parseBanner("Input #0, hls, from 'x.mp4':\n  Stream #0:0: Video: h264, 10x10", name: "x.mp4")) {
            if case .invalidInput = $0 { return true }
            return false
        }
        assertOrbitError(try FFprobe.parseBanner("x.mp4: Invalid data found when processing input", name: "x.mp4")) {
            if case .malformed = $0 { return true }
            return false
        }
    }

    func testProbeValuesThatAreNotFiniteAreDiscarded() throws {
        let json = #"{"streams":[{"codec_type":"video","width":99999999,"height":-4,"avg_frame_rate":"inf/1"},{"codec_type":"audio"}],"format":{"format_name":"mov","duration":"inf"}}"#
        let info = try FFprobe.parse(Data(json.utf8), name: "odd.mov")
        XCTAssertNil(info.duration)
        XCTAssertNil(info.width)
        XCTAssertNil(info.height)
        XCTAssertNil(info.frameRate)
        XCTAssertNil(FFprobe.parseRate("nan/1"))
        XCTAssertNil(FFprobe.parseRate("1/0"))
        XCTAssertNil(FFprobe.saneDimension(.infinity))
    }

    func testVideoCropGeometryIsValidatedAgainstTheFrame() throws {
        var info = MediaInfo(formatName: "mov")
        info.hasVideo = true
        info.width = 160
        info.height = 120
        XCTAssertEqual(try FFmpegEngine.cropFilter(rect: CGRect(x: 10, y: 20, width: 80, height: 60), info: info), "crop=80:60:10:20")
        XCTAssertThrowsError(try FFmpegEngine.cropFilter(rect: CGRect(x: 100, y: 0, width: 80, height: 60), info: info))
        XCTAssertThrowsError(try FFmpegEngine.cropFilter(rect: CGRect(x: 0, y: 0, width: 1e300, height: 60), info: info))
        XCTAssertThrowsError(try FFmpegEngine.cropFilter(rect: CGRect(x: 0, y: 0, width: 1, height: 60), info: info))
        XCTAssertThrowsError(try FFmpegEngine.cropFilter(rect: CGRect(x: -3, y: 0, width: 80, height: 60), info: nil))
    }

    func testMediaOutputIsReallyReopenedWithoutFFmpeg() throws {
        let validator = OutputValidator(toolchain: nil)
        let good = try Fixtures.wav(at: directory.appendingPathComponent("good.wav"))
        XCTAssertNoThrow(try validator.validate(good, check: .media))

        let bad = directory.appendingPathComponent("bad.m4a")
        try Data("this is not audio, only bytes".utf8).write(to: bad)
        XCTAssertThrowsError(try validator.validate(bad, check: .media)) { error in
            guard case OrbitError.validationFailed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: Frame tool

    private func frame(_ options: [String: Any]) throws -> (image: CGImage, grid: PixelGrid, url: URL) {
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("photo.png").path) {
            try Fixtures.quadrantPNG(in: directory)
        }
        let source = directory.appendingPathComponent("photo.png")
        let result = try engine.runTool("image-frame", sources: [source], options: ToolOptions(options))
        let image = try Fixtures.decode(result.outputs[0])
        return (image, try ImageEngine.pixels(of: image), result.outputs[0])
    }

    func testFramePlacesOriginalPixelsOnPaddedCanvas() throws {
        let framed = try frame(["padding": 10, "shadow": 0, "color": "#FF00FF"])
        XCTAssertEqual(framed.url.lastPathComponent, "photo-framed.png")
        XCTAssertEqual(framed.image.width, 84)
        XCTAssertEqual(framed.image.height, 68)
        assertPixel(framed.grid, 3, 3, is: (255, 0, 255))
        assertPixel(framed.grid, 80, 64, is: (255, 0, 255))
        // The 64×48 original sits at (10,10), pixel for pixel.
        assertPixel(framed.grid, 10, 10, is: (255, 0, 0), tolerance: 2)
        assertPixel(framed.grid, 73, 10, is: (0, 255, 0), tolerance: 2)
        assertPixel(framed.grid, 10, 57, is: (0, 0, 255), tolerance: 2)
        assertPixel(framed.grid, 73, 57, is: (255, 255, 255), tolerance: 2)
        assertPixel(framed.grid, 9, 30, is: (255, 0, 255), tolerance: 2)
        assertPixel(framed.grid, 74, 30, is: (255, 0, 255), tolerance: 2)
    }

    func testFrameAspectGrowsCanvasAndCentresImage() throws {
        let square = try frame(["padding": 10, "shadow": 0, "color": "#FF00FF", "aspect": "1:1"])
        XCTAssertEqual(square.image.width, 84)
        XCTAssertEqual(square.image.height, 84)
        assertPixel(square.grid, 42, 8, is: (255, 0, 255))
        assertPixel(square.grid, 15, 22, is: (255, 0, 0))
        assertPixel(square.grid, 42, 76, is: (255, 0, 255))

        let wide = try frame(["padding": 0, "shadow": 0, "color": "#FF00FF", "aspect": "16:9"])
        XCTAssertEqual(wide.image.height, 48)
        XCTAssertEqual(wide.image.width, 85)
    }

    func testFrameRoundedCornersRevealCanvas() throws {
        let rounded = try frame(["padding": 10, "cornerRadius": 16, "shadow": 0, "color": "#FF00FF"])
        assertPixel(rounded.grid, 10, 10, is: (255, 0, 255), tolerance: 30)
        assertPixel(rounded.grid, 73, 57, is: (255, 0, 255), tolerance: 30)
        assertPixel(rounded.grid, 26, 22, is: (255, 0, 0))
    }

    func testFrameShadowDarkensCanvasBelowTheImage() throws {
        let plain = try frame(["paddingPercent": 30, "shadow": 0, "color": "#FFFFFF"])
        let shaded = try frame(["paddingPercent": 30, "shadow": 100, "color": "#FFFFFF"])
        XCTAssertEqual(plain.image.width, shaded.image.width)
        // Just below the bottom edge of the image, in the padding.
        let x = plain.image.width / 2, y = 19 + 48 + 3
        XCTAssertEqual(plain.grid.rgba(x: x, y: y).r, 255)
        XCTAssertLessThan(shaded.grid.rgba(x: x, y: y).r, 245, "the shadow should tint the canvas")
        // The image itself is untouched by the shadow.
        assertPixel(shaded.grid, 19 + 5, 19 + 5, is: (255, 0, 0), tolerance: 2)
    }

    func testFramePercentOptionsScaleWithTheImageAndBadValuesFail() throws {
        let framed = try frame(["paddingPercent": 25, "shadow": 0])
        XCTAssertEqual(framed.image.width, 64 + 32, "25 % of the 64 px longer side on each edge")
        XCTAssertEqual(framed.image.height, 48 + 32)

        let source = directory.appendingPathComponent("photo.png")
        for options: [String: Any] in [
            ["padding": 1e300], ["padding": -4], ["paddingPercent": 900], ["cornerPercent": 80],
            ["aspect": "0:0"], ["aspect": "banana"], ["color": "red"], ["padding": 29_000],
        ] {
            XCTAssertThrowsError(
                try engine.runTool("image-frame", sources: [source], options: ToolOptions(options)), "\(options)")
        }
        XCTAssertEqual(try ImageEngine.aspectRatio("16:9") ?? 0, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertNil(try ImageEngine.aspectRatio("original"))
        XCTAssertNil(try ImageEngine.aspectRatio(nil))
    }

    func testPreviewReportsOrientedFullSize() throws {
        let source = try Fixtures.writeImage(
            try Fixtures.quadrantImage(), id: "jpg", to: directory.appendingPathComponent("turned.jpg"),
            metadata: [kCGImagePropertyOrientation: 6])
        let preview = try XCTUnwrap(ImageEngine.preview(source, maxPixelSize: 32))
        XCTAssertEqual(preview.pixelWidth, 48)
        XCTAssertEqual(preview.pixelHeight, 64)
        XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 32)
        XCTAssertLessThan(preview.image.width, preview.image.height)
        XCTAssertNil(ImageEngine.preview(directory.appendingPathComponent("missing.png")))
    }

    func testPreviewBoundsRequestedSizeAndRejectsOversizedHeader() throws {
        let wide = try Fixtures.writeImage(
            try Fixtures.quadrantImage(width: 4000, height: 8), id: "png",
            to: directory.appendingPathComponent("wide.png"))
        let preview = try XCTUnwrap(ImageEngine.preview(wide, maxPixelSize: Int.max))
        XCTAssertEqual(preview.pixelWidth, 4000)
        XCTAssertLessThanOrEqual(preview.image.width, 2048)
        // Build the external input independently; OrbitCore's bitmap factory
        // deliberately refuses this size before the preview can inspect it.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 30_001, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let oversized = try Fixtures.writeImage(
            try XCTUnwrap(context.makeImage()), id: "png",
            to: directory.appendingPathComponent("oversized.png"))
        XCTAssertNil(ImageEngine.preview(oversized))
    }
}
