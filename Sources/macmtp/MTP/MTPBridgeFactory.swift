import Foundation

public enum MTPBridgeEngine: String, CaseIterable, Sendable {
    case libmtp
}

public enum MTPBridgeFactory {
    public static func selectedEngine(defaults: UserDefaults = .standard) -> MTPBridgeEngine {
        guard let raw = defaults.string(forKey: "mtpEngine"),
              let engine = MTPBridgeEngine(rawValue: raw) else {
            return .libmtp
        }
        return engine
    }

    public static func sharedBridge(defaults: UserDefaults = .standard) -> any MTPBridgeProtocol {
        LibMTPBridge.shared
    }
}
