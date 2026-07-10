import AppKit
import SwiftUI

@main
@MainActor
enum LociMain {
    private static let appDelegate = LociAppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        app.run()
    }
}

extension Notification.Name {
    static let lociShowCommandPalette = Notification.Name("LociShowCommandPalette")
    static let lociToggleNotebookInspector = Notification.Name("LociToggleNotebookInspector")
}

@MainActor
final class LociAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var localAPI: LocalReferenceAPIServer?
    private var libraryStore: LibraryStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyAppMigration.run()
        LociEnvironment.reload()
        configureAppIcon()
        setupMenus()
        let libraryStore = LibraryStore.load()
        self.libraryStore = libraryStore
        LociTelemetry.recordAppLaunch(store: libraryStore)
        ReferenceThumbnail.warmImagesForFirstPaint(
            for: libraryStore.visibleItems.prefix(42),
            limit: 42,
            timeBudget: 0.12
        )
        ReferenceThumbnail.preloadImages(for: libraryStore.visibleItems.prefix(96))
        Task { await ImportCoordinator.shared.startAutonomousAgent() }
        localAPI = LocalReferenceAPIServer(store: libraryStore)
        localAPI?.start()

        let contentView = ContentView(store: libraryStore)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = AppBrand.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.contentViewController = hostingController
        window.delegate = self
        configureToolbar(for: window)
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak libraryStore] in
            libraryStore?.finishDeferredStartupWork()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "loci" {
            Task {
                do {
                    try await XOAuthManager.shared.completeAuthorization(from: url)
                    openSettings()
                } catch {
                    ErrorPresenter.shared.show(.networkError("X sign-in failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func setupMenus() {
        let mainMenu = NSMenu()
        let appName = AppBrand.name

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Text responders receive native edit actions first. Copy and paste fall
        // back to the library selection when focus is on the SwiftUI workspace.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(performCut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(performCopy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(performPaste(_:)), keyEquivalent: "v"))
        for item in editMenu.items.suffix(3) { item.target = self }
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let commandPaletteItem = NSMenuItem(title: "Command Palette", action: #selector(showCommandPalette), keyEquivalent: "k")
        commandPaletteItem.keyEquivalentModifierMask = .command
        commandPaletteItem.target = self
        viewMenu.addItem(commandPaletteItem)
        let inspectorItem = NSMenuItem(title: "Show or Hide Ask Loci", action: #selector(toggleNotebookInspector), keyEquivalent: "i")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        inspectorItem.target = self
        viewMenu.addItem(inspectorItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func performCut(_ sender: Any?) {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            NSSound.beep()
            return
        }
        textView.cut(sender)
    }

    @objc private func performCopy(_ sender: Any?) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.copy(sender)
        } else {
            libraryStore?.copySelectionToPasteboard()
        }
    }

    @objc private func performPaste(_ sender: Any?) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.paste(sender)
        } else {
            libraryStore?.importPasteboard(undoManager: window?.undoManager)
        }
    }

    @objc private func showCommandPalette(_ sender: Any? = nil) {
        NotificationCenter.default.post(name: .lociShowCommandPalette, object: nil)
    }

    @objc private func toggleNotebookInspector(_ sender: Any? = nil) {
        NotificationCenter.default.post(name: .lociToggleNotebookInspector, object: nil)
    }

    private func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "LociMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space,
         .lociCommandPalette, .lociNotebookInspector, .lociSettings]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.lociCommandPalette, .flexibleSpace, .lociNotebookInspector, .lociSettings]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self

        switch itemIdentifier {
        case .lociCommandPalette:
            item.label = "Command Palette"
            item.paletteLabel = "Command Palette"
            item.toolTip = "Command Palette (⌘K)"
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command Palette")
            item.action = #selector(showCommandPalette)
        case .lociNotebookInspector:
            item.label = "Ask Loci"
            item.paletteLabel = "Show or Hide Ask Loci"
            item.toolTip = "Show or Hide Ask Loci (⌥⌘I)"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Show or Hide Ask Loci")
            item.action = #selector(toggleNotebookInspector)
        case .lociSettings:
            item.label = "Settings"
            item.paletteLabel = "Settings"
            item.toolTip = "Settings (⌘,)"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.action = #selector(openSettings)
        default:
            return nil
        }
        return item
    }

    @objc private func openSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let libraryStore else { return }
        let settingsView = SettingsView(store: libraryStore)
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentMinSize = NSSize(width: 660, height: 560)
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    private func configureAppIcon() {
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let lociCommandPalette = NSToolbarItem.Identifier("LociCommandPalette")
    static let lociNotebookInspector = NSToolbarItem.Identifier("LociNotebookInspector")
    static let lociSettings = NSToolbarItem.Identifier("LociSettings")
}
