import XCTest
@testable import OrbitCore

final class BatchTests: XCTestCase {
    private var directory: URL!
    private let engine = Fixtures.engine

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mixedBatch() throws -> (png: URL, jpg: URL, pdf: URL, other: URL) {
        let png = try Fixtures.quadrantPNG(in: directory, name: "a.png")
        let jpg = try Fixtures.writeImage(try Fixtures.quadrantImage(), id: "jpg", to: directory.appendingPathComponent("b.jpg"))
        let pdf = try Fixtures.pdf(pages: ["ONE", "TWO"], at: directory.appendingPathComponent("c.pdf"))
        let other = directory.appendingPathComponent("d.xyz")
        try Data("unknown".utf8).write(to: other)
        return (png, jpg, pdf, other)
    }

    func testCommonTargetsAreTheIntersection() throws {
        let files = try mixedBatch()
        let ids = Set(engine.commonTargets(for: [files.png, files.pdf]).formats.map { $0.id })
        XCTAssertTrue(ids.isSuperset(of: ["png", "jpg", "tiff"]), "raster formats work for both images and PDFs")
        XCTAssertFalse(ids.contains("txt"), "text extraction is PDF-only")
        XCTAssertFalse(ids.contains("pdf"), "PDF output is image-only here")
        XCTAssertFalse(ids.contains("gif"), "PDF pages are not offered as GIF")
    }

    func testFormatSharedByEveryFileIsDroppedButPartialIdentityIsKept() throws {
        let files = try mixedBatch()
        let second = try Fixtures.quadrantPNG(in: directory, name: "e.png")
        XCTAssertFalse(engine.commonTargets(for: [files.png, second]).formats.contains { $0.id == "png" })
        XCTAssertTrue(engine.commonTargets(for: [files.png, files.jpg]).formats.contains { $0.id == "png" })
    }

    func testUnsupportedFilesAreReportedNotSilentlyDropped() throws {
        let files = try mixedBatch()
        let batch = engine.commonTargets(for: [files.png, files.other])
        XCTAssertEqual(batch.unsupported, [files.other])
        XCTAssertEqual(batch.formats.map { $0.id }, engine.targets(for: files.png).map { $0.id })
        XCTAssertTrue(engine.commonTargets(for: [files.other]).formats.isEmpty)
    }

    func testCommonToolsRespectKindsAndMinimumInputs() throws {
        let files = try mixedBatch()
        let imageTools = Set(engine.commonTools(for: [files.png, files.jpg]).map { $0.id })
        XCTAssertTrue(imageTools.isSuperset(of: ["image-crop", "images-to-pdf", "archive-zip"]))
        XCTAssertFalse(imageTools.contains("pdf-merge"))

        let mixedTools = Set(engine.commonTools(for: [files.png, files.pdf, files.other]).map { $0.id })
        XCTAssertFalse(mixedTools.contains("image-crop"))
        XCTAssertTrue(mixedTools.contains("archive-zip"), "anything can be archived")

        let single = Set(engine.commonTools(for: [files.pdf]).map { $0.id })
        XCTAssertTrue(single.contains("pdf-split"))
        XCTAssertFalse(single.contains("pdf-merge"), "merging needs two PDFs")
    }

    func testToolsThatNeedFFmpegAreNotOfferedWithoutIt() {
        let ids = Set(engine.tools.map { $0.id })
        for id in ["media-compress", "media-crop", "media-speed", "media-join", "audio-bleep", "audio-normalize"] {
            XCTAssertFalse(ids.contains(id), "\(id) must be hidden when ffmpeg is absent")
        }
        XCTAssertTrue(engine.allTargets(forExtension: "mkv").isEmpty, "MKV needs ffmpeg")
        XCTAssertEqual(engine.allTargets(forExtension: "mov").map { $0.id }, ["mp4", "mov"])
        XCTAssertTrue(engine.allTargets(forExtension: "rar").isEmpty, "RAR is never a conversion source or target")
    }

    func testMixedBatchConvertsWhatItCanAndReportsTheRest() throws {
        let files = try mixedBatch()
        var updates: [[Int]] = []
        let outcomes = engine.runBatch(
            sources: [files.png, files.jpg, files.pdf, files.other],
            action: .convert(formatID: "png", options: .none)
        ) { indices, _ in updates.append(indices) }

        XCTAssertEqual(outcomes.count, 4)
        guard case .skipped = outcomes[0].status else { return XCTFail("a.png is already PNG") }
        guard case .succeeded(let image) = outcomes[1].status else { return XCTFail("b.jpg should convert") }
        guard case .succeeded(let pages) = outcomes[2].status else { return XCTFail("c.pdf should rasterize") }
        guard case .failed(let reason) = outcomes[3].status else { return XCTFail("d.xyz has no conversion") }

        XCTAssertEqual(image.outputs.map { $0.lastPathComponent }, ["b.png"])
        XCTAssertEqual(pages.outputs.map { $0.lastPathComponent }, ["c-p01.png", "c-p02.png"])
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(updates.contains([1]) && updates.contains([3]))
        XCTAssertEqual(
            Fixtures.listing(directory),
            ["a.png", "b.jpg", "b.png", "c-p01.png", "c-p02.png", "c.pdf", "d.xyz"])
    }

    func testCancelledBatchProducesNoOutputs() throws {
        let files = try mixedBatch()
        let before = Fixtures.listing(directory)
        let token = CancellationToken()
        token.cancel()
        let outcomes = engine.runBatch(
            sources: [files.png, files.jpg], action: .convert(formatID: "tiff", options: .none), token: token)
        for outcome in outcomes {
            guard case .cancelled = outcome.status else { return XCTFail("expected cancelled, got \(outcome.status)") }
        }
        XCTAssertEqual(Fixtures.listing(directory), before)
    }

    func testCancellingMidBatchKeepsFinishedFilesAndStopsTheRest() throws {
        let files = try mixedBatch()
        let token = CancellationToken()
        let outcomes = engine.runBatch(
            sources: [files.png, files.jpg, files.pdf], action: .convert(formatID: "tiff", options: .none), token: token
        ) { indices, status in
            if indices == [0], case .succeeded = status { token.cancel() }
        }
        guard case .succeeded = outcomes[0].status else { return XCTFail("first file finished before the cancel") }
        guard case .cancelled = outcomes[1].status else { return XCTFail("second file must be cancelled") }
        guard case .cancelled = outcomes[2].status else { return XCTFail("third file must be cancelled") }
        XCTAssertEqual(Fixtures.listing(directory), ["a.png", "a.tiff", "b.jpg", "c.pdf", "d.xyz"])
    }

    func testCombiningToolReportsOneOutcomeForAllSources() throws {
        let files = try mixedBatch()
        let outcomes = engine.runBatch(sources: [files.png, files.jpg], action: .tool(id: "images-to-pdf", options: .none))
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].sources.count, 2)
        guard case .succeeded(let result) = outcomes[0].status else { return XCTFail("combine should succeed") }
        XCTAssertEqual(result.outputs.map { $0.lastPathComponent }, ["a-combined.pdf"])
    }

    func testUnknownToolAndWrongKindFailWithoutOutput() throws {
        let files = try mixedBatch()
        let before = Fixtures.listing(directory)
        let unknown = engine.runBatch(sources: [files.png], action: .tool(id: "does-not-exist", options: .none))
        guard case .failed = unknown[0].status else { return XCTFail("unknown tool must fail") }
        let wrongKind = engine.runBatch(sources: [files.pdf], action: .tool(id: "image-crop", options: .none))
        guard case .failed = wrongKind[0].status else { return XCTFail("image tool on a PDF must fail") }
        let needsFFmpeg = engine.runBatch(sources: [files.png], action: .tool(id: "media-compress", options: .none))
        guard case .failed = needsFFmpeg[0].status else { return XCTFail("ffmpeg tool must be unavailable") }
        XCTAssertEqual(Fixtures.listing(directory), before)
    }
}

final class ArchiveTests: XCTestCase {
    private var directory: URL!
    private let engine = Fixtures.engine

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func textFiles() throws -> [URL] {
        try ["first.txt", "-dash name.txt", "third file.md"].map { name in
            let url = directory.appendingPathComponent(name)
            try Data("contents of \(name)".utf8).write(to: url)
            return url
        }
    }

    private func entryNames(_ archive: URL) throws -> Set<String> {
        Set(try ArchiveEngine.list(archive).map { entry in
            URL(fileURLWithPath: entry).lastPathComponent
        }.filter { $0 != "." && !$0.isEmpty })
    }

    func testZipContainsEveryFileUnderItsOwnName() throws {
        let files = try textFiles()
        let result = try engine.runTool("archive-zip", sources: files)
        XCTAssertEqual(result.outputs.map { $0.lastPathComponent }, ["first-archive.zip"])
        let names = try entryNames(result.outputs[0])
        XCTAssertTrue(names.isSuperset(of: ["first.txt", "-dash name.txt", "third file.md"]), "\(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix(".orbitdrop") }, "staging names must not leak into the archive")
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "sources stay in place")
        }
    }

    func testTarAndTgzAreCreated() throws {
        let files = try textFiles()
        let tar = try engine.runTool("archive-tar", sources: files).outputs[0]
        XCTAssertEqual(tar.pathExtension, "tar")
        XCTAssertTrue(try entryNames(tar).contains("third file.md"))

        let tgz = try engine.runTool("archive-tgz", sources: [files[0]]).outputs[0]
        XCTAssertEqual(tgz.lastPathComponent, "first.tgz")
        XCTAssertTrue(try Data(contentsOf: tgz).starts(with: [0x1F, 0x8B]))
        XCTAssertTrue(try entryNames(tgz).contains("first.txt"))
    }

    func testSameBasenameFromTwoFoldersIsNotLost() throws {
        let other = directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let first = directory.appendingPathComponent("same.txt")
        let second = other.appendingPathComponent("same.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let archive = try engine.runTool("archive-zip", sources: [first, second]).outputs[0]
        XCTAssertTrue(try entryNames(archive).isSuperset(of: ["same.txt", "same-2.txt"]))
    }

    func testGzipKeepsOriginalNameAndRoundTrips() throws {
        let source = try textFiles()[0]
        let output = try engine.runTool("archive-gzip", sources: [source]).outputs[0]
        XCTAssertEqual(output.lastPathComponent, "first.txt.gz")
        let unpacked = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-dc", output.path])
        XCTAssertEqual(unpacked.status, 0)
        XCTAssertEqual(unpacked.stdoutText, "contents of first.txt")
    }

    func testListingToolWritesEntryNamesWithoutExtracting() throws {
        let archive = try engine.runTool("archive-zip", sources: try textFiles()).outputs[0]
        let before = Fixtures.listing(directory)
        let listing = try engine.runTool("archive-list", sources: [archive]).outputs[0]
        XCTAssertEqual(listing.lastPathComponent, "first-archive-contents.txt")
        XCTAssertTrue(try String(contentsOf: listing).contains("third file.md"))
        XCTAssertEqual(Fixtures.listing(directory), (before + ["first-archive-contents.txt"]).sorted(), "nothing was unpacked")
    }

    func testArchivesHaveNoConversionsAndBrokenArchivesFail() throws {
        let broken = directory.appendingPathComponent("broken.zip")
        try Data("not an archive at all".utf8).write(to: broken)
        XCTAssertTrue(engine.targets(for: broken).isEmpty)
        assertOrbitError(try self.engine.runTool("archive-list", sources: [broken])) {
            if case .malformed = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["broken.zip"])
    }
}
