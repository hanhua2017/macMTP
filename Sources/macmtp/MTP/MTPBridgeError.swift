import Foundation

public enum MTPBridgeError: Error, LocalizedError {
    case deviceNotConnected
    case transferFailed(String)
    case operationFailed(String)
    case invalidResponse
    case serializationError
    case operationInProgress
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "No MTP device connected, or device is busy."
        case .transferFailed(let message):
            return "File transfer failed: \(message)"
        case .operationFailed(let message):
            return "MTP operation failed: \(message)"
        case .invalidResponse:
            return "Received an invalid or malformed response from the MTP subsystem."
        case .serializationError:
            return "Failed to serialize input arguments for the MTP subsystem."
        case .operationInProgress:
            return "Another MTP operation is currently in progress."
        case .timedOut(let message):
            return "MTP operation timed out: \(message)"
        }
    }
}

