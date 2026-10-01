import Foundation
import AVFoundation
import CoreGraphics

private final class BlockingBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Runs an async AVFoundation call from OrbitCore's synchronous engines.
/// Callers are worker threads or the CLI, never the Swift concurrency pool.
private func runBlocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = BlockingBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            box.result = .success(try await operation())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.result else {
        throw OrbitError.engineFailure("The media operation produced no result.")
    }
    return try result.get()
}

/// The AVFoundation subset that works without ffmpeg: MOV/MP4 conversion,
/// trim, mute and snapshot for video, and PCM/AAC conversion for audio.
enum NativeMedia {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let audioExtensions: Set<String> = ["wav", "aiff", "aif", "aifc", "caf", "m4a", "mp3", "flac", "aac"]

    static let videoTargets = ["mp4", "mov"]
    static let audioTargets = ["m4a", "wav", "aiff"]

    static func probe(_ url: URL) -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        let ext = url.pathExtension.lowercased()
        return try? runBlocking { () async throws -> MediaInfo in
            var info = MediaInfo(formatName: ext)
            let duration = try await asset.load(.duration)
            if duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
               duration.seconds <= ToolOptions.maximumSeconds {
                info.duration = duration.seconds
            }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                let rate = try await track.load(.nominalFrameRate)
                info.hasVideo = true
                info.width = FFprobe.saneDimension(Double(abs(size.width)))
                info.height = FFprobe.saneDimension(Double(abs(size.height)))
                info.frameRate = rate.isFinite && rate > 0 && rate <= 1000 ? Double(rate) : nil
            }
            info.hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            guard info.hasVideo || info.hasAudio else {
                throw OrbitError.malformed("No audio or video tracks.")
            }
            return info
        }
    }

    /// True when the system frameworks can really open the file as audio or
    /// video. Used to validate outputs when no ffmpeg is installed.
    static func canOpen(_ url: URL) -> Bool {
        if (try? AVAudioFile(forReading: url)) != nil { return true }
        return probe(url) != nil
    }

    static func fileType(forExtension ext: String) -> AVFileType {
        ext == "mov" ? .mov : .mp4
    }

    /// Re-exports a movie, optionally trimmed and/or without its audio.
    static func exportVideo(
        _ source: URL, to output: URL, fileType: AVFileType, start: Double? = nil, end: Double? = nil,
        dropAudio: Bool = false, token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        var exportAsset: AVAsset = asset

        if dropAudio {
            let composition = AVMutableComposition()
            let loaded: (AVAssetTrack, CMTime, CGAffineTransform)
            do {
                loaded = try runBlocking { () async throws -> (AVAssetTrack, CMTime, CGAffineTransform) in
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw OrbitError.malformed("\(name) has no video track.")
                    }
                    return (track, try await asset.load(.duration), try await track.load(.preferredTransform))
                }
            } catch let error as OrbitError {
                throw error
            } catch {
                throw OrbitError.malformed("\(name) could not be read: \(error.localizedDescription)")
            }
            guard let target = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw OrbitError.engineFailure("Could not prepare the video track.")
            }
            do {
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: loaded.1), of: loaded.0, at: .zero)
            } catch {
                throw OrbitError.engineFailure("Could not copy the video track: \(error.localizedDescription)")
            }
            target.preferredTransform = loaded.2
            exportAsset = composition
        }

        guard let session = AVAssetExportSession(asset: exportAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw OrbitError.unsupported("\(name) cannot be exported by AVFoundation. Install ffmpeg for this file.")
        }
        session.outputURL = output
        session.outputFileType = fileType
        if start != nil || end != nil {
            let from = CMTime(seconds: start ?? 0, preferredTimescale: 600)
            let to = end.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity
            session.timeRange = CMTimeRange(start: from, end: to)
        }

        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        let handler = token?.onCancel { session.cancelExport() }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            progress?(Double(session.progress))
        }
        if let handler { token?.removeHandler(handler) }

        if token?.isCancelled == true || session.status == .cancelled {
            throw OrbitError.cancelled
        }
        guard session.status == .completed else {
            throw OrbitError.engineFailure(
                "AVFoundation could not export \(name): \(session.error?.localizedDescription ?? "unknown error")")
        }
    }

    static func snapshot(_ source: URL, at seconds: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            return try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        } catch {
            throw OrbitError.engineFailure(
                "Could not read a frame from \(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Converts audio with AVAudioFile. The container is chosen from the
    /// output URL's extension, so the staged file must carry the right one.
    static func convertAudio(
        _ source: URL, to output: URL, formatID: String, token: CancellationToken?, progress: ((Double) -> Void)?
    ) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw OrbitError.malformed("\(source.lastPathComponent) could not be read as audio: \(error.localizedDescription)")
        }
        let format = input.processingFormat
        var settings: [String: Any] = [
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        switch formatID {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        case "wav", "aiff":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = formatID == "aiff"
        default:
            throw OrbitError.unsupported("Audio cannot be written as \(formatID) without ffmpeg.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw OrbitError.engineFailure("Could not allocate an audio buffer.")
        }
        do {
            let writer = try AVAudioFile(
                forWriting: output, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            let total = Double(max(input.length, 1))
            while input.framePosition < input.length {
                try token?.check()
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try writer.write(from: buffer)
                progress?(Double(input.framePosition) / total)
            }
        } catch let error as OrbitError {
            throw error
        } catch {
            throw OrbitError.engineFailure("Audio conversion failed: \(error.localizedDescription)")
        }
    }
}
