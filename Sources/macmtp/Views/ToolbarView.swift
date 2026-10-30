import SwiftUI

struct ToolbarView: View {
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    var isMTPConnected: Bool
    var deviceName: String
    var isReleasingMTPPort: Bool
    var shouldShowReleaseMTP: Bool
    var mtpStatusMessage: String?
    var mtpCapabilities: MTPDeviceCapabilities = .unknown
    var onForceMTPAccess: () -> Void
    var onRefresh: () -> Void
    var onCopy: () -> Void
    var onCut: () -> Void
    var onPaste: () -> Void
    var onDelete: () -> Void
    var onNewFolder: () -> Void
    var onSelectAll: () -> Void
    @Binding var layoutMode: ExplorerLayoutMode
    var hasClipboardContent: Bool
    var selectedCount: Int
    
    @State private var isRefreshing: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            deviceStatusPanel
                .padding(.leading, 16)
            
            Spacer()
            
            fileOperationButtons
                .padding(.trailing, 16)
        }
        .frame(height: 56)
        .background(toolbarBackground)
    }
    
    
    private var deviceStatusPanel: some View {
        HStack(spacing: 10) {
            let hasMTPPortConflict = shouldShowReleaseMTP && !isMTPConnected
            let title = isMTPConnected ? deviceName : (hasMTPPortConflict ? L10n.t("MTP Port In Use") : L10n.t("No Device Detected"))
            let subtitle = isMTPConnected
                ? capabilitySubtitle
                : (hasMTPPortConflict ? (mtpStatusMessage ?? L10n.t("macOS is holding the MTP interface")) : L10n.t("Connect your Android device via USB cable"))

            ZStack {
                Image(systemName: isMTPConnected ? "ipad.and.iphone" : (hasMTPPortConflict ? "exclamationmark.triangle" : "ipad.and.iphone.slash"))
                    .font(.system(size: 22 * appFontScale, weight: .medium))
                    .foregroundColor(isMTPConnected ? .green : (hasMTPPortConflict ? .orange : .secondary))
                    .symbolEffect(.pulse, isActive: isMTPConnected)
                
                if isMTPConnected {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .offset(x: 14, y: -10)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13 * appFontScale, weight: .semibold))
                    .lineLimit(1)
                
                Text(subtitle)
                    .font(.system(size: 11 * appFontScale))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if hasMTPPortConflict {
                Button(action: onForceMTPAccess) {
                    HStack(spacing: 4) {
                        if isReleasingMTPPort {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "lock.open")
                                .font(.system(size: 11 * appFontScale, weight: .medium))
                        }
                        Text(L10n.t("Fix MTP Connection"))
                            .font(.system(size: 11 * appFontScale, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReleasingMTPPort)
                .help(L10n.t("Stop macOS camera services that may be blocking this device, then reconnect"))
            }
        }
        .help(capabilityHelp)
    }

    private var capabilitySubtitle: String {
        let operations = [
            mtpCapabilities.moveObject ? "Move" : nil,
            mtpCapabilities.copyObject ? "Copy" : nil,
            mtpCapabilities.getPartialObject ? "Partial" : nil,
            mtpCapabilities.editObjects ? "Edit" : nil
        ].compactMap { $0 }

        if operations.isEmpty {
            return "LibMTP · Basic operations"
        }
        return "LibMTP · \(operations.joined(separator: " / "))"
    }

    private var capabilityHelp: String {
        guard isMTPConnected else {
            return mtpStatusMessage ?? L10n.t("Connect your Android device via USB cable")
        }

        let flags = [
            "MoveObject: \(mtpCapabilities.moveObject ? "yes" : "no")",
            "CopyObject: \(mtpCapabilities.copyObject ? "yes" : "no")",
            "GetPartialObject: \(mtpCapabilities.getPartialObject ? "yes" : "no")",
            "SendPartialObject: \(mtpCapabilities.sendPartialObject ? "yes" : "no")",
            "EditObject: \(mtpCapabilities.editObjects ? "yes" : "no")"
        ]
        return flags.joined(separator: "\n")
    }
    
    
    private var fileOperationButtons: some View {
        HStack(spacing: 6) {
            ToolbarButton(
                icon: "checkmark.circle",
                label: "Select All",
                shortcut: "⌘A",
                action: onSelectAll
            )
            
            ToolbarDivider()
            
            ToolbarButton(
                icon: "scissors",
                label: "Cut",
                shortcut: "⌘X",
                isEnabled: selectedCount > 0,
                action: onCut
            )
            
            ToolbarButton(
                icon: "doc.on.doc",
                label: "Copy",
                shortcut: "⌘C",
                isEnabled: selectedCount > 0,
                action: onCopy
            )
            
            ToolbarButton(
                icon: "doc.on.clipboard",
                label: "Paste",
                shortcut: "⌘V",
                action: onPaste
            )
            
            ToolbarDivider()
            
            ToolbarButton(
                icon: "trash",
                label: "Delete",
                shortcut: "⌘⌫",
                isEnabled: selectedCount > 0,
                isDestructive: true,
                action: onDelete
            )
            
            ToolbarButton(
                icon: "folder.badge.plus",
                label: "New Folder",
                shortcut: "⌘N",
                action: onNewFolder
            )
            
            ToolbarDivider()

            Picker("", selection: $layoutMode) {
                ForEach(ExplorerLayoutMode.allCases) { mode in
                    Image(systemName: mode.iconName)
                        .help(L10n.t(mode.rawValue))
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 78)
            .help(L10n.t("Switch between single-pane and dual-pane layout"))

            ToolbarDivider()
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isRefreshing = true
                }
                onRefresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isRefreshing = false
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14 * appFontScale, weight: .medium))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(.easeInOut(duration: 0.3), value: isRefreshing)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.t("Refresh directory listing (⌘R)"))
            .frame(width: 30, height: 30)
            
            ToolbarDivider()
            
            Button(action: {
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.perform(NSSelectorFromString("showPreferences"))
                }
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16 * appFontScale, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.t("Preferences"))
            .frame(width: 30, height: 30)

            Button(action: {
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.perform(NSSelectorFromString("showAbout"))
                }
            }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16 * appFontScale, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.t("About macMTP"))
            .frame(width: 30, height: 30)
        }
    }
    
    
    private var toolbarBackground: some View {
        VStack(spacing: 0) {
            Color(NSColor.windowBackgroundColor)
            Divider()
        }
    }
}


struct ToolbarButton: View {
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    let icon: String
    let label: String
    var shortcut: String = ""
    var isEnabled: Bool = true
    var isDestructive: Bool = false
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: {
            if isEnabled {
                action()
                isHovered = false
            }
        }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14 * appFontScale, weight: .medium))
                    .foregroundColor(buttonColor)
                
                Text(L10n.t(label))
                    .font(.system(size: 9 * appFontScale, weight: .medium))
                    .foregroundColor(buttonColor)
            }
            .frame(width: 52, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && isEnabled ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!isEnabled)
        .help("\(L10n.t(label))\(shortcut.isEmpty ? "" : " (\(shortcut))")")
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private var buttonColor: Color {
        if !isEnabled {
            return .secondary.opacity(0.5)
        }
        if isDestructive {
            return .red
        }
        return .primary
    }
}


struct ToolbarDivider: View {
    var body: some View {
        Divider()
            .frame(height: 24)
            .padding(.horizontal, 4)
    }
}
