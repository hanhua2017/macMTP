import Foundation
import SwiftUI
import Darwin

@MainActor
public final class MTPDeviceManager: ObservableObject {
    public static let shared = MTPDeviceManager()


    @Published public var isConnected = false
    @Published public var deviceInfo: MTPDeviceInfo?
    @Published public var storages: [MTPStorageInfo] = []
    @Published public var selectedStorageId: UInt32?
    @Published public var currentMTPPath = "/"
    @Published public var mtpFiles: [FileNode] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var isReleasingMTPPort = false
    @Published public var capabilities: MTPDeviceCapabilities = .unknown


    private var backHistory: [String] = []
    private var forwardHistory: [String] = []


    private let bridge: any MTPBridgeProtocol = MTPBridgeFactory.sharedBridge()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private var refreshGeneration: UInt64 = 0
    private var isRefreshingFiles = false
    private var needsRefreshAfterCurrent = false

    private init() {}

    public struct DeleteProgress: Equatable, Sendable {
        public let currentPath: String
        public let completedCount: Int
        public let totalCount: Int

        public var fractionCompleted: Double {
            guard totalCount > 0 else { return 0 }
            return min(1, max(0, Double(completedCount) / Double(totalCount)))
        }
    }

    public typealias MoveProgress = DeleteProgress

    public func forceReleaseMTPPort() async {
        guard !isReleasingMTPPort else { return }

        ErrorLogger.debug("MTPDeviceManager.forceReleaseMTPPort begin")
        isReleasingMTPPort = true
        errorMessage = "Requesting administrator permission to release the macOS MTP owner..."

        let uid = getuid()
        let command = """
        for attempt in 1 2 3; do
        launchctl disable gui/\(uid)/com.apple.ptpcamerad 2>/dev/null || true
        launchctl disable gui/\(uid)/com.apple.icdd 2>/dev/null || true
        launchctl asuser \(uid) launchctl bootout gui/\(uid)/com.apple.ptpcamerad 2>/dev/null || true
        launchctl asuser \(uid) launchctl bootout gui/\(uid)/com.apple.icdd 2>/dev/null || true
        launchctl asuser \(uid) launchctl bootout gui/\(uid) /System/Library/LaunchAgents/com.apple.ptpcamerad.plist 2>/dev/null || true
        launchctl asuser \(uid) launchctl bootout gui/\(uid) /System/Library/LaunchAgents/com.apple.icdd.plist 2>/dev/null || true
        launchctl asuser \(uid) launchctl remove com.apple.ptpcamerad 2>/dev/null || true
        launchctl asuser \(uid) launchctl remove com.apple.icdd 2>/dev/null || true
        launchctl bootout gui/\(uid)/com.apple.ptpcamerad 2>/dev/null || true
        launchctl bootout gui/\(uid)/com.apple.icdd 2>/dev/null || true
        launchctl bootout gui/\(uid) /System/Library/LaunchAgents/com.apple.ptpcamerad.plist 2>/dev/null || true
        launchctl bootout gui/\(uid) /System/Library/LaunchAgents/com.apple.icdd.plist 2>/dev/null || true
        launchctl remove com.apple.ptpcamerad 2>/dev/null || true
        launchctl remove com.apple.icdd 2>/dev/null || true
        launchctl kill SIGKILL gui/\(uid)/com.apple.ptpcamerad 2>/dev/null || true
        launchctl kill SIGKILL gui/\(uid)/com.apple.icdd 2>/dev/null || true
        pkill -9 -x ptpcamerad 2>/dev/null || true
        pkill -9 -x icdd 2>/dev/null || true
        pkill -9 -x mscamerad-xpc 2>/dev/null || true
        sleep 1
        if ! pgrep -x ptpcamerad >/dev/null 2>&1; then
            break
        fi
        done
        """

        do {
            ErrorLogger.debug("MTPDeviceManager.forceReleaseMTPPort requesting single privileged release")
            _ = try await Self.runPrivilegedShell(command)
            ErrorLogger.debug("MTPDeviceManager.forceReleaseMTPPort release commands completed")

            for attempt in 1...3 {
                ErrorLogger.debug("MTPDeviceManager.forceReleaseMTPPort attempt=\(attempt)")
                errorMessage = "Waiting for the MTP interface to become available..."
                let ownerSnapshot = try await Self.waitForMTPPortRelease(timeoutSeconds: attempt == 1 ? 10 : 5)
                ErrorLogger.debug("MTPDeviceManager.forceReleaseMTPPort ownerSnapshot=\(ownerSnapshot) attempt=\(attempt)")
                errorMessage = "Released macOS camera services. Reconnecting to MTP..."
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                if isConnected {
                    break
                }

                await connectDevice()

                if isConnected {
                    break
                }

                ErrorLogger.debug("MTPDeviceManager.forceReleaseMTPPort reconnect failed attempt=\(attempt)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            if !isConnected {
                errorMessage = "MTP was released but macMTP could not keep the interface. Unplug and reconnect the device, then press Fix MTP Connection again."
            }
        } catch {
            ErrorLogger.log(error, message: "Failed to release macOS MTP owner")
            errorMessage = "Failed to release MTP owner: \(error.localizedDescription)"
            ErrorLogger.debug("MTPDeviceManager.forceReleaseMTPPort failed error=\(error.localizedDescription)")
        }

        isReleasingMTPPort = false
        ErrorLogger.debug("MTPDeviceManager.forceReleaseMTPPort end")
    }


    public var canNavigateBack: Bool {
        !backHistory.isEmpty
    }

    public var canNavigateForward: Bool {
        !forwardHistory.isEmpty
    }

    private nonisolated static func runPrivilegedShell(_ command: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let escapedCommand = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escapedCommand)\" with administrator privileges"

            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let message = errorOutput.isEmpty ? output : errorOutput
                throw NSError(
                    domain: "macMTP.PrivilegedShell",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
                )
            }

            return output
        }.value
    }

    private nonisolated static func waitForMTPPortRelease(timeoutSeconds: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastSnapshot = ""

        while Date() < deadline {
            lastSnapshot = try await runShell(
                executable: "/usr/sbin/ioreg",
                arguments: ["-r", "-c", "IOUSBHostInterface", "-l", "-w", "0"]
            )

            let mtpBlock = block(containing: "MTP@0", in: lastSnapshot)
            if let mtpBlock {
                if !mtpBlock.contains("UsbExclusiveOwner") || mtpBlock.contains("pid") && mtpBlock.contains("macMTP") {
                    return ownerLine(from: mtpBlock) ?? "MTP interface has no exclusive owner"
                }
                if let owner = ownerLine(from: mtpBlock) {
                    ErrorLogger.debug("MTPDeviceManager.waitForMTPPortRelease owner=\(owner)")
                }
            } else {
                ErrorLogger.debug("MTPDeviceManager.waitForMTPPortRelease waiting for MTP interface")
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let mtpBlock = block(containing: "MTP@0", in: lastSnapshot) ?? lastSnapshot
        let owner = ownerLine(from: mtpBlock) ?? "unknown owner"
        throw NSError(
            domain: "macMTP.MTPPortRelease",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MTP interface is still held by \(owner)"]
        )
    }

    private nonisolated static func runShell(executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let message = errorOutput.isEmpty ? output : errorOutput
                throw NSError(
                    domain: "macMTP.Shell",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
                )
            }

            return output
        }.value
    }

    private nonisolated static func block(containing marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let start = text[..<range.lowerBound].lastIndex(of: "\n") ?? text.startIndex
        let remaining = text[range.lowerBound...]
        let end = remaining.range(of: "\n\n")?.lowerBound ?? text.endIndex
        return String(text[start..<end])
    }

    private nonisolated static func ownerLine(from block: String) -> String? {
        block
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("UsbExclusiveOwner") || $0.contains("IOUserClientCreator") }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }


    public func connectDevice() async {
        guard !isConnected else {
            ErrorLogger.debug("MTPDeviceManager.connectDevice skipped because already connected")
            return
        }
        guard !isLoading else { return }
        ErrorLogger.debug("MTPDeviceManager.connectDevice begin")
        isLoading = true
        errorMessage = nil

        do {
            let goDevInfo = try await bridge.initialize()
            ErrorLogger.debug("MTPDeviceManager.connectDevice initialize ok usb=\(String(describing: goDevInfo.usbDeviceInfo?.Product)) mtp=\(String(describing: goDevInfo.mtpDeviceInfo?.Model))")

            let capabilities = (try? await bridge.fetchCapabilities()) ?? .unknown
            ErrorLogger.debug("MTPDeviceManager.connectDevice capabilities move=\(capabilities.moveObject) copy=\(capabilities.copyObject) partialGet=\(capabilities.getPartialObject) partialSend=\(capabilities.sendPartialObject) edit=\(capabilities.editObjects)")
            
            let goStorages = try await bridge.fetchStorages()
            ErrorLogger.debug("MTPDeviceManager.connectDevice fetchStorages ok count=\(goStorages.count)")
            
            let mappedStorages = goStorages.map { item -> MTPStorageInfo in
                let desc = item.Info.StorageDescription
                let type = MTPStorageType.fromMTPCode(item.Info.StorageType)
                return MTPStorageInfo(
                    storageId: item.Sid,
                    description: desc.isEmpty ? "Internal Storage" : desc,
                    totalCapacity: item.Info.MaxCapability,
                    freeSpace: item.Info.FreeSpaceInBytes,
                    storageType: type
                )
            }

            let mappedDevInfo = MTPDeviceInfo(
                manufacturer: goDevInfo.mtpDeviceInfo?.Manufacturer ?? goDevInfo.usbDeviceInfo?.Manufacturer ?? "Unknown",
                model: goDevInfo.mtpDeviceInfo?.Model ?? goDevInfo.usbDeviceInfo?.Product ?? "MTP Device",
                serialNumber: goDevInfo.mtpDeviceInfo?.SerialNumber ?? goDevInfo.usbDeviceInfo?.SerialNumber ?? "000000",
                deviceVersion: goDevInfo.mtpDeviceInfo?.DeviceVersion ?? "1.0",
                storages: mappedStorages
            )

            self.deviceInfo = mappedDevInfo
            self.storages = mappedStorages
            self.capabilities = capabilities
            self.isConnected = true
            
            if let firstStorage = mappedStorages.first {
                self.selectedStorageId = firstStorage.storageId
                self.currentMTPPath = "/"
                self.backHistory.removeAll()
                self.forwardHistory.removeAll()
                await refreshFiles()
            }
            ErrorLogger.debug("MTPDeviceManager.connectDevice success connected=\(isConnected)")
        } catch {
            ErrorLogger.log(error, message: "MTP connection failed")
            self.errorMessage = "Failed to connect: \(error.localizedDescription)"
            self.isConnected = false
            self.deviceInfo = nil
            self.storages = []
            self.capabilities = .unknown
            self.selectedStorageId = nil
            self.mtpFiles = []
            ErrorLogger.debug("MTPDeviceManager.connectDevice failed error=\(error.localizedDescription)")
        }

        isLoading = false
        ErrorLogger.debug("MTPDeviceManager.connectDevice end isConnected=\(isConnected)")
    }

    public func disconnectDevice() async {
        ErrorLogger.debug("MTPDeviceManager.disconnectDevice begin isConnected=\(isConnected)")
        isLoading = true
        errorMessage = nil
        
        if FileTransferService.shared.activeBatch?.isActive == true {
            Task { @MainActor in
                FileTransferService.shared.cancelTransfer()
                FileTransferService.shared.postTransferNotification(
                    title: "Transfer Interrupted",
                    body: "Device disconnected during file transfer",
                    isError: true
                )
            }
        }
        
        do {
            try await bridge.dispose()
        } catch {
            ErrorLogger.log(error, message: "Failed to dispose MTP device cleanly")
        }
        
        self.isConnected = false
        self.deviceInfo = nil
        self.storages = []
        self.capabilities = .unknown
        self.selectedStorageId = nil
        self.mtpFiles = []
        self.currentMTPPath = "/"
        self.backHistory.removeAll()
        self.forwardHistory.removeAll()
        self.isLoading = false
        ErrorLogger.debug("MTPDeviceManager.disconnectDevice end")
    }

    public func refreshStorages() async {
        guard isConnected else { return }
        ErrorLogger.debug("MTPDeviceManager.refreshStorages begin")
        do {
            let goStorages = try await bridge.fetchStorages()
            ErrorLogger.debug("MTPDeviceManager.refreshStorages ok count=\(goStorages.count)")
            let mappedStorages = goStorages.map { item -> MTPStorageInfo in
                let desc = item.Info.StorageDescription
                let type = MTPStorageType.fromMTPCode(item.Info.StorageType)
                return MTPStorageInfo(
                    storageId: item.Sid,
                    description: desc.isEmpty ? "Internal Storage" : desc,
                    totalCapacity: item.Info.MaxCapability,
                    freeSpace: item.Info.FreeSpaceInBytes,
                    storageType: type
                )
            }
            self.storages = mappedStorages
            if let dev = self.deviceInfo {
                self.deviceInfo = MTPDeviceInfo(
                    manufacturer: dev.manufacturer,
                    model: dev.model,
                    serialNumber: dev.serialNumber,
                    deviceVersion: dev.deviceVersion,
                    storages: mappedStorages
                )
            }
        } catch {
            ErrorLogger.log(error, message: "Failed to refresh storages")
            ErrorLogger.debug("MTPDeviceManager.refreshStorages failed error=\(error.localizedDescription)")
        }
    }


    public func refreshFiles() async {
        guard isConnected, let storageId = selectedStorageId else { return }
        if isRefreshingFiles {
            needsRefreshAfterCurrent = true
            ErrorLogger.debug("MTPDeviceManager.refreshFiles coalesced path=\(currentMTPPath)")
            return
        }

        isRefreshingFiles = true
        isLoading = true
        errorMessage = nil
        defer {
            isRefreshingFiles = false
            isLoading = false
            ErrorLogger.debug("MTPDeviceManager.refreshFiles idle")
        }

        repeat {
            needsRefreshAfterCurrent = false

            refreshGeneration += 1
            let generation = refreshGeneration
            let requestedPath = currentMTPPath
            ErrorLogger.debug("MTPDeviceManager.refreshFiles begin storageId=\(storageId) path=\(requestedPath)")

            do {
                let goFiles = try await bridge.listDirectory(storageId: storageId, path: requestedPath, recursive: false)

                // If the user navigated again while this request was in flight,
                // keep the stale result out of the UI and let the coalesced pass
                // below fetch the latest path.
                guard generation == refreshGeneration, requestedPath == currentMTPPath else {
                    ErrorLogger.debug("MTPDeviceManager.refreshFiles stale path=\(requestedPath) current=\(currentMTPPath)")
                    needsRefreshAfterCurrent = true
                    continue
                }

                let mapped = goFiles.map { item -> FileNode in
                    let modDate = dateFormatter.date(from: item.dateAdded) ?? Date()
                    return FileNode(
                        name: item.name,
                        path: item.path,
                        parentPath: item.parentPath,
                        isDirectory: item.isFolder,
                        size: item.size,
                        modificationDate: modDate,
                        objectId: item.objectId,
                        parentId: item.parentId,
                        isSelected: false
                    )
                }
                self.mtpFiles = mapped
                ErrorLogger.debug("MTPDeviceManager.refreshFiles ok count=\(mapped.count) path=\(requestedPath)")

            } catch {
                guard generation == refreshGeneration, requestedPath == currentMTPPath else {
                    needsRefreshAfterCurrent = true
                    continue
                }
                ErrorLogger.log(error, message: "Failed to list MTP directory")
                self.errorMessage = "Failed to list directory: \(error.localizedDescription)"
                self.mtpFiles = []
                ErrorLogger.debug("MTPDeviceManager.refreshFiles failed error=\(error.localizedDescription)")
            }

            ErrorLogger.debug("MTPDeviceManager.refreshFiles end")
        } while needsRefreshAfterCurrent
    }

    public func navigateTo(path: String) async {
        guard isConnected else { return }
        if path == currentMTPPath { return }
        
        backHistory.append(currentMTPPath)
        forwardHistory.removeAll()
        
        currentMTPPath = path
        await refreshFiles()
    }

    public func navigateUp() async {
        guard isConnected else { return }
        if currentMTPPath == "/" || currentMTPPath.isEmpty { return }
        
        let components = currentMTPPath.split(separator: "/")
        if components.isEmpty {
            await navigateTo(path: "/")
        } else {
            let parent = "/" + components.dropLast().joined(separator: "/")
            await navigateTo(path: parent)
        }
    }

    public func navigateBack() async {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(currentMTPPath)
        currentMTPPath = previous
        await refreshFiles()
    }

    public func navigateForward() async {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(currentMTPPath)
        currentMTPPath = next
        await refreshFiles()
    }

    public func selectStorage(_ storageId: UInt32) async {
        guard selectedStorageId != storageId else { return }
        selectedStorageId = storageId
        currentMTPPath = "/"
        backHistory.removeAll()
        forwardHistory.removeAll()
        await refreshFiles()
    }


    public func createFolder(name: String) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw MTPBridgeError.deviceNotConnected
        }
        
        let pathSeparator = currentMTPPath == "/" ? "" : "/"
        let fullPath = "\(currentMTPPath)\(pathSeparator)\(name)"
        
        try await bridge.makeDirectory(storageId: storageId, path: fullPath)
        await refreshFiles()
    }

    public func deleteFiles(
        paths: [String],
        onProgress: ((DeleteProgress) -> Void)? = nil
    ) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw MTPBridgeError.deviceNotConnected
        }

        for (index, path) in paths.enumerated() {
            onProgress?(DeleteProgress(currentPath: path, completedCount: index, totalCount: paths.count))
            try await bridge.deleteFiles(storageId: storageId, paths: [path])
            onProgress?(DeleteProgress(currentPath: path, completedCount: index + 1, totalCount: paths.count))
        }

        await refreshFiles()
    }

    public func renameFile(path: String, newName: String) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw MTPBridgeError.deviceNotConnected
        }
        
        try await bridge.renameFile(storageId: storageId, path: path, newName: newName)
        await refreshFiles()
    }

    public func moveFiles(
        paths: [String],
        destinationParentPath: String,
        onProgress: ((MoveProgress) -> Void)? = nil
    ) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw MTPBridgeError.deviceNotConnected
        }
        guard capabilities.moveObject else {
            throw MTPBridgeError.operationFailed("This MTP device does not advertise MoveObject support.")
        }

        for (index, path) in paths.enumerated() {
            onProgress?(MoveProgress(currentPath: path, completedCount: index, totalCount: paths.count))
            try await bridge.moveFile(
                storageId: storageId,
                sourcePath: path,
                destinationParentPath: destinationParentPath
            )
            onProgress?(MoveProgress(currentPath: path, completedCount: index + 1, totalCount: paths.count))
        }

        await refreshFiles()
    }

    public func copyFiles(
        paths: [String],
        destinationParentPath: String,
        onProgress: ((MoveProgress) -> Void)? = nil
    ) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw MTPBridgeError.deviceNotConnected
        }
        guard capabilities.copyObject else {
            throw MTPBridgeError.operationFailed("This MTP device does not advertise CopyObject support.")
        }

        for (index, path) in paths.enumerated() {
            onProgress?(MoveProgress(currentPath: path, completedCount: index, totalCount: paths.count))
            try await bridge.copyFile(
                storageId: storageId,
                sourcePath: path,
                destinationParentPath: destinationParentPath
            )
            onProgress?(MoveProgress(currentPath: path, completedCount: index + 1, totalCount: paths.count))
        }

        await refreshFiles()
    }

    public func checkFilesExist(files: [String]) async throws -> [Bool] {
        guard isConnected, let storageId = selectedStorageId else {
            throw MTPBridgeError.deviceNotConnected
        }
        
        return try await bridge.checkFilesExist(storageId: storageId, paths: files)
    }
}
