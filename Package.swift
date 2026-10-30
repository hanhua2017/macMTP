// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let env = ProcessInfo.processInfo.environment
#if arch(arm64)
let runtimeArch = "arm64"
#else
let runtimeArch = "x86_64"
#endif
let defaultRuntimePrefix = "\(packageDir)/thirdparty/runtime/\(runtimeArch)-macos14"
let runtimePrefix = env["MACMTP_RUNTIME_PREFIX"] ?? (
    env["MACMTP_LIBMTP_ROOT"] == nil && FileManager.default.fileExists(atPath: "\(defaultRuntimePrefix)/lib/libmtp.9.dylib")
        ? defaultRuntimePrefix : nil
)
let hostArch = env["HOSTTYPE"] ?? env["RUNNER_ARCH"] ?? env["NATIVE_ARCH"] ?? ""
let libusbLibDir = env["MACMTP_LIBUSB_LIB_DIR"] ?? runtimePrefix.map { "\($0)/lib" }
let defaultLibusbSearchPaths = hostArch.contains("arm64")
    || hostArch == "ARM64"
    ? ["/opt/homebrew/lib", "/usr/local/lib"]
    : ["/usr/local/lib", "/opt/homebrew/lib"]
let existingDefaultLibusbSearchPaths = defaultLibusbSearchPaths.filter {
    FileManager.default.fileExists(atPath: $0)
}
let selectedLibusbSearchPaths = libusbLibDir.map { [$0] }
    ?? (existingDefaultLibusbSearchPaths.isEmpty ? defaultLibusbSearchPaths : existingDefaultLibusbSearchPaths)
let libusbLinkerFlags = selectedLibusbSearchPaths
    .flatMap { ["-L\($0)"] } + ["-lusb-1.0"]
let libmtpRoot = env["MACMTP_LIBMTP_ROOT"] ?? "\(packageDir)/thirdparty/sources/libmtp-1.1.23"
let libmtpIncludeDir = runtimePrefix.map { "\($0)/include" } ?? "\(libmtpRoot)/src"
let libmtpLibDir = env["MACMTP_LIBMTP_LIB_DIR"] ?? runtimePrefix.map { "\($0)/lib" } ?? "\(libmtpRoot)/src/.libs"
let runtimeLibrarySearchFlags = runtimePrefix.map { ["-L\($0)/lib"] } ?? [
    "-L/opt/homebrew/opt/libusb/lib",
    "-L/opt/homebrew/opt/libgcrypt/lib",
    "-L/opt/homebrew/opt/libgpg-error/lib",
]
let libmtpLinkerFlags = ["-L\(libmtpLibDir)"] + runtimeLibrarySearchFlags + [
    "-lmtp", "-lusb-1.0", "-lgcrypt", "-lgpg-error", "-liconv",
]

let package = Package(
    name: "macmtp",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CLibMTPBridge",
            path: "Sources/CLibMTPBridge",
            sources: ["libmtp_bridge.c"],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(libmtpIncludeDir)"])
            ],
            linkerSettings: [
                .unsafeFlags(libmtpLinkerFlags),
                .linkedFramework("IOKit")
            ]
        ),
        // Main macOS application target
        .executableTarget(
            name: "macmtp",
            dependencies: [
                "CLibMTPBridge"
            ],
            path: "Sources/macmtp",

            linkerSettings: [
                .unsafeFlags(libusbLinkerFlags),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "macmtpTests",
            dependencies: [
                "macmtp"
            ],
            path: "Tests/macmtpTests"
        )
    ]
)
