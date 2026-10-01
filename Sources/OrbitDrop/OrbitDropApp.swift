import AppKit
import SwiftUI
import OrbitCore

@main
enum OrbitDropMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Menu-bar utility; the bundled Info.plist sets LSUIElement as well.
        application.setActivationPolicy(.accessory)
        // NSApplication holds its delegate weakly; keep it alive for the
        // whole run loop instead of relying on a local's lifetime.
        retainedDelegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    @MainActor private static var retainedDelegate: AppDelegate?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let pausedKey = "gestureMonitorPaused"
    private static let launchedKey = "hasLaunchedBefore"

    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var window: NSWindow?
    private var dragMonitor: DragMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        let monitor = DragMonitor(model: model)
        monitor.onPick = { [weak self] urls, choice in self?.handlePick(urls, choice) }
        dragMonitor = monitor
        if !UserDefaults.standard.bool(forKey: AppDelegate.pausedKey) {
            monitor.start()
        }
        refreshPauseItem()

        // The first launch opens the converter so the app is usable at once.
        // When the app was launched in the background, the window is shown
        // without activating, so the user's current app keeps the focus.
        if !UserDefaults.standard.bool(forKey: AppDelegate.launchedKey) {
            UserDefaults.standard.set(true, forKey: AppDelegate.launchedKey)
            showMainWindow(activate: NSApp.isActive)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(activate: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor?.stop()
        model.cancel()
    }

    // MARK: Menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle", accessibilityDescription: "OrbitDrop")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "OD" }
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open OrbitDrop", action: #selector(openMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let pause = NSMenuItem(title: "Pause Shift-Drag Monitor", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseItem = pause

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit OrbitDrop", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func refreshPauseItem() {
        pauseItem?.state = (dragMonitor?.isRunning ?? false) ? .off : .on
    }

    @objc private func openMainWindow() {
        showMainWindow(activate: true)
    }

    @objc private func togglePause() {
        guard let monitor = dragMonitor else { return }
        if monitor.isRunning {
            monitor.stop()
        } else {
            monitor.start()
        }
        UserDefaults.standard.set(!monitor.isRunning, forKey: AppDelegate.pausedKey)
        refreshPauseItem()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Window

    /// `activate: false` puts the window on screen without taking focus.
    private func showMainWindow(activate: Bool) {
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            created.title = "OrbitDrop"
            created.isReleasedWhenClosed = false
            created.contentViewController = NSHostingController(rootView: MainView(model: model))
            created.setContentSize(NSSize(width: 820, height: 520))
            created.center()
            created.setFrameAutosaveName("OrbitDropMainWindow")
            window = created
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    // MARK: Radial drops

    private func handlePick(_ urls: [URL], _ choice: RadialChoice) {
        guard !model.isRunning else {
            showMainWindow(activate: false)
            return
        }
        model.setFiles(urls)
        // Only a tool that needs input takes the focus; a plain conversion
        // shows its progress without interrupting the app the user is in.
        var needsInput = false
        if case .tool(let tool) = choice { needsInput = !tool.parameters.isEmpty }
        if case .openWindow = choice { needsInput = true }
        showMainWindow(activate: needsInput)
        switch choice {
        case .format(let format):
            model.selectedTargetID = format.id
            model.convert()
        case .tool(let tool):
            model.selectedToolID = tool.id
            if tool.parameters.isEmpty {
                model.runTool(tool, values: [:])
            } else {
                model.pendingTool = tool
            }
        case .openWindow:
            break
        }
    }
}
