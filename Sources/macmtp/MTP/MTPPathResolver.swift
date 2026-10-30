import Foundation

public enum MTPPathResolver {
    public static func normalize(_ path: String) -> String {
        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !parts.isEmpty else { return "/" }
        return "/" + parts.joined(separator: "/")
    }

    public static func parentPath(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }
        let ns = normalized as NSString
        let parent = ns.deletingLastPathComponent
        return normalize(parent.isEmpty ? "/" : parent)
    }

    public static func fileName(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "" }
        return (normalized as NSString).lastPathComponent
    }

    public static func join(parent: String, name: String) -> String {
        let cleanParent = normalize(parent)
        let cleanName = name
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
        guard !cleanName.isEmpty else { return cleanParent }
        if cleanParent == "/" {
            return "/" + cleanName
        }
        return cleanParent + "/" + cleanName
    }
}
