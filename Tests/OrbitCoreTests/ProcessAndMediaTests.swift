import XCTest
import AVFoundation
@testable import OrbitCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesOutputAndStatus() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hello", "a b; echo injected"])
        XCTAssertEqual(result.status, 0)
        // Arguments are passed verbatim; nothing is interpreted by a shell.
        XCTAssertEqual(result.stdoutText, "hello a b; echo injected\n")
    }

    func testNonZeroExitAndStderrAreReported() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/ls"), ["/definitely/not/a/real/path"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.stderrTail.isEmpty)
    }

    func testLargeOutputDoesNotDeadlock() throws {
        var lines = 0
        let lock = NSLock()
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/seq"), ["1", "300000"],
            onStdoutLine: { _ in
                lock.lock()
                lines += 1
                lock.unlock()
            })
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(lines, 300_000)
        XCTAssertTrue(result.stdoutText.hasSuffix("300000\n"))
    }

    func testMissingExecutableIsReported() {
        assertOrbitError(try ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), [])) {
            if case .missingTool = $0 { return true }
            return false
        }
    }

    func testCancellationTerminatesTheChildPromptly() {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { token.cancel() }
        let started = Date()
        assertOrbitError(try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], token: token)) {
            $0 == .cancelled
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAlreadyCancelledTokenNeverStartsTheProcess() {
        let token = CancellationToken()
        token.cancel()
        assertOrbitError(try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], token: token)) {
            $0 == .cancelled
        }
    }

    func testCancellationTokenHandlers() {
        let token = CancellationToken()
        var fired = 0
        let removed = token.onCancel { fired += 100 }
        token.onCancel { fired += 1 }
        token.removeHandler(removed)
        token.cancel()
        token.cancel()
        XCTAssertEqual(fired, 1)
        token.onCancel { fired += 10 }
        XCTAssertEqual(fired, 11, "handlers added after cancellation run immediately")
    }
}

final class FFmpegCommandTests: XCTestCase {
    private let input = URL(fileURLWithPath: "/tmp/has space/-clip;rm -rf.mov")

    func testInputArgumentsRestrictProtocolsAndNeverUseAShell() {
        let arguments = FFmpegEngine.globalArguments() + FFmpegEngine.inputArguments(input, seek: 1.5)
        XCTAssertTrue(arguments.contains("-nostdin"))
        let whitelist = try? XCTUnwrap(arguments.firstIndex(of: "-protocol_whitelist"))
        let inputFlag = try? XCTUnwrap(arguments.firstIndex(of: "-i"))
        XCTAssertNotNil(whitelist)
        XCTAssertNotNil(inputFlag)
        if let whitelist, let inputFlag {
            XCTAssertEqual(arguments[whitelist + 1], "file,pipe")
            XCTAssertLessThan(whitelist, inputFlag, "the whitelist must apply to the input")
            // The path is one argument, exactly as given, and absolute.
            XCTAssertEqual(arguments[inputFlag + 1], "/tmp/has space/-clip;rm -rf.mov")
        }
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-ss")! + 1], "1.500")
    }

    func testOutputArgumentsNeverOverwriteAndUseRelativeNames() {
        let arguments = FFmpegEngine.outputArguments(muxer: "mp4", name: "staged-1.mp4")
        XCTAssertTrue(arguments.contains("-n"))
        XCTAssertFalse(arguments.contains("-y"))
        XCTAssertEqual(arguments.last, "staged-1.mp4")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-f")! + 1], "mp4")
    }

    func testProbeArgumentsRestrictProtocols() {
        let arguments = FFprobe.arguments(for: input)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-protocol_whitelist")! + 1], "file,pipe")
        XCTAssertEqual(arguments.last, input.path)
    }

    func testTempoChainStaysInsideFilterLimits() {
        XCTAssertEqual(FFmpegEngine.tempoChain(1.5), ["atempo=1.5000"])
        XCTAssertEqual(FFmpegEngine.tempoChain(4), ["atempo=2.0", "atempo=2.0000"])
        XCTAssertEqual(FFmpegEngine.tempoChain(0.25), ["atempo=0.5", "atempo=0.5000"])
    }

    func testEncoderSelectionArguments() {
        let hardware = FFmpegEngine.videoArguments(encoder: "h264_videotoolbox", level: .standard, info: nil)
        XCTAssertEqual(Array(hardware.prefix(3)), ["-c:v", "h264_videotoolbox", "-b:v"])
        let software = FFmpegEngine.videoArguments(encoder: "libx264", level: .medium, info: nil)
        XCTAssertEqual(software, ["-c:v", "libx264", "-preset", "medium", "-crf", "28", "-pix_fmt", "yuv420p"])
        XCTAssertEqual(FFmpegEngine.audioArguments(encoder: "aac", bitrateKbps: 96), ["-c:a", "aac", "-b:a", "96k"])
    }

    func testBleepFilterMutesVoiceAndGatesTone() {
        let filter = FFmpegEngine.bleepFilter(ranges: [(start: 1, end: 2.5), (start: 7, end: 8)], frequency: 1000)
        XCTAssertTrue(filter.contains("between(t,1.000,2.500)+between(t,7.000,8.000)"))
        XCTAssertTrue(filter.contains("not(between(t,1.000,2.500)+between(t,7.000,8.000))"))
        XCTAssertTrue(filter.contains("sine=frequency=1000"))
        XCTAssertTrue(filter.hasSuffix("[out]"))
    }

    func testProgressParsing() {
        XCTAssertEqual(FFmpegEngine.progressSeconds(fromLine: "out_time_us=2500000"), 2.5)
        XCTAssertEqual(FFmpegEngine.progressSeconds(fromLine: "out_time_ms=1000000"), 1.0)
        XCTAssertNil(FFmpegEngine.progressSeconds(fromLine: "frame=10"))
        XCTAssertNil(FFmpegEngine.progressSeconds(fromLine: "out_time_us=N/A"))
    }

    func testEncoderAndMuxerListParsing() {
        let encoders = FFmpegLocator.parseEncoders("""
        Encoders:
         V..... = Video
         A..... = Audio
         ------
         V....D libx264              libx264 H.264 / AVC
         V....D h264_videotoolbox    VideoToolbox H.264 Encoder
         A....D aac                  AAC (Advanced Audio Coding)
         S..... srt                  SubRip subtitle
        """)
        XCTAssertEqual(encoders, ["libx264", "h264_videotoolbox", "aac", "srt"])

        let muxers = FFmpegLocator.parseMuxers("""
        File formats:
         D. = Demuxing supported
         .E = Muxing supported
         --
          E matroska        Matroska
          E mov             QuickTime / MOV
          E mp4             MP4 (MPEG-4 Part 14)
          E stream_segment,ssegment streaming segment muxer
        """)
        XCTAssertEqual(muxers, ["matroska", "mov", "mp4", "stream_segment", "ssegment"])
    }

    func testFormatAvailabilityFollowsTheInstalledBuild() throws {
        let minimal = MediaToolchain(
            ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), ffprobe: nil,
            encoders: ["mpeg4", "aac", "pcm_s16le"], muxers: ["mp4", "mov", "wav", "webm"])
        let engine = OrbitEngine(capabilities: Capabilities(
            imageTypeIdentifiers: ["public.png"], media: minimal, supportsSubjectMask: false))
        XCTAssertEqual(engine.allTargets(forExtension: "avi").map { $0.id }, ["mp4", "mov", "wav"],
                       "webm lacks its encoders, mkv its muxer, mp3 its encoder")
        XCTAssertEqual(engine.allTargets(forExtension: "flac").map { $0.id }, ["wav"])
        XCTAssertTrue(engine.tools.contains { $0.id == "media-compress" })
    }

    func testProbeParsingAndPlaylistFormatsAreBlocked() throws {
        let json = """
        {"streams":[
          {"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30000/1001","disposition":{"attached_pic":0}},
          {"codec_type":"audio","codec_name":"aac","channels":2}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"12.500000"}}
        """
        let info = try FFprobe.parse(Data(json.utf8), name: "clip.mp4")
        XCTAssertTrue(info.hasVideo && info.hasAudio)
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.duration, 12.5)
        XCTAssertEqual(info.frameRate ?? 0, 29.97, accuracy: 0.01)

        let playlist = #"{"streams":[{"codec_type":"video"}],"format":{"format_name":"hls"}}"#
        assertOrbitError(try FFprobe.parse(Data(playlist.utf8), name: "evil.mp4")) {
            if case .invalidInput = $0 { return true }
            return false
        }
        let coverOnly = #"{"streams":[{"codec_type":"video","disposition":{"attached_pic":1}}],"format":{"format_name":"mp3"}}"#
        assertOrbitError(try FFprobe.parse(Data(coverOnly.utf8), name: "cover.mp3")) {
            if case .malformed = $0 { return true }
            return false
        }
    }
}

final class MediaTests: XCTestCase {
    private var directory: URL!
    private let engine = Fixtures.engine

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPlaylistDisguisedAsMediaIsRejectedBeforeAnyEngineRuns() throws {
        let playlist = directory.appendingPathComponent("evil.mp4")
        try Data("#EXTM3U\n#EXTINF:10,\nfile:///etc/passwd\n".utf8).write(to: playlist)
        let concat = directory.appendingPathComponent("list.mov")
        try Data("ffconcat version 1.0\nfile /etc/hosts\n".utf8).write(to: concat)

        for (source, target) in [(playlist, "mov"), (concat, "mp4")] {
            assertOrbitError(try self.engine.convert(source, to: target)) {
                if case .invalidInput = $0 { return true }
                return false
            }
        }
        assertOrbitError(try self.engine.runTool("media-snapshot", sources: [playlist])) {
            if case .invalidInput = $0 { return true }
            return false
        }
        XCTAssertEqual(Fixtures.listing(directory), ["evil.mp4", "list.mov"])
    }

    func testEmptyAndGarbageMediaFailCleanly() throws {
        let empty = directory.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        let garbage = directory.appendingPathComponent("noise.wav")
        try Data("RIFFnot really audio".utf8).write(to: garbage)
        for source in [empty, garbage] {
            XCTAssertThrowsError(try engine.convert(source, to: "aiff"))
        }
        XCTAssertEqual(Fixtures.listing(directory), ["empty.wav", "noise.wav"])
    }

    func testNativeWAVToAIFFKeepsLengthAndRate() throws {
        let source = try Fixtures.wav(at: directory.appendingPathComponent("tone.wav"), seconds: 0.5, sampleRate: 8000)
        let result = try engine.convert(source, to: "aiff")
        XCTAssertEqual(result.outputs.map { $0.lastPathComponent }, ["tone.aiff"])
        XCTAssertFalse(result.notes.isEmpty, "the AVFoundation route is disclosed")

        let converted = try AVAudioFile(forReading: result.outputs[0])
        XCTAssertEqual(converted.length, 4000)
        XCTAssertEqual(converted.fileFormat.sampleRate, 8000)
        XCTAssertEqual(converted.fileFormat.channelCount, 1)
    }

    func testNativeAudioConversionCanBeCancelled() throws {
        let source = try Fixtures.wav(at: directory.appendingPathComponent("tone.wav"))
        let token = CancellationToken()
        token.cancel()
        assertOrbitError(try self.engine.convert(source, to: "aiff", token: token)) { $0 == .cancelled }
        XCTAssertEqual(Fixtures.listing(directory), ["tone.wav"])
    }

    /// Exercises a real ffmpeg when one is installed; skipped otherwise.
    func testInstalledFFmpegConvertsAndValidates() throws {
        let capabilities = Capabilities.detect()
        guard let toolchain = capabilities.media else {
            throw XCTSkip("ffmpeg is not installed in /opt/homebrew/bin or /usr/local/bin")
        }
        guard let flac = FormatRegistry.mediaSpec(id: "flac"), flac.isAvailable(in: toolchain) else {
            throw XCTSkip("this ffmpeg build cannot write FLAC")
        }
        let live = OrbitEngine(capabilities: capabilities)
        let source = try Fixtures.wav(at: directory.appendingPathComponent("tone.wav"), seconds: 1, sampleRate: 44_100)

        let result = try live.convert(source, to: "flac")
        XCTAssertEqual(result.outputs.map { $0.lastPathComponent }, ["tone.flac"])
        XCTAssertTrue(try Data(contentsOf: result.outputs[0]).starts(with: Data("fLaC".utf8)))

        let trimmed = try live.runTool(
            "media-trim", sources: [source], options: ToolOptions(["start": 0.25, "end": 0.75]))
        XCTAssertEqual(trimmed.outputs.map { $0.lastPathComponent }, ["tone-trimmed.wav"])
        let file = try AVAudioFile(forReading: trimmed.outputs[0])
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 0.5, accuracy: 0.05)

        XCTAssertEqual(
            Fixtures.listing(directory), ["tone-trimmed.wav", "tone.flac", "tone.wav"], "no staging folders remain")
    }
}
