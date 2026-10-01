import Foundation

/// Every failure surfaced by OrbitCore. Messages are written for end users.
public enum OrbitError: Error, Equatable, LocalizedError {
    case cancelled
    case unsupported(String)
    case invalidInput(String)
    case invalidOptions(String)
    case malformed(String)
    case sourceChanged(String)
    case outputNotWritable(String)
    case missingTool(String)
    case engineFailure(String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Cancelled."
        case .unsupported(let message), .invalidInput(let message), .invalidOptions(let message),
             .malformed(let message), .sourceChanged(let message), .outputNotWritable(let message),
             .missingTool(let message), .engineFailure(let message), .validationFailed(let message):
            return message
        }
    }

    /// A user-presentable description for any error.
    public static func describe(_ error: Error) -> String {
        if let orbit = error as? OrbitError, let text = orbit.errorDescription { return text }
        return error.localizedDescription
    }
}
