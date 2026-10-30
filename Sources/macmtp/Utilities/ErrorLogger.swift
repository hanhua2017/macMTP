import Foundation

public struct ErrorLogger {
    private static let debugLogURL = URL(fileURLWithPath: "/tmp/macmtp-debug.log")
    private static let debugLogQueue = DispatchQueue(label: "macMTP.debug-log", qos: .utility)

    public static func debug(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        debugLogQueue.async {
            if FileManager.default.fileExists(atPath: debugLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: debugLogURL) {
                    _ = try? handle.seekToEnd()
                    _ = try? handle.write(contentsOf: data)
                    _ = try? handle.close()
                }
            } else {
                try? data.write(to: debugLogURL, options: .atomic)
            }
        }
    }

    public static func log(_ error: Error, message: String? = nil, userInfo: [String: Any]? = nil) {
        let errMsg = message.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription
        debug("ERROR \(errMsg)")
    }
}
