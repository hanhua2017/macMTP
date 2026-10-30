import Foundation
import IOKit
import IOKit.usb

@MainActor
public final class USBWatcher: ObservableObject, @unchecked Sendable {
    
    
    public static let shared = USBWatcher()
    
    
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var isWatching = false
    private var pendingConnectTask: Task<Void, Never>?
    private var pendingVerifyTask: Task<Void, Never>?
    
    
    private init() {}
    

    
    
    public func startWatching() {
        guard !isWatching else { return }
        ErrorLogger.debug("USBWatcher.startWatching begin")
        
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return
        }
        self.notificationPort = port
        
        self.runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        guard let matchingDict1 = IOServiceMatching(kIOUSBDeviceClassName),
              let matchingDict2 = IOServiceMatching(kIOUSBDeviceClassName) else {
            return
        }
        
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        let addedResult = IOServiceAddMatchingNotification(
            port,
            kIOPublishNotification,
            matchingDict1,
            { (refcon, iterator) in
                let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon!).takeUnretainedValue()
                Task { @MainActor in
                    await watcher.handleDevicesAdded(iterator: iterator)
                }
            },
            selfPtr,
            &addedIterator
        )
        
        if addedResult != kIOReturnSuccess {
            ErrorLogger.debug("USBWatcher.startWatching added notification failed result=\(addedResult)")
            stopWatching()
            return
        }
        
        Task { @MainActor in
            await handleDevicesAdded(iterator: addedIterator, isInitialScan: true)
        }
        
        let removedResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchingDict2,
            { (refcon, iterator) in
                let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon!).takeUnretainedValue()
                Task { @MainActor in
                    await watcher.handleDevicesRemoved(iterator: iterator)
                }
            },
            selfPtr,
            &removedIterator
        )
        
        if removedResult != kIOReturnSuccess {
            ErrorLogger.debug("USBWatcher.startWatching removed notification failed result=\(removedResult)")
            stopWatching()
            return
        }
        
        Task { @MainActor in
            await handleDevicesRemoved(iterator: removedIterator)
        }
        
        isWatching = true
        ErrorLogger.debug("USBWatcher.startWatching active")
    }
    
    public func stopWatching() {
        guard isWatching else { return }
        ErrorLogger.debug("USBWatcher.stopWatching")
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }

        pendingConnectTask?.cancel()
        pendingConnectTask = nil
        pendingVerifyTask?.cancel()
        pendingVerifyTask = nil
        
        isWatching = false
    }
    
    
    private func handleDevicesAdded(iterator: io_iterator_t, isInitialScan: Bool = false) async {
        var deviceCount = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceCount += 1
            logUSBDevice(device, event: isInitialScan ? "initial" : "added")
            IOObjectRelease(device)
        }
        
        if deviceCount > 0 {
            ErrorLogger.debug("USBWatcher.handleDevicesAdded count=\(deviceCount) initial=\(isInitialScan)")
            let autoDetect = UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true
            if autoDetect {
                scheduleConnect(delay: isInitialScan ? 500_000_000 : 3_000_000_000)
            }
        }
    }
    
    private func handleDevicesRemoved(iterator: io_iterator_t) async {
        var deviceCount = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceCount += 1
            logUSBDevice(device, event: "removed")
            IOObjectRelease(device)
        }
        
        if deviceCount > 0 {
            ErrorLogger.debug("USBWatcher.handleDevicesRemoved count=\(deviceCount) scheduling verifyMtpConnection")
            pendingVerifyTask?.cancel()
            pendingVerifyTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await verifyMtpConnection()
            }
        }
    }
    
    private func verifyMtpConnection() async {
        guard MTPDeviceManager.shared.isConnected else { return }
        guard !MTPDeviceManager.shared.isLoading else {
            ErrorLogger.debug("USBWatcher.verifyMtpConnection skipped because manager is loading")
            return
        }
        ErrorLogger.debug("USBWatcher.verifyMtpConnection begin")

        let result = try? await Self.bridgeForMTPVerification().fetchStorages()
        if result == nil {
            ErrorLogger.debug("USBWatcher.verifyMtpConnection fetchStorages failed; disconnecting")
            await MTPDeviceManager.shared.disconnectDevice()
        } else {
            ErrorLogger.debug("USBWatcher.verifyMtpConnection ok")
        }
    }

    static func bridgeForMTPVerification(defaults: UserDefaults = .standard) -> any MTPBridgeProtocol {
        MTPBridgeFactory.sharedBridge(defaults: defaults)
    }

    private func scheduleConnect(delay: UInt64) {
        pendingConnectTask?.cancel()
        pendingConnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            guard !MTPDeviceManager.shared.isConnected,
                  !MTPDeviceManager.shared.isLoading else {
                ErrorLogger.debug("USBWatcher.scheduleConnect skipped connected=\(MTPDeviceManager.shared.isConnected) loading=\(MTPDeviceManager.shared.isLoading)")
                return
            }
            let interfaces = await Self.currentMTPInterfacesInBackground()
            guard shouldAttemptMTPConnect(interfaces: interfaces) else {
                scheduleConnect(delay: 5_000_000_000)
                return
            }
            ErrorLogger.debug("USBWatcher.scheduleConnect calling connectDevice")
            await MTPDeviceManager.shared.connectDevice()
        }
    }
    
    private func getDeviceName(device: io_object_t) -> String? {
        var nameChar = [CChar](repeating: 0, count: 128)
        let result = IORegistryEntryGetName(device, &nameChar)
        if result == kIOReturnSuccess {
            return String(decoding: nameChar.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    private func logUSBDevice(_ device: io_object_t, event: String) {
        let name = getDeviceName(device: device) ?? "unknown"
        let owner = stringProperty(device, "UsbExclusiveOwner") ?? "none"
        let product = stringProperty(device, "USB Product Name") ?? stringProperty(device, "kUSBProductString") ?? "unknown"
        let vendor = stringProperty(device, "USB Vendor Name") ?? stringProperty(device, "kUSBVendorString") ?? "unknown"
        ErrorLogger.debug("USBWatcher.device event=\(event) name=\(name) product=\(product) vendor=\(vendor) owner=\(owner)")
    }

    private func stringProperty(_ device: io_object_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
            return nil
        }
        return value as? String
    }

    private func intProperty(_ device: io_object_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
            return nil
        }
        return value as? Int
    }

    private func shouldAttemptMTPConnect(interfaces: [(name: String, owner: String?)]) -> Bool {
        guard !interfaces.isEmpty else {
            ErrorLogger.debug("USBWatcher.shouldAttemptMTPConnect no MTP interface found yet")
            MTPDeviceManager.shared.errorMessage = "Waiting for the MTP interface to appear. macMTP will retry automatically."
            return false
        }

        let blockedOwners = interfaces.compactMap { item -> String? in
            guard let owner = item.owner, !owner.isEmpty else { return nil }
            return owner.contains("macMTP") ? nil : owner
        }

        if !blockedOwners.isEmpty {
            ErrorLogger.debug("USBWatcher.shouldAttemptMTPConnect blocked owners=\(blockedOwners.joined(separator: ","))")
            MTPDeviceManager.shared.errorMessage = "MTP interface is in use by \(blockedOwners.joined(separator: ", ")). Close Image Capture/Photos or stop ptpcamerad, then macMTP will retry."
            return false
        }

        ErrorLogger.debug("USBWatcher.shouldAttemptMTPConnect ok interfaces=\(interfaces.map { $0.name }.joined(separator: ","))")
        MTPDeviceManager.shared.errorMessage = nil
        return true
    }

    private nonisolated static func currentMTPInterfacesInBackground() async -> [(name: String, owner: String?)] {
        await Task.detached(priority: .utility) {
            currentMTPInterfaces()
        }.value
    }

    private nonisolated static func currentMTPInterfaces() -> [(name: String, owner: String?)] {
        guard let matching = IOServiceMatching("IOUSBHostInterface") else { return [] }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == kIOReturnSuccess else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var interfaces: [(name: String, owner: String?)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            let interfaceClass = intProperty(service, "bInterfaceClass")
            let interfaceSubClass = intProperty(service, "bInterfaceSubClass")
            let name = getDeviceName(device: service) ?? stringProperty(service, "kUSBString") ?? "unknown"
            let isMTP = (interfaceClass == 6 && interfaceSubClass == 1) || name.localizedCaseInsensitiveContains("MTP")

            if isMTP {
                interfaces.append((name: name, owner: stringProperty(service, "UsbExclusiveOwner")))
            }
        }
        return interfaces
    }

    private nonisolated static func getDeviceName(device: io_object_t) -> String? {
        var nameChar = [CChar](repeating: 0, count: 128)
        let result = IORegistryEntryGetName(device, &nameChar)
        if result == kIOReturnSuccess {
            return String(decoding: nameChar.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    private nonisolated static func stringProperty(_ device: io_object_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func intProperty(_ device: io_object_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
            return nil
        }
        return value as? Int
    }
}
