import Cocoa
import SwiftUI


class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var preferencesWindowController: NSWindowController?
    var aboutWindowController: NSWindowController?
    var helpWindowController: NSWindowController?
    private var isRelaunchingForLanguageChange = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = LocalizedRootView {
            ContentView()
        }
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "macMTP"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.setFrameAutosaveName("macMTPMainWindow")
        window.minSize = NSSize(width: 900, height: 550)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        
        setupMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: L10n.languageDidChange,
            object: nil
        )
        
        USBWatcher.shared.startWatching()

        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }
    
    
    @MainActor private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.t("About macMTP"), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L10n.t("Preferences…"), action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L10n.t("Hide macMTP"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: L10n.t("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: L10n.t("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L10n.t("Quit macMTP"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: L10n.t("File"))
        fileMenu.addItem(withTitle: L10n.t("New Folder"), action: #selector(menuNewFolder), keyEquivalent: "n")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: L10n.t("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.t("Edit"))
        editMenu.addItem(withTitle: L10n.t("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: L10n.t("View"))
        viewMenu.addItem(withTitle: L10n.t("Refresh"), action: #selector(menuRefresh), keyEquivalent: "r")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: L10n.t("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.t("Window"))
        windowMenu.addItem(withTitle: L10n.t("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.t("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: L10n.t("Help"))
        helpMenu.addItem(withTitle: L10n.t("macMTP Help"), action: #selector(showHelp), keyEquivalent: "?")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        
        NSApp.mainMenu = mainMenu
    }

    @MainActor @objc private func languageDidChange() {
        relaunchApp()
    }

    @MainActor private func relaunchApp() {
        guard !isRelaunchingForLanguageChange else { return }
        isRelaunchingForLanguageChange = true

        let appURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 0.5; /usr/bin/open -n \"\(appURL.path.replacingOccurrences(of: "\"", with: "\\\""))\""
        ]
        try? process.run()

        NSApp.terminate(nil)
    }
    
    
    @MainActor @objc private func showAbout() {
        if let existing = aboutWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hostingView = NSHostingView(rootView: LocalizedRootView {
            AboutView()
        })
        let aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        aboutWindow.titlebarAppearsTransparent = true
        aboutWindow.titleVisibility = .hidden
        aboutWindow.isMovableByWindowBackground = true
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.contentView = hostingView
        aboutWindow.center()
        
        let controller = NSWindowController(window: aboutWindow)
        aboutWindowController = controller
        aboutWindow.makeKeyAndOrderFront(nil)
    }
    
    @objc private func menuNewFolder() {
        NotificationCenter.default.post(name: .menuNewFolderRequested, object: nil)
    }

    @objc private func menuRefresh() {
        NotificationCenter.default.post(name: .menuRefreshRequested, object: nil)
    }

    @MainActor @objc private func showPreferences() {
        if let existing = preferencesWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hostingView = NSHostingView(rootView: LocalizedRootView {
            PreferencesView()
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t("macMTP Preferences")
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        let controller = NSWindowController(window: window)
        preferencesWindowController = controller
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor @objc private func showHelp() {
        if let existing = helpWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let hostingView = NSHostingView(rootView: LocalizedRootView {
            HelpView()
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t("macMTP Help")
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        let controller = NSWindowController(window: window)
        helpWindowController = controller
        window.makeKeyAndOrderFront(nil)
    }
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
