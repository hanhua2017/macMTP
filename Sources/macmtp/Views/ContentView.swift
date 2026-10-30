import SwiftUI


struct ContentView: View {

    enum ActivePane: Equatable {
        case local
        case mtp
    }

    private struct PendingDropTransfer {
        let sources: [FileNode]
        let destination: String
        let direction: TransferDirection
        let storageId: UInt32
    }


    @State private var currentLocalPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var currentMTPPath: String = "/"
    @State private var selectedLocalItems: Set<String> = []
    @State private var selectedMTPItems: Set<String> = []


    @State private var isMTPConnected: Bool = false
    @State private var connectedDeviceName: String = "No Device Connected"
    @State private var isReleasingMTPPort: Bool = false
    @State private var mtpErrorMessage: String? = nil


    @State private var selectedSidebarItem: String? = "home"
    @State private var isSidebarVisible: Bool = false


    @State private var showConflictDialog: Bool = false
    @State private var activeConflictResolution: ConflictResolution? = nil
    @State private var conflictingFiles: [ConflictingFilePair] = []
    @State private var conflictRememberForBatch: Bool = false
    @State private var pendingLocalPasteItems: [FileNode] = []
    @State private var pendingLocalPasteDestination: String = ""
    @State private var pendingLocalPasteIsCut: Bool = false
    @State private var pendingDropTransfer: PendingDropTransfer?


    @State private var showTransferProgress: Bool = false


    @State private var statusIsTransferring: Bool = false
    @State private var statusTransferProgress: Double = 0
    @State private var statusTransferFileName: String = ""

    @State private var selectedLocalSize: Int64 = 0
    @State private var selectedMTPSize: Int64 = 0
    @State private var localDirSize: Int64 = 0
    @State private var mtpDirSize: Int64 = 0
    @State private var localSizeByPath: [String: Int64] = [:]
    @State private var mtpSizeByPath: [String: Int64] = [:]


    @State private var activePane: ActivePane = .local


    @State private var localFiles: [FileNode] = []
    @State private var mtpFiles: [FileNode] = []


    @State private var mtpStorages: [MTPStorageInfo] = []
    @State private var mtpSelectedStorageId: UInt32? = nil
    @State private var mtpTotalBytes: Int64 = 0
    @State private var mtpFreeBytes: Int64 = 0
    @State private var mtpCapabilities: MTPDeviceCapabilities = .unknown


    @State private var showDeleteConfirmation: Bool = false
    @State private var pendingDeletePaths: [String] = []
    @State private var isDeletingMTP: Bool = false
    @State private var mtpOperationTitle: String = "Deleting MTP Items"
    @State private var mtpOperationVerb: String = "Deleting"
    @State private var mtpOperationCompletedVerb: String = "Deleted"
    @State private var mtpOperationIcon: String = "trash"
    @State private var mtpOperationIconColor: Color = .red
    @State private var mtpOperationIsIndeterminate: Bool = false
    @State private var deleteProgress: Double = 0
    @State private var deleteCurrentName: String = ""
    @State private var deleteCompletedCount: Int = 0
    @State private var deleteTotalCount: Int = 0
    @State private var showNewFolderDialog: Bool = false
    @State private var newFolderName: String = "New Folder"


    @State private var eventMonitor: Any? = nil

    @AppStorage("swapPanels") private var swapPanels: Bool = false
    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    @AppStorage("explorerLayoutMode") private var explorerLayoutModeRaw: String = ExplorerLayoutMode.dual.rawValue
    @State private var transferErrorMessage: String?

    private var layoutModeBinding: Binding<ExplorerLayoutMode> {
        Binding(
            get: { ExplorerLayoutMode(rawValue: explorerLayoutModeRaw) ?? .dual },
            set: { explorerLayoutModeRaw = $0.rawValue }
        )
    }

    private var layoutMode: ExplorerLayoutMode {
        ExplorerLayoutMode(rawValue: explorerLayoutModeRaw) ?? .dual
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(
                isMTPConnected: isMTPConnected,
                deviceName: connectedDeviceName,
                isReleasingMTPPort: isReleasingMTPPort,
                shouldShowReleaseMTP: shouldShowReleaseMTP,
                mtpStatusMessage: mtpStatusMessage,
                mtpCapabilities: mtpCapabilities,
                onForceMTPAccess: handleForceMTPAccess,
                onRefresh: handleRefresh,
                onCopy: handleCopy,
                onCut: handleCut,
                onPaste: handlePaste,
                onDelete: handleDelete,
                onNewFolder: handleNewFolder,
                onSelectAll: handleSelectAll,
                layoutMode: layoutModeBinding,
                hasClipboardContent: ClipboardManager.shared.hasContent,
                selectedCount: activePane == .local ? selectedLocalItems.count : selectedMTPItems.count
            )

            HSplitView {
                if layoutMode == .dual && isSidebarVisible {
                    SidebarView(
                        selectedItem: $selectedSidebarItem,
                        currentLocalPath: $currentLocalPath,
                        isMTPConnected: isMTPConnected,
                        mtpDeviceName: connectedDeviceName,
                        mtpStorages: MTPDeviceManager.shared.storages,
                        onMTPStorageSelected: { storageId in
                            MTPDeviceManager.shared.selectedStorageId = storageId
                            Task {
                                await MTPDeviceManager.shared.navigateTo(path: "/")
                            }
                        }
                    )
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                    .layoutPriority(0)
                }

                if layoutMode == .single {
                    mtpPane
                } else {
                    HSplitView {
                        if swapPanels {
                            mtpPane
                            localPane
                        } else {
                            localPane
                            mtpPane
                        }
                    }
                }
            }
            .onChange(of: layoutMode) { _, mode in
                if mode == .single {
                    activePane = .mtp
                    selectedLocalItems.removeAll()
                    if isSidebarVisible {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSidebarVisible = false
                        }
                    }
                }
            }

            if showTransferProgress, let batch = FileTransferService.shared.activeBatch {
                TransferProgressView(
                    batch: batch,
                    onCancel: {
                        FileTransferService.shared.cancelTransfer()
                        showTransferProgress = false
                    },
                    onPause: {
                        FileTransferService.shared.pauseTransfer()
                    },
                    onResume: {
                        FileTransferService.shared.resumeTransfer()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isDeletingMTP {
                MTPDeleteProgressView(
                    title: mtpOperationTitle,
                    verb: mtpOperationVerb,
                    completedVerb: mtpOperationCompletedVerb,
                    iconName: mtpOperationIcon,
                    iconColor: mtpOperationIconColor,
                    fileName: deleteCurrentName,
                    completedCount: deleteCompletedCount,
                    totalCount: deleteTotalCount,
                    progress: deleteProgress,
                    isIndeterminate: mtpOperationIsIndeterminate
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            StatusView(
                localPath: currentLocalPath,
                mtpPath: currentMTPPath,
                isMTPConnected: isMTPConnected,
                localItemCount: showHiddenFilesLocal ? localFiles.count : localFiles.filter { !$0.name.hasPrefix(".") }.count,
                localSelectedCount: selectedLocalItems.count,
                localSelectedSize: selectedLocalSize,
                localDirSize: localDirSize,
                mtpItemCount: showHiddenFilesMTP ? mtpFiles.count : mtpFiles.filter { !$0.name.hasPrefix(".") }.count,
                mtpSelectedCount: selectedMTPItems.count,
                mtpSelectedSize: selectedMTPSize,
                mtpDirSize: mtpDirSize,
                isTransferring: statusIsTransferring,
                transferProgress: statusTransferProgress,
                transferFileName: statusTransferFileName,
                mtpTotalBytes: mtpTotalBytes,
                mtpFreeBytes: mtpFreeBytes
            )
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showConflictDialog) {
            ConflictDialogView(
                conflictingFiles: conflictingFiles.isEmpty ? FileTransferService.shared.conflictingFiles : conflictingFiles,
                totalFileCount: conflictingFiles.isEmpty ? FileTransferService.shared.totalFileCount : pendingLocalPasteItems.count,
                resolution: $activeConflictResolution,
                rememberForBatch: $conflictRememberForBatch
            )
        }
        .alert("Transfer Failed", isPresented: Binding(
            get: { transferErrorMessage != nil },
            set: { if !$0 { transferErrorMessage = nil; FileTransferService.shared.transferError = nil } }
        )) {
            Button("OK", role: .cancel) { FileTransferService.shared.transferError = nil }
        } message: {
            Text(transferErrorMessage ?? "")
        }
        .onReceive(FileTransferService.shared.$transferError) { transferErrorMessage = $0 }
        .alert("Delete Files", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                performDelete(paths: pendingDeletePaths)
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePaths.removeAll()
            }
        } message: {
            Text(L10n.f(
                "Are you sure you want to delete %d item%@? This cannot be undone.",
                pendingDeletePaths.count,
                pendingDeletePaths.count == 1 ? "" : "s"
            ))
        }
        .alert("New Folder", isPresented: $showNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                performNewFolder()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new folder:")
        }
        .onAppear {
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onChange(of: activeConflictResolution) { _, resolution in
            if let resolution = resolution {
                if !pendingLocalPasteItems.isEmpty {
                    if resolution != .cancel {
                        performLocalPaste(
                            items: pendingLocalPasteItems,
                            destination: pendingLocalPasteDestination,
                            isCut: pendingLocalPasteIsCut,
                            conflictResolution: resolution
                        )
                        ClipboardManager.shared.clear()
                        handleRefresh()
                    }
                    pendingLocalPasteItems = []
                    pendingLocalPasteDestination = ""
                    pendingLocalPasteIsCut = false
                    conflictingFiles = []
                    showConflictDialog = false
                } else if let pendingDropTransfer {
                    if resolution != .cancel {
                        FileTransferService.shared.initiateTransfer(
                            sources: pendingDropTransfer.sources,
                            destinationDir: pendingDropTransfer.destination,
                            direction: pendingDropTransfer.direction,
                            storageId: pendingDropTransfer.storageId,
                            conflictResolution: resolution
                        )
                    }
                    self.pendingDropTransfer = nil
                    conflictingFiles = []
                    showConflictDialog = false
                } else {
                    FileTransferService.shared.resolveConflicts(with: resolution, rememberForBatch: conflictRememberForBatch)
                }
                activeConflictResolution = nil
            }
        }
        .onReceive(MTPDeviceManager.shared.$isConnected) { connected in
            isMTPConnected = connected
            connectedDeviceName = MTPDeviceManager.shared.deviceInfo?.displayName ?? "No Device Connected"
        }
        .onReceive(MTPDeviceManager.shared.$isReleasingMTPPort) { releasing in
            isReleasingMTPPort = releasing
        }
        .onReceive(MTPDeviceManager.shared.$errorMessage) { message in
            mtpErrorMessage = message
        }
        .onReceive(MTPDeviceManager.shared.$capabilities) { capabilities in
            mtpCapabilities = capabilities
        }
        .onReceive(MTPDeviceManager.shared.$mtpFiles) { newFiles in
            mtpFiles = newFiles
            currentMTPPath = MTPDeviceManager.shared.currentMTPPath
            refreshMTPSizeStats()
        }
        .onReceive(MTPDeviceManager.shared.$storages) { storages in
            mtpStorages = storages
            if let first = storages.first {
                mtpTotalBytes = Int64(first.totalCapacity)
                mtpFreeBytes = Int64(first.freeSpace)
            } else {
                mtpTotalBytes = 0
                mtpFreeBytes = 0
            }
        }
        .onReceive(MTPDeviceManager.shared.$selectedStorageId) { storageId in
            mtpSelectedStorageId = storageId
            if let storageId = storageId, let selected = mtpStorages.first(where: { $0.storageId == storageId }) {
                mtpTotalBytes = Int64(selected.totalCapacity)
                mtpFreeBytes = Int64(selected.freeSpace)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuNewFolderRequested)) { _ in
            handleNewFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuRefreshRequested)) { _ in
            handleRefresh()
        }
        // Observe FileTransferService for showing transfer progress and status bar
        .onReceive(FileTransferService.shared.$activeBatch) { batch in
            showTransferProgress = batch != nil
            statusIsTransferring = batch?.isActive ?? false
            statusTransferProgress = batch?.overallProgress ?? 0
            statusTransferFileName = batch?.currentItem?.fileName ?? ""
        }
        .onReceive(FileTransferService.shared.$transferSnapshot) { snapshot in
            statusIsTransferring = snapshot.isTransferring
            statusTransferProgress = snapshot.progress
            statusTransferFileName = snapshot.fileName
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            guard let batch = FileTransferService.shared.activeBatch else { return }
            statusIsTransferring = batch.isActive
            statusTransferProgress = batch.overallProgress
            statusTransferFileName = batch.currentItem?.fileName ?? ""
        }
        .onReceive(FileTransferService.shared.$showConflictDialog) { show in
            showConflictDialog = show
            if show {
                conflictRememberForBatch = false
            }
        }
        .onChange(of: localFiles) { _, _ in
            refreshLocalSizeStats()
        }
        .onChange(of: mtpFiles) { _, _ in
            refreshMTPSizeStats()
        }
    }

    private var shouldShowReleaseMTP: Bool {
        guard !isMTPConnected else { return false }
        if isReleasingMTPPort { return true }
        return mtpErrorMessage?.localizedCaseInsensitiveContains("MTP interface is in use") == true
    }

    private var mtpStatusMessage: String? {
        if isReleasingMTPPort {
            return mtpErrorMessage ?? "Releasing the MTP interface..."
        }
        return mtpErrorMessage
    }

    @ViewBuilder
    private var localPane: some View {
        FileExplorerPane(
            title: "Local Files",
            showsSidebarToggle: !swapPanels,
            isSidebarVisible: isSidebarVisible,
            onToggleSidebar: toggleSidebar,
            currentPath: $currentLocalPath,
            selectedItems: $selectedLocalItems,
            isLocal: true,
            isDisabled: false,
            files: $localFiles,
            isActivePane: activePane == .local,
            clipboardManager: ClipboardManager.shared,
            onFilesDropped: { files, destination in
                handleFilesDropped(files: files, destination: destination, isLocal: true)
            },
            onFileOperation: { operation in
                handleFileOperation(operation, isLocal: true)
            },
            onPaste: handlePaste
        )
        .frame(minWidth: 350, idealWidth: 420)
        .layoutPriority(1)
        .simultaneousGesture(
            TapGesture().onEnded { activePane = .local },
            including: .all
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(activePane == .local ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 2)
        )
        .onChange(of: selectedLocalItems) { _, _ in
            activePane = .local
            refreshSelectedLocalSize()
        }
    }

    @ViewBuilder
    private var mtpPane: some View {
        VStack(spacing: 0) {
            if isMTPConnected && mtpStorages.count > 1 {
                StorageSelectorView(
                    storages: mtpStorages,
                    selectedStorageId: mtpSelectedStorageId,
                    onSelect: { storageId in
                        MTPDeviceManager.shared.selectedStorageId = storageId
                        Task {
                            await MTPDeviceManager.shared.navigateTo(path: "/")
                        }
                    }
                )
            }

            FileExplorerPane(
                title: isMTPConnected ? connectedDeviceName : "MTP Device",
                showsSidebarToggle: layoutMode == .dual && swapPanels,
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: toggleSidebar,
                currentPath: $currentMTPPath,
                selectedItems: $selectedMTPItems,
                isLocal: false,
                isDisabled: !isMTPConnected,
                files: $mtpFiles,
                isActivePane: activePane == .mtp,
                clipboardManager: ClipboardManager.shared,
                onFilesDropped: { files, destination in
                    handleFilesDropped(files: files, destination: destination, isLocal: false)
                },
                onFileOperation: { operation in
                    handleFileOperation(operation, isLocal: false)
                },
                onPaste: handlePaste
            )
        }
        .frame(minWidth: 350, idealWidth: 420)
        .layoutPriority(1)
        .simultaneousGesture(
            TapGesture().onEnded { activePane = .mtp },
            including: .all
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(activePane == .mtp ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 2)
        )
        .onChange(of: selectedMTPItems) { _, _ in
            activePane = .mtp
            refreshSelectedMTPSize()
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSidebarVisible.toggle()
        }
    }

    private func refreshLocalSizeStats() {
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        for file in localFiles {
            let size = file.calculatedSize ?? file.size
            sizes[file.path] = size
            total += size
        }
        localSizeByPath = sizes
        if localDirSize != total {
            localDirSize = total
        }
        refreshSelectedLocalSize()
    }

    private func refreshMTPSizeStats() {
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        for file in mtpFiles {
            let size = file.calculatedSize ?? file.size
            sizes[file.path] = size
            total += size
        }
        mtpSizeByPath = sizes
        if mtpDirSize != total {
            mtpDirSize = total
        }
        refreshSelectedMTPSize()
    }

    private func refreshSelectedLocalSize() {
        let total = selectedLocalItems.reduce(Int64(0)) { $0 + (localSizeByPath[$1] ?? 0) }
        if selectedLocalSize != total {
            selectedLocalSize = total
        }
    }

    private func refreshSelectedMTPSize() {
        let total = selectedMTPItems.reduce(Int64(0)) { $0 + (mtpSizeByPath[$1] ?? 0) }
        if selectedMTPSize != total {
            selectedMTPSize = total
        }
    }

    private func installKeyboardMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !ExplorerKeyboardRouting.isEditingText(event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder) else {
                return event
            }
            let hasCmd = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)
            let modifiersOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 {
                switch self.activePane {
                case .local: self.selectedLocalItems.removeAll()
                case .mtp: self.selectedMTPItems.removeAll()
                }
                return nil
            }

            if event.keyCode == 36 && !hasCmd && modifiersOnly == [] {
                self.handleEnter()
                return nil
            }

            if event.keyCode == 126 && hasCmd && !hasShift {
                self.handleNavigateUp()
                return nil
            }

            guard hasCmd else { return event }

            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            switch key {
            case "c":
                self.handleCopy()
                return nil
            case "x":
                self.handleCut()
                return nil
            case "v":
                self.handlePaste()
                return nil
            case "a":
                self.handleSelectAll()
                return nil
            case "n":
                self.handleNewFolder()
                return nil
            case "r":
                self.handleRefresh()
                return nil
            default:
                break
            }

            if event.keyCode == 51 && hasCmd {
                self.handleDelete()
                return nil
            }

            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }


    func handleCopy() {
        switch activePane {
        case .local:
            let selectedNodes = localFiles.filter { selectedLocalItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.copyItems(items: selectedNodes, from: currentLocalPath, isLocal: true)
        case .mtp:
            let selectedNodes = mtpFiles.filter { selectedMTPItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.copyItems(items: selectedNodes, from: currentMTPPath, isLocal: false)
        }
    }

    func handleCut() {
        switch activePane {
        case .local:
            let selectedNodes = localFiles.filter { selectedLocalItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.cutItems(items: selectedNodes, from: currentLocalPath, isLocal: true)
        case .mtp:
            let selectedNodes = mtpFiles.filter { selectedMTPItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.cutItems(items: selectedNodes, from: currentMTPPath, isLocal: false)
        }
    }

    func handlePaste() {
        if !ClipboardManager.shared.hasContent {
            let pasteboard = NSPasteboard.general
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                let items = urls.map { FileNode(name: $0.lastPathComponent, path: $0.path, isDirectory: $0.hasDirectoryPath, size: 0, modificationDate: Date()) }
                if !items.isEmpty {
                    ClipboardManager.shared.copyItems(items: items, from: "Finder", isLocal: true)
                } else {
                    return
                }
            } else {
                return
            }
        }

        let destinationPath: String
        let isDestLocal: Bool

        switch activePane {
        case .local:
            destinationPath = currentLocalPath
            isDestLocal = true
        case .mtp:
            destinationPath = currentMTPPath
            isDestLocal = false
        }

        if ClipboardManager.shared.sourceIsLocal && isDestLocal {
            let conflicts = detectLocalConflicts(
                sourcePaths: ClipboardManager.shared.items.map { $0.path },
                destination: destinationPath
            )

            if !conflicts.isEmpty {
                conflictingFiles = conflicts
                pendingLocalPasteItems = ClipboardManager.shared.items
                pendingLocalPasteDestination = destinationPath
                pendingLocalPasteIsCut = ClipboardManager.shared.isCutOperation
                showConflictDialog = true
                return
            }
        }

        if ClipboardManager.shared.sourceIsLocal && isDestLocal {
            performLocalPaste(items: ClipboardManager.shared.items, destination: destinationPath, isCut: ClipboardManager.shared.isCutOperation)
            ClipboardManager.shared.clear()
            handleRefresh()
        } else if !ClipboardManager.shared.sourceIsLocal && !isDestLocal {
            if destinationPath == ClipboardManager.shared.sourcePath {
                ClipboardManager.shared.clear()
            } else if ClipboardManager.shared.isCutOperation {
                guard MTPDeviceManager.shared.capabilities.moveObject else {
                    mtpErrorMessage = "This MTP device does not advertise MoveObject support."
                    return
                }
                performMTPMove(
                    paths: ClipboardManager.shared.items.map(\.path),
                    destination: destinationPath
                )
                ClipboardManager.shared.clear()
            } else {
                guard MTPDeviceManager.shared.capabilities.copyObject else {
                    mtpErrorMessage = "This MTP device does not advertise CopyObject support."
                    return
                }
                performMTPCopy(
                    paths: ClipboardManager.shared.items.map(\.path),
                    destination: destinationPath
                )
                ClipboardManager.shared.clear()
            }
        } else {
            let direction: TransferDirection = isDestLocal ? .mtpToLocal : .localToMTP
            let storageId = MTPDeviceManager.shared.selectedStorageId ?? 0
            let sources = ClipboardManager.shared.items
            FileTransferService.shared.initiateTransfer(
                sources: sources,
                destinationDir: destinationPath,
                direction: direction,
                storageId: storageId,
                isCut: ClipboardManager.shared.isCutOperation
            )
            ClipboardManager.shared.clear()
        }
    }

    func handleDelete() {
        switch activePane {
        case .local:
            let paths = Array(selectedLocalItems)
            guard !paths.isEmpty else { return }
            pendingDeletePaths = paths
            showDeleteConfirmation = true
        case .mtp:
            let paths = Array(selectedMTPItems)
            guard !paths.isEmpty else { return }
            pendingDeletePaths = paths
            showDeleteConfirmation = true
        }
    }

    func handleNewFolder() {
        newFolderName = "New Folder"
        showNewFolderDialog = true
    }

    func handleForceMTPAccess() {
        Task {
            await MTPDeviceManager.shared.forceReleaseMTPPort()
        }
    }

    func handleEnter() {
        switch activePane {
        case .local:
            guard let first = selectedLocalItems.first,
                  let node = localFiles.first(where: { $0.path == first })
            else { return }
            if node.isDirectory {
                currentLocalPath = node.path
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
            }
        case .mtp:
            guard let first = selectedMTPItems.first,
                  let node = mtpFiles.first(where: { $0.path == first }),
                  node.isDirectory
            else { return }
            Task {
                await MTPDeviceManager.shared.navigateTo(path: node.path)
                currentMTPPath = MTPDeviceManager.shared.currentMTPPath
            }
        }
    }

    func handleNavigateUp() {
        switch activePane {
        case .local:
            let parent = parentPath(of: currentLocalPath)
            if parent != normalizedPath(currentLocalPath) { currentLocalPath = parent }
        case .mtp:
            let parent = parentPath(of: currentMTPPath)
            guard parent != normalizedPath(currentMTPPath) else { return }
            Task {
                await MTPDeviceManager.shared.navigateTo(path: parent)
                currentMTPPath = MTPDeviceManager.shared.currentMTPPath
            }
        }
    }

    private func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        if path == "/" { return "/" }
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result.isEmpty ? "/" : result
    }

    private func parentPath(of path: String) -> String {
        let cleanPath = normalizedPath(path)
        guard cleanPath != "/" else { return "/" }
        let parts = cleanPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    func handleRefresh() {
        switch activePane {
        case .local:
            NotificationCenter.default.post(name: .localDirectoryNeedsRefresh, object: nil)
        case .mtp:
            Task {
                await MTPDeviceManager.shared.refreshFiles()
            }
        }
    }

    func handleSelectAll() {
        switch activePane {
        case .local:
            selectedLocalItems = Set(localFiles.map { $0.path })
        case .mtp:
            selectedMTPItems = Set(mtpFiles.map { $0.path })
        }
    }


    private func handleFileOperation(_ operation: FileExplorerPane.FileOperation, isLocal: Bool) {
        switch operation {
        case .delete(let paths):
            pendingDeletePaths = paths
            showDeleteConfirmation = true

        case .rename(let oldPath, let newName):
            if isLocal {
                let sourceURL = URL(fileURLWithPath: oldPath)
                let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName)
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: destURL)
                    handleRefresh()
                } catch {
                    ErrorLogger.log(error, message: "Rename failed")
                }
            } else {
                Task {
                    try? await MTPDeviceManager.shared.renameFile(path: oldPath, newName: newName)
                }
            }

        case .newFolder(let parent, let name):
            if isLocal {
                let folderURL = URL(fileURLWithPath: parent).appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
                    handleRefresh()
                } catch {
                    ErrorLogger.log(error, message: "Create folder failed")
                }
            } else {
                let separator = parent == "/" ? "" : "/"
                Task {
                    do {
                        let storageId = MTPDeviceManager.shared.selectedStorageId ?? 0
                        try await MTPBridgeFactory.sharedBridge().makeDirectory(
                            storageId: storageId,
                            path: "\(parent)\(separator)\(name)"
                        )
                        await MTPDeviceManager.shared.refreshFiles()
                    } catch {
                        ErrorLogger.log(error, message: "Create MTP folder failed")
                    }
                }
            }

        case .open(let path):
            if isLocal {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    private func handleFilesDropped(files: [DroppedFile], destination: String, isLocal: Bool) {
        ErrorLogger.debug("ContentView.handleFilesDropped files=\(files.count) items=\(describeDroppedFilesForLog(files)) destination=\(destination) isLocalDestination=\(isLocal)")
        let localSources = files.filter { $0.isLocal }
        let mtpSources = files.filter { !$0.isLocal }
        ErrorLogger.debug("ContentView.handleFilesDropped split local=\(localSources.count) mtp=\(mtpSources.count)")

        if isLocal {
            if !localSources.isEmpty {
                DispatchQueue.global(qos: .userInitiated).async {
                    var didCopy = false
                    for file in localSources {
                        let url = URL(fileURLWithPath: file.path)
                        let destURL = URL(fileURLWithPath: destination).appendingPathComponent(file.name)
                        if url == destURL || url.deletingLastPathComponent().path == URL(fileURLWithPath: destination).path {
                            continue
                        }
                        do {
                            try FileManager.default.copyItem(at: url, to: destURL)
                            didCopy = true
                        } catch {
                            ErrorLogger.log(error, message: "Drop copy failed for \(file.name)")
                        }
                    }
                    if didCopy {
                        DispatchQueue.main.async {
                            self.handleRefresh()
                        }
                    }
                }
            }
            if !mtpSources.isEmpty {
                let nodes = fileNodes(fromDroppedMTPFiles: mtpSources)
                ErrorLogger.debug("ContentView.handleFilesDropped mtpToLocal nodes=\(describeFileNodesForLog(nodes))")
                let conflicts = detectDroppedMTPToLocalConflicts(files: mtpSources, destination: destination)
                ErrorLogger.debug("ContentView.handleFilesDropped mtpToLocal conflicts=\(conflicts.count) destination=\(destination)")
                if !conflicts.isEmpty {
                    conflictingFiles = conflicts
                    pendingDropTransfer = PendingDropTransfer(
                        sources: nodes,
                        destination: destination,
                        direction: .mtpToLocal,
                        storageId: MTPDeviceManager.shared.selectedStorageId ?? 0
                    )
                    conflictRememberForBatch = true
                    showConflictDialog = true
                    let conflictNames = conflicts.map(\.fileName).joined(separator: ",")
                    ErrorLogger.debug("ContentView.handleFilesDropped mtpToLocal showingConflictDialog files=\(conflictNames)")
                    return
                }
                ErrorLogger.debug("ContentView.handleFilesDropped mtpToLocal initiateTransfer storageId=\(MTPDeviceManager.shared.selectedStorageId ?? 0)")
                FileTransferService.shared.initiateTransfer(
                    sources: nodes,
                    destinationDir: destination,
                    direction: .mtpToLocal,
                    storageId: MTPDeviceManager.shared.selectedStorageId ?? 0
                )
            }
        } else {
            if !localSources.isEmpty {
                let nodes = localSources.map { FileNode(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: 0, modificationDate: Date()) }
                FileTransferService.shared.initiateTransfer(
                    sources: nodes,
                    destinationDir: destination,
                    direction: .localToMTP,
                    storageId: MTPDeviceManager.shared.selectedStorageId ?? 0
                )
            }
        }
    }

    private func describeDroppedFilesForLog(_ files: [DroppedFile]) -> String {
        files.map { file in
            "\(file.isLocal ? "local" : "mtp"):\(file.isDirectory ? "dir" : "file"):\(file.path)"
        }
        .joined(separator: "|")
    }

    private func describeFileNodesForLog(_ nodes: [FileNode]) -> String {
        nodes.map { node in
            "\(node.isDirectory ? "dir" : "file"):\(node.path):size=\(node.size)"
        }
        .joined(separator: "|")
    }

    private func fileNodes(fromDroppedMTPFiles files: [DroppedFile]) -> [FileNode] {
        files.map { dropped in
            if let current = mtpFiles.first(where: { $0.path == dropped.path }) {
                return current
            }
            return FileNode(
                name: dropped.name,
                path: dropped.path,
                isDirectory: dropped.isDirectory,
                size: 0,
                modificationDate: Date()
            )
        }
    }

    private func detectDroppedMTPToLocalConflicts(files: [DroppedFile], destination: String) -> [ConflictingFilePair] {
        let fileManager = FileManager.default
        let destinationURL = URL(fileURLWithPath: destination)

        return files.compactMap { dropped in
            let destinationFileURL = destinationURL.appendingPathComponent(dropped.name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: destinationFileURL.path, isDirectory: &isDirectory) else {
                return nil
            }

            let sourceNode = mtpFiles.first(where: { $0.path == dropped.path })
            let attributes = (try? fileManager.attributesOfItem(atPath: destinationFileURL.path)) ?? [:]
            let destinationSize = (attributes[.size] as? Int64) ?? 0
            let destinationDate = (attributes[.modificationDate] as? Date) ?? Date()

            return ConflictingFilePair(
                fileName: dropped.name,
                sourcePath: dropped.path,
                sourceSize: sourceNode?.size ?? 0,
                sourceDate: sourceNode?.modificationDate ?? Date(),
                destinationPath: destinationFileURL.path,
                destinationSize: destinationSize,
                destinationDate: destinationDate
            )
        }
    }


    private func detectLocalConflicts(sourcePaths: [String], destination: String) -> [ConflictingFilePair] {
        var conflicts: [ConflictingFilePair] = []
        let fileManager = FileManager.default

        for sourcePath in sourcePaths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let fileName = sourceURL.lastPathComponent
            let destPath = URL(fileURLWithPath: destination).appendingPathComponent(fileName).path

            if fileManager.fileExists(atPath: destPath) {
                do {
                    let sourceAttrs = try fileManager.attributesOfItem(atPath: sourcePath)
                    let destAttrs = try fileManager.attributesOfItem(atPath: destPath)

                    let sourceSize = (sourceAttrs[.size] as? Int64) ?? 0
                    let sourceDate = (sourceAttrs[.modificationDate] as? Date) ?? Date()
                    let destSize = (destAttrs[.size] as? Int64) ?? 0
                    let destDate = (destAttrs[.modificationDate] as? Date) ?? Date()

                    conflicts.append(ConflictingFilePair(
                        fileName: fileName,
                        sourcePath: sourcePath,
                        sourceSize: sourceSize,
                        sourceDate: sourceDate,
                        destinationPath: destPath,
                        destinationSize: destSize,
                        destinationDate: destDate
                    ))
                } catch {
        conflicts.append(ConflictingFilePair(
                        fileName: fileName,
                        sourcePath: sourcePath,
                        sourceSize: 0,
                        sourceDate: Date(),
                        destinationPath: destPath,
                        destinationSize: 0,
                        destinationDate: Date()
                    ))
                }
            }
        }

        return conflicts
    }


    private func performDelete(paths: [String]) {
        let fileManager = FileManager.default

        if activePane == .local {
            for path in paths {
                do {
                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                } catch {
                    ErrorLogger.log(error, message: "Delete failed for \(path)")
                }
            }
            selectedLocalItems.removeAll()
            pendingDeletePaths.removeAll()
            handleRefresh()
        } else {
            Task {
                await MainActor.run {
                    mtpOperationTitle = "Deleting MTP Items"
                    mtpOperationVerb = "Deleting"
                    mtpOperationCompletedVerb = "Deleted"
                    mtpOperationIcon = "trash"
                    mtpOperationIconColor = .red
                    mtpOperationIsIndeterminate = false
                    isDeletingMTP = true
                    deleteProgress = 0
                    deleteCurrentName = paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
                    deleteCompletedCount = 0
                    deleteTotalCount = paths.count
                }

                do {
                    try await MTPDeviceManager.shared.deleteFiles(paths: paths) { progress in
                        deleteCurrentName = (progress.currentPath as NSString).lastPathComponent
                        deleteCompletedCount = progress.completedCount
                        deleteTotalCount = progress.totalCount
                        deleteProgress = progress.fractionCompleted
                    }
                    await MainActor.run {
                        selectedMTPItems.removeAll()
                        pendingDeletePaths.removeAll()
                        isDeletingMTP = false
                    }
                } catch {
                    ErrorLogger.log(error, message: "MTP delete failed")
                    await MainActor.run {
                        pendingDeletePaths.removeAll()
                        isDeletingMTP = false
                    }
                }
            }
        }
    }

    private func performMTPMove(paths: [String], destination: String) {
        Task {
            await MainActor.run {
                mtpOperationTitle = "Moving MTP Items"
                mtpOperationVerb = "Moving"
                mtpOperationCompletedVerb = "Moved"
                mtpOperationIcon = "folder"
                mtpOperationIconColor = .accentColor
                mtpOperationIsIndeterminate = true
                isDeletingMTP = true
                deleteProgress = 0
                deleteCurrentName = paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
                deleteCompletedCount = 0
                deleteTotalCount = paths.count
            }

            do {
                try await MTPDeviceManager.shared.moveFiles(paths: paths, destinationParentPath: destination) { progress in
                    deleteCurrentName = (progress.currentPath as NSString).lastPathComponent
                    deleteCompletedCount = progress.completedCount
                    deleteTotalCount = progress.totalCount
                    deleteProgress = progress.fractionCompleted
                }
                await MainActor.run {
                    selectedMTPItems.removeAll()
                    isDeletingMTP = false
                    handleRefresh()
                }
            } catch {
                ErrorLogger.log(error, message: "MTP move failed")
                await MainActor.run {
                    isDeletingMTP = false
                    mtpErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func performMTPCopy(paths: [String], destination: String) {
        Task {
            await MainActor.run {
                mtpOperationTitle = "Copying MTP Items"
                mtpOperationVerb = "Copying"
                mtpOperationCompletedVerb = "Copied"
                mtpOperationIcon = "doc.on.doc"
                mtpOperationIconColor = .accentColor
                mtpOperationIsIndeterminate = true
                isDeletingMTP = true
                deleteProgress = 0
                deleteCurrentName = paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
                deleteCompletedCount = 0
                deleteTotalCount = paths.count
            }

            do {
                try await MTPDeviceManager.shared.copyFiles(paths: paths, destinationParentPath: destination) { progress in
                    deleteCurrentName = (progress.currentPath as NSString).lastPathComponent
                    deleteCompletedCount = progress.completedCount
                    deleteTotalCount = progress.totalCount
                    deleteProgress = progress.fractionCompleted
                }
                await MainActor.run {
                    selectedMTPItems.removeAll()
                    isDeletingMTP = false
                    handleRefresh()
                }
            } catch {
                ErrorLogger.log(error, message: "MTP copy failed")
                await MainActor.run {
                    isDeletingMTP = false
                    mtpErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func performLocalPaste(
        items: [FileNode],
        destination: String,
        isCut: Bool,
        conflictResolution: ConflictResolution? = nil
    ) {
        let fileManager = FileManager.default
        let destURL = URL(fileURLWithPath: destination)
        for item in items {
            let sourceURL = URL(fileURLWithPath: item.path)
            let targetURL = destURL.appendingPathComponent(item.name)
            if sourceURL == targetURL || sourceURL.deletingLastPathComponent() == destURL {
                continue
            }
            do {
                if fileManager.fileExists(atPath: targetURL.path) {
                    switch conflictResolution {
                    case .skip, .skipIfSameSize:
                        continue
                    case .overwriteIfDifferent:
                        let sourceSize = ((try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size]) as? Int64) ?? 0
                        let targetSize = ((try? fileManager.attributesOfItem(atPath: targetURL.path)[.size]) as? Int64) ?? 0
                        if sourceSize == targetSize { continue }
                        try fileManager.removeItem(at: targetURL)
                    case .overwrite:
                        try fileManager.removeItem(at: targetURL)
                    case .cancel:
                        return
                    case .askEach, .none:
                        break
                    }
                }
                if isCut {
                    try fileManager.moveItem(at: sourceURL, to: targetURL)
                } else {
                    try fileManager.copyItem(at: sourceURL, to: targetURL)
                }
            } catch {
                ErrorLogger.log(error, message: "Paste operation failed for \(item.name)")
            }
        }
    }

    private func performNewFolder() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let parentPath: String
        switch activePane {
        case .local: parentPath = currentLocalPath
        case .mtp: parentPath = currentMTPPath
        }

        let folderURL = URL(fileURLWithPath: parentPath).appendingPathComponent(trimmedName)

        if activePane == .local {
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
                handleRefresh()
            } catch {
                ErrorLogger.log(error, message: "Create folder failed")
            }
        } else {
            Task {
                try? await MTPDeviceManager.shared.createFolder(name: trimmedName)
                await MTPDeviceManager.shared.refreshFiles()
            }
        }
    }
}

private struct MTPDeleteProgressView: View {
    let title: String
    let verb: String
    let completedVerb: String
    let iconName: String
    let iconColor: Color
    let fileName: String
    let completedCount: Int
    let totalCount: Int
    let progress: Double
    let isIndeterminate: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .foregroundColor(iconColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Text("\(completedCount)/\(totalCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }

                if isIndeterminate && completedCount < totalCount {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color(NSColor.windowBackgroundColor).opacity(0.7)
            }
        )
    }

    private var subtitle: String {
        guard !fileName.isEmpty else {
            return "Preparing..."
        }
        return completedCount >= totalCount ? "\(completedVerb) \(fileName)" : "\(verb) \(fileName)"
    }
}
