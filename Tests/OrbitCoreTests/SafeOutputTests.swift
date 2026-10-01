import XCTest
@testable import OrbitCore

final class SafeOutputTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func stage(_ staging: StagingArea, _ text: String) throws -> URL {
        let url = staging.newFile(ext: "txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testCommitNeverOverwritesAndAddsCounters() throws {
        let existing = directory.appendingPathComponent("report.txt")
        try Data("original".utf8).write(to: existing)

        let staging = try StagingArea(outputDirectory: directory)
        let first = try staging.commit(try stage(staging, "one"), stem: "report", ext: "txt")
        let second = try staging.commit(try stage(staging, "two"), stem: "report", ext: "txt")
        staging.discard()

        XCTAssertEqual(first.lastPathComponent, "report-2.txt")
        XCTAssertEqual(second.lastPathComponent, "report-3.txt")
        XCTAssertEqual(try String(contentsOf: existing), "original")
        XCTAssertEqual(try String(contentsOf: first), "one")
        XCTAssertEqual(try String(contentsOf: second), "two")
        XCTAssertEqual(Fixtures.listing(directory), ["report-2.txt", "report-3.txt", "report.txt"])
    }

    func testCommitDoesNotFollowExistingSymlink() throws {
        let target = directory.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.txt"), withDestinationURL: target)

        let staging = try StagingArea(outputDirectory: directory)
        let committed = try staging.commit(try stage(staging, "new"), stem: "link", ext: "txt")
        staging.discard()

        XCTAssertEqual(committed.lastPathComponent, "link-2.txt")
        XCTAssertEqual(try String(contentsOf: target), "keep")
    }

    func testConcurrentCommitsGetDistinctNames() throws {
        let lock = NSLock()
        var names: [String] = []
        let directory = self.directory!
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            guard let staging = try? StagingArea(outputDirectory: directory) else { return }
            let staged = staging.newFile(ext: "txt")
            try? Data("\(index)".utf8).write(to: staged)
            if let url = try? staging.commit(staged, stem: "same", ext: "txt") {
                lock.lock()
                names.append(url.lastPathComponent)
                lock.unlock()
            }
            staging.discard()
        }
        XCTAssertEqual(names.count, 12)
        XCTAssertEqual(Set(names).count, 12, "every commit must land on its own name")
        XCTAssertEqual(Fixtures.listing(directory).count, 12, "no staging directories may remain")
    }

    func testStagingIsHiddenAndRemovedOnDiscard() throws {
        let staging = try StagingArea(outputDirectory: directory)
        XCTAssertTrue(staging.directory.lastPathComponent.hasPrefix("."))
        XCTAssertEqual(staging.directory.deletingLastPathComponent().path, directory.path)
        _ = try stage(staging, "temporary")
        staging.discard()
        XCTAssertEqual(Fixtures.listing(directory), [])
    }

    func testMissingOutputDirectoryIsReported() {
        let missing = directory.appendingPathComponent("does-not-exist")
        assertOrbitError(try StagingArea(outputDirectory: missing)) {
            if case .outputNotWritable = $0 { return true }
            return false
        }
    }

    func testReadOnlyOutputDirectoryIsReportedAndLeftUntouched() throws {
        let locked = directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        let source = try Fixtures.quadrantPNG(in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: locked.path), "running with privileges that ignore permissions")

        assertOrbitError(try Fixtures.engine.convert(source, to: "jpg", outputDirectory: locked)) {
            if case .outputNotWritable = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(locked), [])
    }

    // MARK: Job contract

    private func source(named name: String = "input.txt") throws -> SourceFile {
        let url = directory.appendingPathComponent(name)
        try Data("source".utf8).write(to: url)
        return try SourceFile(url)
    }

    private let validator = OutputValidator(toolchain: nil)

    func testFailureRemovesStagingAndLeavesNoOutput() throws {
        let input = try source()
        assertOrbitError(try JobRunner.perform(
            sources: [input], outputDirectory: nil, token: nil, validator: self.validator
        ) { staging in
            let staged = staging.newFile(ext: "txt")
            try Data("partial".utf8).write(to: staged)
            throw OrbitError.engineFailure("boom")
        }) { $0 == .engineFailure("boom") }
        XCTAssertEqual(Fixtures.listing(directory), ["input.txt"])
    }

    func testLateCancellationDoesNotCommitOrReportSuccess() throws {
        let input = try source()
        let token = CancellationToken()
        assertOrbitError(try JobRunner.perform(
            sources: [input], outputDirectory: nil, token: token, validator: self.validator
        ) { staging in
            let staged = staging.newFile(ext: "txt")
            try Data("finished".utf8).write(to: staged)
            // The engine finished its work; the user cancels just before commit.
            token.cancel()
            return .single(staged, stem: "input-done", ext: "txt", check: .nonEmpty)
        }) { $0 == .cancelled }
        XCTAssertEqual(Fixtures.listing(directory), ["input.txt"])
    }

    func testCancelledBeforeStartCreatesNothing() throws {
        let input = try source()
        let token = CancellationToken()
        token.cancel()
        assertOrbitError(try JobRunner.perform(
            sources: [input], outputDirectory: nil, token: token, validator: self.validator
        ) { _ in
            XCTFail("the body must not run")
            return StagedResult(outputs: [])
        }) { $0 == .cancelled }
        XCTAssertEqual(Fixtures.listing(directory), ["input.txt"])
    }

    func testSourceChangedDuringJobIsDetected() throws {
        let input = try source()
        assertOrbitError(try JobRunner.perform(
            sources: [input], outputDirectory: nil, token: nil, validator: self.validator
        ) { staging in
            let staged = staging.newFile(ext: "txt")
            try Data("derived".utf8).write(to: staged)
            try Data("the source was edited meanwhile".utf8).write(to: input.url)
            return .single(staged, stem: "input-done", ext: "txt", check: .nonEmpty)
        }) {
            if case .sourceChanged = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["input.txt"])
    }

    func testEmptyOutputFailsValidation() throws {
        let input = try source()
        assertOrbitError(try JobRunner.perform(
            sources: [input], outputDirectory: nil, token: nil, validator: self.validator
        ) { staging in
            let staged = staging.newFile(ext: "txt")
            try Data().write(to: staged)
            return .single(staged, stem: "input-done", ext: "txt", check: .nonEmpty)
        }) {
            if case .validationFailed = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["input.txt"])
    }

    func testMultiOutputJobCommitsEveryFileWithSourceDerivedNames() throws {
        let input = try source(named: "clip.txt")
        let result = try JobRunner.perform(
            sources: [input], outputDirectory: nil, token: nil, validator: validator
        ) { staging in
            var outputs: [StagedOutput] = []
            for part in 1...3 {
                let staged = staging.newFile(ext: "txt")
                try Data("part \(part)".utf8).write(to: staged)
                outputs.append(StagedOutput(url: staged, stem: "\(input.stem)-part\(part)", ext: "txt", check: .nonEmpty))
            }
            return StagedResult(outputs: outputs)
        }
        XCTAssertEqual(result.outputs.map { $0.lastPathComponent }, ["clip-part1.txt", "clip-part2.txt", "clip-part3.txt"])
        XCTAssertEqual(Fixtures.listing(directory), ["clip-part1.txt", "clip-part2.txt", "clip-part3.txt", "clip.txt"])
    }

    func testFoldersAndMissingFilesAreRejectedAsSources() {
        assertOrbitError(try SourceFile(self.directory)) {
            if case .invalidInput = $0 { return true }
            return false
        }
        assertOrbitError(try SourceFile(self.directory.appendingPathComponent("nope.png"))) {
            if case .invalidInput = $0 { return true }
            return false
        }
        assertOrbitError(try SourceFile(URL(string: "https://example.com/a.png")!)) {
            if case .invalidInput = $0 { return true }
            return false
        }
    }
}
