import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import PDFKit


struct DroppedFile: Codable {
    let path: String
    let isLocal: Bool
    let name: String
    let isDirectory: Bool
}

final class ThreadSafeArray<T>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()

    func append(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        let copy = items
        lock.unlock()
        return copy
    }
}

final class InAppDragState: @unchecked Sendable {
    static let shared = InAppDragState()

    private let lock = NSLock()
    private var payload: String?
    private var timestamp: Date = .distantPast

    func update(payload: String) {
        lock.lock()
        self.payload = payload
        self.timestamp = Date()
        lock.unlock()
    }

    func recentPayload(maxAge: TimeInterval = 30) -> String? {
        lock.lock()
        let currentPayload = payload
        let age = Date().timeIntervalSince(timestamp)
        lock.unlock()
        return age <= maxAge ? currentPayload : nil
    }
}


enum FileExplorerLoadingState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case error(String)
}


enum FileSortColumn: String, CaseIterable {
    case name = "Name"
    case size = "Size"
    case type = "Type"
    case dateModified = "Date Modified"
}

enum FileSortDirection {
    case ascending
    case descending

    var toggled: FileSortDirection {
        self == .ascending ? .descending : .ascending
    }

    var iconName: String {
        self == .ascending ? "chevron.up" : "chevron.down"
    }
}


enum FileViewMode: String, CaseIterable {
    case list = "List"
    case icons = "Icons"
    case largeIcons = "Large Icons"

    var iconName: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .largeIcons: return "square.grid.3x3"
        }
    }
}


struct FileExplorerPane: View {
    nonisolated private static let finderFilenamesType = "NSFilenamesPboardType"
    nonisolated static let internalFileItemsType = "com.macmtp.file-items"
    nonisolated static let acceptedDropTypes = [
        internalFileItemsType,
        "public.file-url",
        "public.utf8-plain-text",
        finderFilenamesType
    ]

    @AppStorage("appFontScale") private var appFontScale: Double = 1.0

    var title: String
    var showsSidebarToggle: Bool = false
    var isSidebarVisible: Bool = true
    var onToggleSidebar: (() -> Void)? = nil

    @Binding var currentPath: String

    @Binding var selectedItems: Set<String>

    var isLocal: Bool

    var isDisabled: Bool = false

    @Binding var files: [FileNode]

    let isActivePane: Bool
    let clipboardManager: ClipboardManager
    var onFilesDropped: (([DroppedFile], String) -> Void)? = nil
    var onFileOperation: ((FileOperation) -> Void)? = nil
    var onPaste: (() -> Void)? = nil
    

    @State private var loadingState: FileExplorerLoadingState = .idle
    @State private var displayedFiles: [FileNode] = []

    @State private var sortColumn: FileSortColumn = .name
    @State private var sortDirection: FileSortDirection = .ascending

    @State private var viewMode: FileViewMode = .list

    @State private var pathHistory: [String] = []
    @State private var pathHistoryIndex: Int = -1

    @State private var filterText: String = ""
    @State private var isFilterVisible: Bool = false

    @State private var keySearchBuffer: String = ""
    @State private var lastKeyTime: Date = Date.distantPast

    @State private var isEditingPath: Bool = false
    @State private var editablePathText: String = ""

    @State private var showRenameDialog: Bool = false
    @State private var renameTargetFile: FileNode? = nil
    @State private var renameText: String = ""

    @State private var isCreatingNewFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var showProperties: Bool = false
    @State private var propertiesFile: FileNode?

    @State private var isDropTargeted: Bool = false
    @State private var dropTargetDirectoryPath: String? = nil

    @State private var sizeGen: UInt64 = 0

    @State private var contextMenuTargetID: String? = nil

    @State private var lastClickedItemID: String? = nil

    @State private var directorySizes: [String: Int64] = [:]


    @State private var dragRect: CGRect? = nil
    @State private var ignoreMarqueeDrag: Bool = false
    @State private var itemFrames: [String: CGRect] = [:]
    @State private var dragStartSelection: Set<String> = []


    enum FileOperation {
        case delete(paths: [String])
        case rename(oldPath: String, newName: String)
        case newFolder(parentPath: String, name: String)
        case open(path: String)
    }


    var body: some View {
        VStack(spacing: 0) {
            navigationHeader

            if isFilterVisible {
                filterBar
            }

            if viewMode == .list {
                columnHeaders
                Divider()
            }

            contentArea
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            if !isDisabled {
                navigateTo(path: currentPath)
            }
        }
        .onChange(of: currentPath) { _, newPath in
            let currentHistoricalPath = pathHistory.indices.contains(pathHistoryIndex) ? pathHistory[pathHistoryIndex] : nil
            guard !isDisabled else { return }
            if isLocal {
                let cleanPath = normalizedPath(newPath)
                if currentHistoricalPath != cleanPath {
                    if pathHistoryIndex < pathHistory.count - 1 {
                        pathHistory.removeSubrange((pathHistoryIndex + 1)...)
                    }
                    pathHistory.append(cleanPath)
                    pathHistoryIndex = pathHistory.count - 1
                }
                clearSelectionIfNeeded()
                loadDirectory()
            } else if currentHistoricalPath != newPath {
                navigateTo(path: newPath)
            }
        }
        .onChange(of: files) { _, newFiles in
            applyFilterAndSort(using: newFiles)
        }
        .onChange(of: isDisabled) { _, disabled in
            if !disabled {
                loadDirectory()
            }
        }
        .onReceive(MTPDeviceManager.shared.$mtpFiles) { newFiles in
            guard !isLocal else { return }
            applyFilterAndSort(using: newFiles)
            if newFiles.isEmpty {
                if let err = MTPDeviceManager.shared.errorMessage {
                    loadingState = .error(err)
                } else {
                    loadingState = .empty
                }
            } else {
                loadingState = .loaded
            }
            sizeGen &+= 1
        }
        .onChange(of: showHiddenFilesLocal) { _, _ in
            if isLocal { applyFilterAndSort() }
        }
        .onChange(of: showHiddenFilesMTP) { _, _ in
            if !isLocal { applyFilterAndSort() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localDirectoryNeedsRefresh)) { _ in
            if isLocal {
                loadDirectory()
            }
        }
        .onChange(of: filterText) { _, _ in
            applyFilterAndSort()
        }
        .onChange(of: sortColumn) { _, _ in
            applyFilterAndSort()
        }
        .onChange(of: sortDirection) { _, _ in
            applyFilterAndSort()
        }
        .background(
            KeyboardLetterNav(
                onKeyPress: { key in handleKeyPress(key) },
                isActive: isDisabled ? false : isActivePane
            )
        )
        .onChange(of: isActivePane) { _, active in
            if active { lastKeyTime = Date.distantPast }
        }
        .sheet(isPresented: $showProperties) {
            if let file = propertiesFile {
                FilePropertiesView(file: file, isLocal: isLocal)
            }
        }
        .alert("Rename", isPresented: $showRenameDialog) {
            TextField("New name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let file = renameTargetFile {
                    commitRename(file: file)
                }
            }
        } message: {
            Text("Enter a new name for this item.")
        }
        .alert("New Folder", isPresented: $isCreatingNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                commitNewFolder()
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
    }


    private var navigationHeader: some View {
        HStack(spacing: 6) {
            if showsSidebarToggle {
                Button(action: { onToggleSidebar?() }) {
                    Image(systemName: isSidebarVisible ? "sidebar.left" : "sidebar.leading")
                        .font(.system(size: 13 * appFontScale, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(isSidebarVisible ? "Hide navigation sidebar" : "Show navigation sidebar")
            }

            Button(action: navigateBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12 * appFontScale, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(pathHistoryIndex <= 0)
            .help("Go back")

            Button(action: navigateForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12 * appFontScale, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(pathHistoryIndex >= pathHistory.count - 1)
            .help("Go forward")

            Button(action: navigateUp) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12 * appFontScale, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(currentPath == "/" || currentPath.isEmpty)
            .help("Go to parent folder")

            if isEditingPath {
                TextField("Path", text: $editablePathText, onCommit: {
                    isEditingPath = false
                    navigateTo(path: editablePathText)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12 * appFontScale))
                .onExitCommand {
                    isEditingPath = false
                }
            } else {
                pathBreadcrumbs
                    .onTapGesture(count: 2) {
                        editablePathText = currentPath
                        isEditingPath = true
                    }
            }

            Spacer(minLength: 4)

            Button(action: {
                let modes = FileViewMode.allCases
                let idx = modes.firstIndex(of: viewMode) ?? 0
                viewMode = modes[(idx + 1) % modes.count]
            }) {
                Image(systemName: viewMode.iconName)
                    .font(.system(size: 13 * appFontScale))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.f("View mode: %@", L10n.t(viewMode.rawValue)))

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFilterVisible.toggle()
                    if !isFilterVisible { filterText = "" }
                }
            }) {
                Image(systemName: isFilterVisible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14 * appFontScale))
                    .foregroundColor(isFilterVisible ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Filter files")

            Text(itemCountText)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var pathBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let components = pathComponents
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8 * appFontScale))
                            .foregroundColor(.secondary)
                    }

                    Button(action: {
                        let targetPath = buildPath(upTo: index, from: components)
                        navigateTo(path: targetPath)
                    }) {
                        HStack(spacing: 3) {
                            if index == 0 {
                                Image(systemName: isLocal ? "laptopcomputer" : "ipad.and.iphone")
                                    .font(.system(size: 10 * appFontScale))
                            }
                            Text(component.isEmpty ? "/" : component)
                                .font(.system(size: 11 * appFontScale))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pathComponents: [String] {
        let path = currentPath
        if path == "/" { return ["/"] }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        parts.insert("/", at: 0)
        return parts
    }

    private func buildPath(upTo index: Int, from components: [String]) -> String {
        if index == 0 { return "/" }
        let subComponents = components[1...index]
        return "/" + subComponents.joined(separator: "/")
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

    private var itemCountText: String {
        let total = displayedFiles.count
        let selected = selectedItems.count
        if selected > 0 {
            return L10n.f("%d items (%d selected)", total, selected)
        }
        return L10n.f("%d items", total)
    }


    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Filter by name or extension (e.g. .mp4)", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11 * appFontScale))

            if !filterText.isEmpty {
                Button(action: { filterText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .transition(.move(edge: .top).combined(with: .opacity))
    }


    private var columnHeaders: some View {
        HStack(spacing: 0) {
            columnHeader(title: "Name", column: .name, minWidth: 180)
            Divider().frame(height: 16)
            columnHeader(title: "Size", column: .size, minWidth: 70)
            Divider().frame(height: 16)
            columnHeader(title: "Type", column: .type, minWidth: 60)
            Divider().frame(height: 16)
            columnHeader(title: "Date Modified", column: .dateModified, minWidth: 120)
        }
        .padding(.leading, 8)
        .frame(height: 24)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
    }

    private func columnHeader(title: String, column: FileSortColumn, minWidth: CGFloat) -> some View {
        Button(action: {
            if sortColumn == column {
                sortDirection = sortDirection.toggled
            } else {
                sortColumn = column
                sortDirection = .ascending
            }
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11 * appFontScale, weight: .medium))
                    .foregroundColor(.secondary)

                if sortColumn == column {
                    Image(systemName: sortDirection.iconName)
                        .font(.system(size: 8 * appFontScale, weight: .bold))
                        .foregroundColor(.accentColor)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: minWidth)
        .frame(maxWidth: column == .name ? .infinity : minWidth + 20)
    }


    @ViewBuilder
    private var contentArea: some View {
        Group {
            if isDisabled {
                disabledStateView
            } else {
                switch loadingState {
                case .loading:
                    loadingStateView
                case .error(let message):
                    errorStateView(message: message)
                case .empty:
                    emptyStateView
                default:
                    if viewMode == .list {
                        listView
                    } else {
                        iconGridView
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onDrop(of: Self.acceptedDropTypes, isTargeted: $isDropTargeted) { providers in
            guard !isDisabled else { return false }
            ErrorLogger.debug("FileExplorerPane.contentArea onDrop isLocal=\(isLocal) providers=\(providers.count)")
            return handleDrop(providers: providers)
        }
        .onChange(of: isDropTargeted) { _, targeted in
            ErrorLogger.debug("FileExplorerPane.contentArea dropTargeted isLocal=\(isLocal) targeted=\(targeted) path=\(currentPath)")
        }
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(displayedFiles) { file in
                    listRowItem(for: file)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.001))
        }
        .contextMenu { emptySpaceContextMenuItems }
        .onTapGesture { focusFileList(); clearSelectionIfNeeded() }
    }

    private var iconGridView: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: viewMode == .largeIcons ? 4 : 7)
        return GeometryReader { scrollGeo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(displayedFiles) { file in
                            gridItemWithPreference(for: file)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .frame(minWidth: scrollGeo.size.width, minHeight: scrollGeo.size.height, alignment: .topLeading)
                .background(Color.white.opacity(0.001))
            }
            .coordinateSpace(name: "explorerSpace")
            .onPreferenceChange(ItemFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragRect == nil {
                            let start = value.startLocation
                            let hitItem = itemFrames.values.contains { $0.insetBy(dx: -4, dy: -4).contains(start) }
                            if hitItem {
                                ignoreMarqueeDrag = true
                                return
                            }
                            ignoreMarqueeDrag = false
                            
                            let modifiers = NSEvent.modifierFlags
                            if modifiers.contains(.shift) || modifiers.contains(.command) {
                                dragStartSelection = selectedItems
                            } else {
                                dragStartSelection = []
                                clearSelectionIfNeeded()
                            }
                        }
                        
                        if ignoreMarqueeDrag { return }
                        
                        let start = value.startLocation
                        let current = value.location
                        
                        let rect = CGRect(
                            x: min(start.x, current.x),
                            y: min(start.y, current.y),
                            width: abs(current.x - start.x),
                            height: abs(current.y - start.y)
                        )
                        self.dragRect = rect
                        
                        var newSelection = dragStartSelection
                        for (path, frame) in itemFrames {
                            if rect.intersects(frame) {
                                newSelection.insert(path)
                            }
                        }
                        setSelectionIfNeeded(newSelection)
                    }
                    .onEnded { _ in
                        dragRect = nil
                        ignoreMarqueeDrag = false
                    }
            )
            .overlay(
                Group {
                    if let rect = dragRect, !ignoreMarqueeDrag {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .stroke(Color.accentColor, lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            )
        }
        .background(Color(NSColor.controlBackgroundColor))
        .contextMenu { emptySpaceContextMenuItems }
        .onTapGesture { focusFileList(); clearSelectionIfNeeded() }
    }

    @ViewBuilder
    private func gridItemWithPreference(for file: FileNode) -> some View {
        let isSelected = selectedItems.contains(file.path)
        let iconSize: CGFloat = viewMode == .largeIcons ? 48 : 28
        let itemWidth: CGFloat = viewMode == .largeIcons ? 90 : 70
        let itemHeight: CGFloat = viewMode == .largeIcons ? 110 : 70
        let iconAreaHeight: CGFloat = viewMode == .largeIcons ? 54 : 32
        let nameAreaHeight: CGFloat = viewMode == .largeIcons ? 34 : 30
        let isDirectoryDropTarget = dropTargetDirectoryPath == file.path

        let item = VStack(spacing: 4) {
            FileIconView(
                file: file,
                isLocal: isLocal,
                iconSize: iconSize,
                thumbnailSize: CGSize(width: iconAreaHeight, height: iconAreaHeight)
            )
                .frame(width: itemWidth, height: iconAreaHeight, alignment: .center)

            Text(file.name)
                .font(viewMode == .largeIcons ? .caption : .caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .frame(maxWidth: viewMode == .largeIcons ? 80 : 60)
                .frame(height: nameAreaHeight, alignment: .top)

            if viewMode == .largeIcons {
                Text(fileSizeDisplay(for: file))
                    .font(.system(size: 8 * appFontScale))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(height: 12)
            }
        }
        .frame(
            width: itemWidth,
            height: itemHeight,
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(gridItemBackgroundColor(isSelected: isSelected, isDirectoryDropTarget: isDirectoryDropTarget))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isDirectoryDropTarget ? Color.accentColor.opacity(0.85) :
                        (isSelected ? Color.accentColor.opacity(0.5) : Color.clear),
                    lineWidth: isDirectoryDropTarget ? 2 : 1.5
                )
        )
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ItemFramePreferenceKey.self,
                    value: [file.path: geo.frame(in: .named("explorerSpace"))]
                )
            }
        )
        .highPriorityGesture(TapGesture(count: 1).onEnded {
            handleSingleClick(file: file)
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            handleDoubleClick(file: file)
        })
        .onDrag { dragProvider(for: file) }
        .contextMenu { contextMenuItems(for: file) }

        if file.isDirectory {
            item.onDrop(of: Self.acceptedDropTypes, isTargeted: dropTargetBinding(for: file)) { providers in
                handleDrop(providers: providers, targetDirectory: file.path)
            }
        } else {
            item
        }
    }


    @ViewBuilder
    private func listRowItem(for file: FileNode) -> some View {
        let isSelected = selectedItems.contains(file.path)
        let isDirectoryDropTarget = dropTargetDirectoryPath == file.path

        let row = fileRow(for: file)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.leading, 8)
            .background(listRowBackgroundColor(isSelected: isSelected, isDirectoryDropTarget: isDirectoryDropTarget))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isDirectoryDropTarget ? Color.accentColor.opacity(0.85) : Color.clear, lineWidth: 1.5)
                    .padding(.horizontal, 2)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 0.5)
            }
            .contextMenu { contextMenuItems(for: file) }
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture(count: 1).onEnded {
                handleSingleClick(file: file)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                handleDoubleClick(file: file)
            })

        if file.isDirectory {
            row.onDrop(of: Self.acceptedDropTypes, isTargeted: dropTargetBinding(for: file)) { providers in
                handleDrop(providers: providers, targetDirectory: file.path)
            }
        } else {
            row
        }
    }


    private func fileRow(for file: FileNode) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.iconName)
                    .font(.system(size: 14 * appFontScale))
                    .foregroundColor(file.iconColor)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20)

                Text(file.name)
                    .font(.system(size: 12 * appFontScale))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .frame(minWidth: 180, maxWidth: .infinity)

            Text(fileSizeDisplay(for: file))
                .font(.system(size: 11 * appFontScale))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(minWidth: 70, maxWidth: 90, alignment: .trailing)
                .padding(.horizontal, 8)

            Text(file.isDirectory ? "Folder" : file.extensionName)
                .font(.system(size: 11 * appFontScale))
                .foregroundColor(.secondary)
                .frame(minWidth: 60, maxWidth: 80, alignment: .leading)
                .padding(.horizontal, 8)

            Text(file.formattedDate)
                .font(.system(size: 11 * appFontScale))
                .foregroundColor(.secondary)
                .frame(minWidth: 120, maxWidth: 140, alignment: .leading)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onDrag { dragProvider(for: file) }
    }

    private func listRowBackgroundColor(isSelected: Bool, isDirectoryDropTarget: Bool) -> Color {
        if isDirectoryDropTarget {
            return Color.accentColor.opacity(0.22)
        }
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        return Color.clear
    }

    private func gridItemBackgroundColor(isSelected: Bool, isDirectoryDropTarget: Bool) -> Color {
        if isDirectoryDropTarget {
            return Color.accentColor.opacity(0.22)
        }
        if isSelected {
            return Color.accentColor.opacity(0.15)
        }
        return Color.clear
    }

    private func dropTargetBinding(for file: FileNode) -> Binding<Bool>? {
        guard file.isDirectory else { return nil }
        return Binding(
            get: { dropTargetDirectoryPath == file.path },
            set: { isTargeted in
                if isTargeted {
                    dropTargetDirectoryPath = file.path
                } else if dropTargetDirectoryPath == file.path {
                    dropTargetDirectoryPath = nil
                }
            }
        )
    }


    @ViewBuilder
    private func contextMenuItems(for file: FileNode) -> some View {
        Button(action: { handleDoubleClick(file: file) }) {
            Label("Open", systemImage: "arrow.up.forward.square")
        }

        Divider()

        Button(action: {
            ClipboardManager.shared.copyItems(items: targetedItems(for: file), from: currentPath, isLocal: isLocal)
        }) {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button(action: {
            ClipboardManager.shared.cutItems(items: targetedItems(for: file), from: currentPath, isLocal: isLocal)
        }) {
            Label("Cut", systemImage: "scissors")
        }

        Button(action: {
            onPaste?()
        }) {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(!ClipboardManager.shared.hasContent)

        Divider()

        Button(action: {
            onFileOperation?(.delete(paths: targetedItems(for: file).map(\.path)))
        }) {
            Label("Delete", systemImage: "trash")
        }

        Button(action: {
            renameTargetFile = file
            renameText = file.name
            showRenameDialog = true
        }) {
            Label("Rename", systemImage: "pencil")
        }

        Divider()

        Button(action: {
            isCreatingNewFolder = true
            newFolderName = "New Folder"
        }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }

        Button(action: {
            setSelectionIfNeeded(Set(displayedFiles.map { $0.path }))
        }) {
            Label("Select All", systemImage: "checkmark.circle")
        }

        Divider()

        Button(action: {
            propertiesFile = targetedItems(for: file).first ?? file
            showProperties = true
        }) {
            Label("Properties", systemImage: "info.circle")
        }

        if isLocal && file.isDirectory {
            Button(action: {
                calculateDirectorySize(for: file)
            }) {
                Label("Calculate Size", systemImage: "sum")
            }
        }
    }

    private func targetedItems(for file: FileNode) -> [FileNode] {
        guard selectedItems.contains(file.path) else {
            return [file]
        }
        let items = displayedFiles.filter { selectedItems.contains($0.path) }
        return items.isEmpty ? [file] : items
    }
    
    @ViewBuilder
    private var emptySpaceContextMenuItems: some View {
        Button(action: {
            onPaste?()
        }) {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(!ClipboardManager.shared.hasContent)
        
        Divider()
        
        Button(action: {
            isCreatingNewFolder = true
            newFolderName = "New Folder"
        }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
    }


    private var disabledStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: isLocal ? "externaldrive.badge.xmark" : "cable.connector.horizontal")
                .font(.system(size: 48 * appFontScale))
                .foregroundColor(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text(isLocal ? "Local drive not accessible" : "Connect an Android device to view files")
                .font(.headline)
                .foregroundColor(.secondary)

            Text(isLocal ? "Check that the selected volume is mounted." : "Plug in your Android device via USB and enable file transfer (MTP) mode.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private var loadingStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading directory…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func errorStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40 * appFontScale))
                .foregroundColor(.orange)
                .symbolRenderingMode(.multicolor)

            Text("Error Loading Directory")
                .font(.headline)
                .foregroundColor(.primary)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button(action: { loadDirectory() }) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 44 * appFontScale))
                .foregroundColor(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text("This folder is empty")
                .font(.headline)
                .foregroundColor(.secondary)

            if !filterText.isEmpty {
                Text("No files match the filter \"\(filterText)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: { filterText = "" }) {
                    Label("Clear Filter", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .contentShape(Rectangle())
        .contextMenu { emptySpaceContextMenuItems }
        .onTapGesture { focusFileList(); clearSelectionIfNeeded() }
    }




    private func navigateTo(path: String) {
        let cleanPath = normalizedPath(path)
        if cleanPath == currentPath, pathHistory.indices.contains(pathHistoryIndex) {
            return
        }

        if isLocal {
            if pathHistoryIndex < pathHistory.count - 1 {
                pathHistory.removeSubrange((pathHistoryIndex + 1)...)
            }
            pathHistory.append(cleanPath)
            pathHistoryIndex = pathHistory.count - 1

            clearSelectionIfNeeded()
            if currentPath == cleanPath {
                loadDirectory()
            } else {
                currentPath = cleanPath
            }
    } else {
        if pathHistoryIndex < pathHistory.count - 1 {
            pathHistory.removeSubrange((pathHistoryIndex + 1)...)
        }
        pathHistory.append(cleanPath)
        pathHistoryIndex = pathHistory.count - 1
        clearSelectionIfNeeded()
        
        let manager = MTPDeviceManager.shared
        if cleanPath == manager.currentMTPPath && !manager.isLoading {
            let currentFiles = manager.mtpFiles
            applyFilterAndSort(using: currentFiles)
            if currentFiles.isEmpty {
                if let err = manager.errorMessage {
                    loadingState = .error(err)
                } else {
                    loadingState = .empty
                }
            } else {
                loadingState = .loaded
            }
        } else {
            loadingState = .loading
            Task {
                await manager.navigateTo(path: cleanPath)
                currentPath = manager.currentMTPPath
            }
        }
    }
    }

    private func navigateBack() {
        if isLocal {
            guard pathHistoryIndex > 0 else { return }
            pathHistoryIndex -= 1
            currentPath = pathHistory[pathHistoryIndex]
            clearSelectionIfNeeded()
        } else {
            Task {
                await MTPDeviceManager.shared.navigateBack()
            }
        }
    }

    private func navigateForward() {
        if isLocal {
            guard pathHistoryIndex >= 0 && pathHistoryIndex < pathHistory.count - 1 else { return }
            pathHistoryIndex += 1
            currentPath = pathHistory[pathHistoryIndex]
            clearSelectionIfNeeded()
        } else {
            Task {
                await MTPDeviceManager.shared.navigateForward()
            }
        }
    }

    private func navigateUp() {
        if isLocal {
            let parentPath = parentPath(of: currentPath)
            guard parentPath != normalizedPath(currentPath) else { return }
            navigateTo(path: parentPath)
        } else {
            Task {
                await MTPDeviceManager.shared.navigateUp()
                currentPath = MTPDeviceManager.shared.currentMTPPath
            }
        }
    }


    private func loadDirectory() {
        if isLocal {
            loadingState = .loading
            let path = currentPath
            sizeGen &+= 1
            let gen = sizeGen
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.listLocalDirectory(path: path)
                DispatchQueue.main.async {
                    guard self.sizeGen == gen else { return }
                    if case .failure(let error) = result {
                        self.loadingState = .error(error.localizedDescription)
                    } else if case .success(let items) = result {
                        self.directorySizes.removeAll()
                        self.files = items
                        self.applyFilterAndSort()
                        self.loadingState = self.files.isEmpty ? .empty : .loaded
                    }
                }
            }
        } else {
            loadingState = .loading
        }
    }

    nonisolated private func listLocalDirectory(path: String) -> Result<[FileNode], Error> {
        let url = URL(fileURLWithPath: path)
        var items: [FileNode] = []

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )

            for itemUrl in contents {
                let resourceValues = try itemUrl.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = resourceValues.isDirectory ?? false
                let size = Int64(resourceValues.fileSize ?? 0)
                let date = resourceValues.contentModificationDate ?? Date()

                items.append(
                    FileNode(
                        name: itemUrl.lastPathComponent,
                        path: itemUrl.path,
                        isDirectory: isDir,
                        size: isDir ? 0 : size,
                        modificationDate: date
                    )
                )
            }

            return .success(items)
        } catch {
            return .failure(error)
        }
    }

    private func calculateDirectorySizesAsync() {
        guard isLocal else { return }
        let gen = sizeGen
        let currentFiles = files
        let local = isLocal
        let storageId = MTPDeviceManager.shared.selectedStorageId
        Task {
            for i in currentFiles.indices where currentFiles[i].isDirectory {
                let isStale = await MainActor.run { self.sizeGen != gen }
                if isStale { break }

                let size = await FileNode.calculateDirectorySize(
                    path: currentFiles[i].path,
                    isLocal: local,
                    storageId: storageId
                )
                if let size = size {
                    await MainActor.run {
                        guard self.sizeGen == gen else { return }
                        self.directorySizes[currentFiles[i].path] = size
                    }
                }
            }
        }
    }

    private func calculateDirectorySize(for file: FileNode) {
        guard isLocal, file.isDirectory else { return }
        let path = file.path
        let gen = sizeGen
        Task {
            let size = await FileNode.calculateDirectorySize(
                path: path,
                isLocal: true,
                storageId: nil
            )
            await MainActor.run {
                guard self.sizeGen == gen, let size = size else { return }
                self.directorySizes[path] = size
            }
        }
    }


    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false

    private func applyFilterAndSort(using input: [FileNode]? = nil) {
        var result = input ?? files

        let showHidden = isLocal ? showHiddenFilesLocal : showHiddenFilesMTP
        if !showHidden {
            result = result.filter { !$0.name.hasPrefix(".") }
        }

        if !filterText.isEmpty {
            let query = filterText.lowercased()
            if query.hasPrefix(".") {
                let ext = String(query.dropFirst())
                result = result.filter {
                    $0.extensionName.lowercased() == ext || $0.isDirectory
                }
            } else {
                result = result.filter {
                    $0.name.lowercased().contains(query)
                }
            }
        }

        result.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return compareFiles(a, b)
        }

        displayedFiles = result

        if displayedFiles.isEmpty && !files.isEmpty && !filterText.isEmpty {
            loadingState = .empty
        } else if displayedFiles.isEmpty && files.isEmpty {
            loadingState = .empty
        } else {
            loadingState = .loaded
        }
    }

    private func compareFiles(_ a: FileNode, _ b: FileNode) -> Bool {
        let ascending: Bool
        switch sortColumn {
        case .name:
            ascending = a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .size:
            ascending = a.size < b.size
        case .type:
            ascending = a.extensionName.localizedStandardCompare(b.extensionName) == .orderedAscending
        case .dateModified:
            ascending = a.modificationDate < b.modificationDate
        }
        return sortDirection == .ascending ? ascending : !ascending
    }


    private func focusFileList() {
        if ExplorerKeyboardRouting.isEditingText(NSApp.keyWindow?.firstResponder) {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func handleDoubleClick(file: FileNode) {
        focusFileList()
        if file.isDirectory {
            navigateTo(path: file.path)
        } else if isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        }
    }

    private func handleSingleClick(file: FileNode) {
        focusFileList()
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            handleCommandClick(file: file)
        } else if flags.contains(.shift) {
            handleShiftClick(file: file)
        } else {
            setSelectionIfNeeded([file.path])
            lastClickedItemID = file.path
        }
    }

    private func dragProvider(for file: FileNode) -> NSItemProvider {
        focusFileList()
        let items: [FileNode]
        if selectedItems.contains(file.path) {
            items = displayedFiles.filter { selectedItems.contains($0.path) }
        } else {
            setSelectionIfNeeded([file.path])
            lastClickedItemID = file.path
            items = [file]
        }
        ErrorLogger.debug(
            "FileExplorerPane.dragProvider begin isLocal=\(isLocal) trigger=\(file.path) items=\(Self.describeFileNodes(items))"
        )
        
        let provider = NSItemProvider()
        let payloads = Self.internalPayload(for: items.map {
            DroppedFile(path: $0.path, isLocal: isLocal, name: $0.name, isDirectory: $0.isDirectory)
        })
        InAppDragState.shared.update(payload: payloads)
        
        if isLocal {
            let paths = items.map { $0.path }
            if let data = try? PropertyListSerialization.data(fromPropertyList: paths, format: .xml, options: 0) {
                provider.registerDataRepresentation(forTypeIdentifier: "NSFilenamesPboardType", visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            
            if let firstLocal = items.first {
                let url = URL(fileURLWithPath: firstLocal.path)
                provider.registerObject(url as NSURL, visibility: .all)
            }
        }

        provider.registerDataRepresentation(forTypeIdentifier: Self.internalFileItemsType, visibility: .all) { completion in
            completion(payloads.data(using: .utf8), nil)
            return nil
        }
        
        provider.registerDataRepresentation(for: .utf8PlainText, visibility: .all) { completion in
            let data = payloads.data(using: .utf8)
            completion(data, nil)
            return nil
        }
        if !isLocal {
            registerMTPFileRepresentation(on: provider, for: items)
        }
        provider.suggestedName = items.first?.name ?? file.name
        ErrorLogger.debug(
            "FileExplorerPane.dragProvider ready isLocal=\(isLocal) suggestedName=\(provider.suggestedName ?? "") types=\(provider.registeredTypeIdentifiers.joined(separator: ",")) payload=\(Self.logSafePayload(payloads))"
        )
        return provider
    }

    private func registerMTPFileRepresentation(on provider: NSItemProvider, for items: [FileNode]) {
        let files = items.filter { !$0.isDirectory }
        guard files.count == 1, let file = files.first else { return }
        guard let storageId = MTPDeviceManager.shared.selectedStorageId else { return }

        let typeIdentifier = UTType(filenameExtension: file.extensionName)?.identifier ?? UTType.data.identifier
        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1_000)
            ErrorLogger.debug("FileExplorerPane.dragProvider MTP file representation requested path=\(file.path)")

            Task.detached(priority: .userInitiated) {
                do {
                    let tempDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("macmtp-finder-drag-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

                    try await MTPBridgeFactory.sharedBridge().downloadFiles(
                        storageId: storageId,
                        sources: [file.path],
                        destination: tempDirectory.path,
                        onPreprocess: { _ in },
                        onProgress: { progressInfo in
                            progress.completedUnitCount = Int64(progressInfo.activeFileSize.progress * 1_000)
                        }
                    )

                    let downloadedURL = tempDirectory.appendingPathComponent(file.name)
                    progress.completedUnitCount = progress.totalUnitCount
                    ErrorLogger.debug("FileExplorerPane.dragProvider MTP file representation ready path=\(downloadedURL.path)")
                    completion(downloadedURL, false, nil)
                } catch {
                    ErrorLogger.log(error, message: "Prepare MTP file drag failed")
                    completion(nil, false, error)
                }
            }

            return progress
        }
    }

    private func handleCommandClick(file: FileNode) {
        var newSelection = selectedItems
        if selectedItems.contains(file.path) {
            newSelection.remove(file.path)
        } else {
            newSelection.insert(file.path)
        }
        setSelectionIfNeeded(newSelection)
        lastClickedItemID = file.path
    }

    private func handleShiftClick(file: FileNode) {
        guard let lastID = lastClickedItemID,
              let lastIndex = displayedFiles.firstIndex(where: { $0.path == lastID }),
              let currentIndex = displayedFiles.firstIndex(where: { $0.path == file.path })
        else {
            setSelectionIfNeeded([file.path])
            lastClickedItemID = file.path
            return
        }

        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        var newSelection = selectedItems
        for i in range {
            newSelection.insert(displayedFiles[i].path)
        }
        setSelectionIfNeeded(newSelection)
    }

    private func setSelectionIfNeeded(_ newSelection: Set<String>) {
        guard selectedItems != newSelection else { return }
        selectedItems = newSelection
    }

    private func clearSelectionIfNeeded() {
        guard !selectedItems.isEmpty else { return }
        selectedItems.removeAll()
    }

    private func handleKeyPress(_ key: String) {
        guard !key.isEmpty, !displayedFiles.isEmpty else { return }

        let now = Date()
        let timeDiff = now.timeIntervalSince(lastKeyTime)
        lastKeyTime = now

        if timeDiff < 1.0 {
            keySearchBuffer += key.lowercased()
        } else {
            keySearchBuffer = key.lowercased()
        }

        let matches = displayedFiles.filter { $0.name.lowercased().hasPrefix(keySearchBuffer) }
        guard !matches.isEmpty else { return }

        let selectedMatch = matches.first { selectedItems.contains($0.path) }

        if let current = selectedMatch, let currentIndex = matches.firstIndex(of: current) {
            let nextIndex = (currentIndex + 1) % matches.count
            let next = matches[nextIndex]
            setSelectionIfNeeded([next.path])
            lastClickedItemID = next.path
        } else {
            let first = matches[0]
            setSelectionIfNeeded([first.path])
            lastClickedItemID = first.path
        }
    }


    private func commitRename(file: FileNode) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != file.name else {
            return
        }

        if isLocal {
            let sourceURL = URL(fileURLWithPath: file.path)
            let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(trimmed)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
                loadDirectory()
            } catch {
                ErrorLogger.log(error, message: "Rename failed")
            }
        } else {
            onFileOperation?(.rename(oldPath: file.path, newName: trimmed))
        }
    }

    private func commitNewFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isLocal {
            let folderURL = URL(fileURLWithPath: currentPath).appendingPathComponent(trimmed)
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
                loadDirectory()
            } catch {
                ErrorLogger.log(error, message: "Create folder failed")
            }
        } else {
            onFileOperation?(.newFolder(parentPath: currentPath, name: trimmed))
        }
    }


    private func handleDrop(providers: [NSItemProvider], targetDirectory: String? = nil) -> Bool {
        let collectedFiles = ThreadSafeArray<DroppedFile>()
        let group = DispatchGroup()
        let dropDestination = targetDirectory ?? currentPath
        ErrorLogger.debug("FileExplorerPane.handleDrop begin isLocal=\(isLocal) destination=\(dropDestination) providers=\(providers.count)")

        for (index, provider) in providers.enumerated() {
            let suggestedName = provider.suggestedName ?? ""
            ErrorLogger.debug(
                "FileExplorerPane.handleDrop provider[\(index)] suggestedName=\(suggestedName) types=\(provider.registeredTypeIdentifiers.joined(separator: ","))"
            )
            group.enter()
            Self.loadDroppedFiles(from: provider) { files in
                files.forEach { collectedFiles.append($0) }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            var files = collectedFiles.all
            if files.isEmpty, let payload = InAppDragState.shared.recentPayload() {
                let fallbackFiles = Self.droppedFiles(fromInternalPayload: payload)
                files = fallbackFiles
                ErrorLogger.debug("FileExplorerPane.handleDrop using inAppDragStateFallback items=\(Self.describeDroppedFiles(fallbackFiles))")
            }
            ErrorLogger.debug("FileExplorerPane.handleDrop resolved files=\(files.count) items=\(Self.describeDroppedFiles(files)) isLocal=\(isLocal) destination=\(dropDestination)")
            if !files.isEmpty {
                onFilesDropped?(files, dropDestination)
            }
        }

        return true
    }

    // SwiftUI may strip the custom types during an in-app drag. In that case
    // plain text retains the full selection, while fileURL represents only its first item.
    nonisolated static func loadDroppedFiles(
        from provider: NSItemProvider,
        completion: @escaping ([DroppedFile]) -> Void
    ) {
        let types = [
            internalFileItemsType,
            finderFilenamesType,
            UTType.utf8PlainText.identifier,
            UTType.fileURL.identifier
        ].filter { provider.hasItemConformingToTypeIdentifier($0) }
        let suggestedName = provider.suggestedName ?? ""

        func load(at index: Int) {
            guard index < types.count else {
                completion([])
                return
            }
            let type = types[index]
            if type == UTType.fileURL.identifier {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    let files = ThreadSafeArray<DroppedFile>()
                    if let url, url.isFileURL {
                        appendLocalDroppedFile(url: url, suggestedName: suggestedName, to: files)
                    }
                    completion(files.all)
                }
                return
            }

            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                let files = ThreadSafeArray<DroppedFile>()
                if let data {
                    if type == finderFilenamesType {
                        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                        if let paths = plist as? [String] {
                            for path in paths {
                                appendLocalDroppedFile(
                                    url: URL(fileURLWithPath: path),
                                    suggestedName: paths.count == 1 ? suggestedName : "",
                                    to: files
                                )
                            }
                        }
                    } else if let text = String(data: data, encoding: .utf8) {
                        let internalFiles = droppedFiles(fromInternalPayload: text)
                        internalFiles.forEach { files.append($0) }
                        if internalFiles.isEmpty, type == UTType.utf8PlainText.identifier {
                            if let url = URL(string: text), url.isFileURL {
                                appendLocalDroppedFile(url: url, suggestedName: suggestedName, to: files)
                            } else if text.hasPrefix("/") {
                                appendLocalDroppedFile(url: URL(fileURLWithPath: text), suggestedName: suggestedName, to: files)
                            }
                        }
                    }
                }
                let resolved = files.all
                ErrorLogger.debug("FileExplorerPane.handleDrop type=\(type) resolved=\(resolved.count)")
                if resolved.isEmpty {
                    load(at: index + 1)
                } else {
                    completion(resolved)
                }
            }
        }

        load(at: 0)
    }

    nonisolated private static func logSafePayload(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "\n", with: "\\n")
        if compact.count <= 500 {
            return compact
        }
        return String(compact.prefix(500)) + "...<truncated>"
    }

    nonisolated private static func describeDroppedFiles(_ files: [DroppedFile]) -> String {
        files.map { file in
            "\(file.isLocal ? "local" : "mtp"):\(file.isDirectory ? "dir" : "file"):\(file.path)"
        }
        .joined(separator: "|")
    }

    nonisolated private static func describeFileNodes(_ files: [FileNode]) -> String {
        files.map { file in
            "\(file.isDirectory ? "dir" : "file"):\(file.path)"
        }
        .joined(separator: "|")
    }

    nonisolated static func internalPayload(for files: [DroppedFile]) -> String {
        // JSON escaping preserves newlines, colons and Unicode within each path.
        let data = try! JSONEncoder().encode(files)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func droppedFiles(fromInternalPayload payload: String) -> [DroppedFile] {
        if let data = payload.data(using: .utf8),
           let files = try? JSONDecoder().decode([DroppedFile].self, from: data) {
            guard files.allSatisfy({ $0.path.hasPrefix("/") }) else { return [] }
            return files
        }
        // Accept older app payloads only when every line is valid. Ambiguous or
        // damaged legacy data must never silently resolve to a truncated path.
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        var files: [DroppedFile] = []
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts[0] == "local" || parts[0] == "mtp",
                  parts[1] == "file" || parts[1] == "dir",
                  parts[2].hasPrefix("/") else { return [] }
            let path = String(parts[2])
            files.append(DroppedFile(path: path, isLocal: parts[0] == "local",
                                     name: (path as NSString).lastPathComponent,
                                     isDirectory: parts[1] == "dir"))
        }
        return files
    }

    nonisolated private static func appendLocalDroppedFile(url: URL, suggestedName: String, to files: ThreadSafeArray<DroppedFile>) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isDirectory = exists && isDir.boolValue
        let name = suggestedName.isEmpty ? url.lastPathComponent : suggestedName
        files.append(DroppedFile(path: url.path, isLocal: true, name: name, isDirectory: isDirectory))
    }


    private func fileSizeDisplay(for file: FileNode) -> String {
        if file.isDirectory {
            if let size = directorySizes[file.path] {
                return FormatUtils.formatBytes(size)
            }
            if let calculatedSize = file.calculatedSize {
                return FormatUtils.formatBytes(calculatedSize)
            }
            return "—"
        }
        return file.formattedSize
    }
}


    struct KeyboardLetterNav: NSViewRepresentable {
    var onKeyPress: (String) -> Void
    var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyPress: onKeyPress)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyPress = onKeyPress
        context.coordinator.isActive = isActive
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    class Coordinator: NSObject {
        var onKeyPress: (String) -> Void
        var isActive: Bool = false
        private var monitor: Any?

        init(onKeyPress: @escaping (String) -> Void) {
            self.onKeyPress = onKeyPress
        }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, self.isActive,
                      !ExplorerKeyboardRouting.isEditingText(event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder) else { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers == [] else { return event }
                guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return event }
                guard chars.rangeOfCharacter(from: .letters) != nil else { return event }
                self.onKeyPress(chars)
                return event
            }
        }

        func removeMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}


struct FilePropertiesView: View {
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    let file: FileNode
    let isLocal: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: file.iconName)
                    .font(.system(size: 32 * appFontScale))
                    .foregroundColor(file.iconColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(isLocal ? "Local file" : "MTP device file")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            Group {
                propertyRow(label: "Kind", value: file.isDirectory ? "Folder" : "Document")
                propertyRow(label: "Size", value: file.formattedSize)
                propertyRow(label: "Modified", value: file.formattedDate)
                propertyRow(label: "Path", value: file.path)
                if !file.parentPath.isEmpty {
                    propertyRow(label: "Parent", value: file.parentPath)
                }
                if !file.extensionName.isEmpty {
                    propertyRow(label: "Extension", value: file.extensionName)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func propertyRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

private struct FileIconView: View {
    let file: FileNode
    let isLocal: Bool
    let iconSize: CGFloat
    let thumbnailSize: CGSize

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: file.iconName)
                    .font(.system(size: iconSize))
                    .foregroundColor(file.iconColor)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .onAppear(perform: loadThumbnailIfNeeded)
        .onChange(of: file.path) { _, _ in
            thumbnail = nil
            loadThumbnailIfNeeded()
        }
    }

    private var thumbnailCornerRadius: CGFloat {
        min(6, max(3, thumbnailSize.width * 0.12))
    }

    private var shouldUseThumbnail: Bool {
        guard isLocal, !file.isDirectory else { return false }
        switch file.extensionName.lowercased() {
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tif", "tiff", "webp", "pdf":
            return true
        default:
            return false
        }
    }

    private var cacheKey: String {
        "\(file.path)|\(file.size)|\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height))"
    }

    private func loadThumbnailIfNeeded() {
        guard shouldUseThumbnail else { return }

        let key = cacheKey
        if let cached = FileThumbnailLoader.shared.cachedImage(for: key) {
            thumbnail = cached
            return
        }

        let path = file.path
        let size = thumbnailSize
        DispatchQueue.global(qos: .utility).async {
            let image = FileThumbnailLoader.makeThumbnail(path: path, pointSize: size)
            if let image {
                FileThumbnailLoader.shared.cache(image, for: key)
            }
            DispatchQueue.main.async {
                guard self.file.path == path else { return }
                self.thumbnail = image
            }
        }
    }
}

private final class FileThumbnailLoader: @unchecked Sendable {
    static let shared = FileThumbnailLoader()

    private let thumbnailCache = NSCache<NSString, NSImage>()

    private init() {}

    func cachedImage(for key: String) -> NSImage? {
        thumbnailCache.object(forKey: key as NSString)
    }

    func cache(_ image: NSImage, for key: String) {
        thumbnailCache.setObject(image, forKey: key as NSString)
    }

    static func makeThumbnail(path: String, pointSize: CGSize) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "pdf" {
            return makePDFThumbnail(url: url, pointSize: pointSize)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let maxPixelSize = max(32, Int(max(pointSize.width, pointSize.height) * scale))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: pointSize)
    }

    private static func makePDFThumbnail(url: URL, pointSize: CGSize) -> NSImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0)
        else { return nil }

        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        let scale = min(pointSize.width / pageBounds.width, pointSize.height / pageBounds.height)
        let targetSize = CGSize(
            width: max(1, pageBounds.width * scale),
            height: max(1, pageBounds.height * scale)
        )

        let drawRect = NSRect(
            x: (pointSize.width - targetSize.width) / 2,
            y: (pointSize.height - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )

        guard let sourceImage = page.thumbnail(of: targetSize, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let composed = NSImage(size: pointSize)
        composed.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        NSImage(cgImage: sourceImage, size: targetSize).draw(in: drawRect)
        composed.unlockFocus()
        return composed
    }
}


struct ItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { current, _ in current }
    }
}
