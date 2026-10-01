import Foundation
import OrbitCore

let helpText = """
orbitdrop-cli — offline file conversion (OrbitDrop command line)

USAGE
  orbitdrop-cli inspect <file>...
  orbitdrop-cli list-formats [<file>...]
  orbitdrop-cli list-tools [<file>...]
  orbitdrop-cli convert --to <format> [--options JSON] [--output-dir DIR] <file>...
  orbitdrop-cli tool --name <tool> [--options JSON] [--output-dir DIR] <file>...
  orbitdrop-cli capabilities
  orbitdrop-cli help

COMMANDS
  inspect        Show kind, details, conversion targets and tools for each file.
  list-formats   Without files: every format offered on this Mac, per kind.
                 With files: the formats all of them can be converted to.
  list-tools     Without files: every available tool and its options.
                 With files: the tools that accept all of them.
  convert        Convert each file to <format>. Prints one output file URL per line.
  tool           Run a tool. Combining tools (pdf-merge, media-join, archive-zip, ...)
                 turn all files into one output; other tools run once per file.
  capabilities   Show native image formats and the detected ffmpeg, if any.

OPTIONS
  --to FORMAT        Target format id, e.g. png, jpg, pdf, mp4, srt.
  --name TOOL        Tool id, e.g. image-crop (see list-tools).
  --options JSON     Tool or conversion options as a JSON object,
                     e.g. '{"x":0,"y":0,"width":640,"height":480}'.
  --output-dir DIR   Write outputs to DIR instead of beside each source.
  --ffmpeg PATH      Absolute path to ffmpeg, or "none" to use native engines only.
                     Default: $ORBITDROP_FFMPEG, /opt/homebrew/bin, /usr/local/bin.
  --                 Treat everything after it as file paths.

BEHAVIOUR
  Sources are never modified and existing files are never overwritten; a name
  that is taken gets a numeric suffix (photo-2.jpg). Output URLs go to stdout,
  notes and errors to stderr. Exit status: 0 success, 1 if any job failed or
  was cancelled, 2 for usage errors. Ctrl-C cancels cleanly. No network access.
"""

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

struct UsageError: Error {
    let message: String
}

struct Arguments {
    var flags: [String: String] = [:]
    var paths: [String] = []

    static let valueFlags: Set<String> = ["--to", "--name", "--options", "--output-dir", "--ffmpeg"]

    init(_ raw: [String]) throws {
        var index = 0
        var onlyPaths = false
        while index < raw.count {
            let item = raw[index]
            if onlyPaths || !item.hasPrefix("--") {
                paths.append(item)
            } else if item == "--" {
                onlyPaths = true
            } else if Arguments.valueFlags.contains(item) {
                guard index + 1 < raw.count else {
                    throw UsageError(message: "\(item) needs a value.")
                }
                flags[item] = raw[index + 1]
                index += 1
            } else {
                throw UsageError(message: "Unknown option \(item).")
            }
            index += 1
        }
    }

    var urls: [URL] {
        paths.map { URL(fileURLWithPath: $0) }
    }

    func outputDirectory() throws -> URL? {
        guard let path = flags["--output-dir"] else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UsageError(message: "--output-dir is not an existing folder: \(path)")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

func describe(_ parameter: ToolParameter) -> String {
    var text = "      \(parameter.key): "
    switch parameter.kind {
    case .number(let value):
        text += "number" + (value.map { " (default \($0))" } ?? "")
    case .text(let value):
        text += "text" + (value.isEmpty ? "" : " (default \"\(value)\")")
    case .choice(let options, let value):
        text += options.joined(separator: " | ") + " (default \(value))"
    case .toggle(let value):
        text += "true | false (default \(value))"
    }
    return parameter.help.isEmpty ? text : text + " — " + parameter.help
}

func printTools(_ tools: [ToolDescriptor]) {
    for tool in tools {
        let scope = tool.combinesInputs ? " [combines all inputs]" : ""
        print("  \(tool.id)\(scope) — \(tool.summary)")
        tool.parameters.forEach { print(describe($0)) }
    }
}

func run(_ raw: [String]) throws -> Int32 {
    guard let command = raw.first else {
        print(helpText)
        return 2
    }
    if ["help", "--help", "-h"].contains(command) {
        print(helpText)
        return 0
    }
    let arguments = try Arguments(Array(raw.dropFirst()))
    let engine = OrbitEngine(capabilities: .detect(ffmpegPath: arguments.flags["--ffmpeg"]))
    let urls = arguments.urls

    switch command {
    case "capabilities":
        let writable = FormatRegistry.imageFormats.filter(engine.capabilities.canWrite).map { $0.id }
        print("Native image output: \(writable.joined(separator: ", "))")
        if let media = engine.capabilities.media {
            print("ffmpeg: \(media.ffmpeg.path)")
            print("ffprobe: \(media.ffprobe?.path ?? "not found (ffmpeg's own stream report is used to inspect and validate media)")")
            let formats = FormatRegistry.mediaFormats.filter { $0.isAvailable(in: media) }.map { $0.id }
            print("Media output: \(formats.joined(separator: ", "))")
            print("Hardware H.264: \(media.encoders.contains("h264_videotoolbox") ? "available" : "not available")")
        } else {
            print("ffmpeg: not found — media work is limited to the AVFoundation subset")
        }
        print("Tools: \(engine.tools.count)")
        return 0

    case "inspect":
        guard !urls.isEmpty else { throw UsageError(message: "inspect needs at least one file.") }
        var failed = false
        for url in urls {
            do {
                let report = try engine.inspect(url)
                print("\(report.url.path)")
                print("  Kind: \(report.kind.displayName)")
                print("  Size: \(report.sizeBytes) bytes")
                for detail in report.details { print("  \(detail.key): \(detail.value)") }
                let targets = report.targets.map { $0.id }.joined(separator: ", ")
                print("  Convert to: \(targets.isEmpty ? "(nothing)" : targets)")
                let tools = report.tools.map { $0.id }.joined(separator: ", ")
                print("  Tools: \(tools.isEmpty ? "(none)" : tools)")
            } catch {
                printError("\(url.path): \(OrbitError.describe(error))")
                failed = true
            }
        }
        return failed ? 1 : 0

    case "list-formats":
        if urls.isEmpty {
            let samples: [(String, String)] = [
                ("Image", "png"), ("PDF", "pdf"), ("Document", "txt"), ("Subtitles", "srt"),
                ("Video", "mov"), ("Audio", "wav"),
            ]
            for (label, ext) in samples {
                let ids = engine.allTargets(forExtension: ext).map { $0.id }
                print("\(label): \(ids.isEmpty ? "(none)" : ids.joined(separator: ", "))")
            }
            if engine.capabilities.media == nil {
                print("Note: ffmpeg was not found; video and audio lists show the AVFoundation subset for MOV/MP4 and common audio files.")
            }
        } else {
            let batch = engine.commonTargets(for: urls)
            for format in batch.formats { print("\(format.id)\t\(format.title)") }
            for url in batch.unsupported { printError("No conversions for \(url.lastPathComponent)") }
            if batch.formats.isEmpty { printError("These files have no conversion target in common.") }
        }
        return 0

    case "list-tools":
        printTools(urls.isEmpty ? engine.tools : engine.commonTools(for: urls))
        return 0

    case "convert", "tool":
        guard !urls.isEmpty else { throw UsageError(message: "\(command) needs at least one file.") }
        let options: ToolOptions
        do {
            options = try ToolOptions(json: arguments.flags["--options"] ?? "")
        } catch {
            throw UsageError(message: OrbitError.describe(error))
        }
        let action: BatchAction
        if command == "convert" {
            guard let format = arguments.flags["--to"] else { throw UsageError(message: "convert needs --to <format>.") }
            action = .convert(formatID: format, options: options)
        } else {
            guard let name = arguments.flags["--name"] else { throw UsageError(message: "tool needs --name <tool>.") }
            action = .tool(id: name, options: options)
        }
        let outputDirectory = try arguments.outputDirectory()

        // Ctrl-C cancels the running job; staged files are cleaned up.
        let token = CancellationToken()
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { token.cancel() }
        interrupt.resume()

        let outcomes = engine.runBatch(sources: urls, action: action, outputDirectory: outputDirectory, token: token)
        var failed = false
        for outcome in outcomes {
            let names = outcome.sources.map { $0.lastPathComponent }.joined(separator: ", ")
            switch outcome.status {
            case .succeeded(let result):
                result.outputs.forEach { print($0.absoluteString) }
                result.notes.forEach { printError("note: \(names): \($0)") }
            case .skipped(let reason):
                printError("skipped: \(names): \(reason)")
            case .failed(let reason):
                printError("error: \(names): \(reason)")
                failed = true
            case .cancelled:
                printError("cancelled: \(names)")
                failed = true
            case .running:
                break
            }
        }
        return failed ? 1 : 0

    default:
        throw UsageError(message: "Unknown command \"\(command)\".")
    }
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch let error as UsageError {
    printError("orbitdrop-cli: \(error.message)\nRun \"orbitdrop-cli help\" for usage.")
    exit(2)
} catch {
    printError("orbitdrop-cli: \(OrbitError.describe(error))")
    exit(1)
}
