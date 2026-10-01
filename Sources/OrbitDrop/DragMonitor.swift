import AppKit
import OrbitCore

/// Watches for "Shift while dragging files" and shows the radial panel.
///
/// Only passive NSEvent mouse monitors are used, together with polling of
/// `NSEvent.modifierFlags`. No event tap is installed and no Accessibility
/// or Input Monitoring permission is requested. If the system delivers no
/// global mouse events, the gesture simply never appears and the main
/// window remains the way to convert.
///
/// Limits (v1): only real file URLs on the drag pasteboard are recognised
/// (no file promises), and Escape can dismiss the panel only while OrbitDrop
/// itself receives key events.
final class DragMonitor {
    var onPick: (([URL], RadialChoice) -> Void)?

    private let panel: RadialPanelController
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var pollTimer: Timer?

    private var mouseIsDown = false
    private var downLocation = NSPoint.zero
    private var baselineChangeCount = 0
    private var dismissedThisDrag = false

    private static let minimumDragDistance: CGFloat = 6

    init(model: AppModel) {
        panel = RadialPanelController(model: model)
        panel.onPick = { [weak self] urls, choice in
            // One pick per drag: never reopen the panel for the same gesture.
            self?.dismissedThisDrag = true
            self?.onPick?(urls, choice)
        }
    }

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard !isRunning else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.panel.isVisible else { return event }
            self.dismissedThisDrag = true
            self.panel.hide()
            return nil
        }
    }

    func stop() {
        for monitor in [globalMonitor, localMonitor, keyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
        stopPolling()
        mouseIsDown = false
        panel.hide()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            panel.hide()
            mouseIsDown = true
            dismissedThisDrag = false
            downLocation = NSEvent.mouseLocation
            // A drag that starts now bumps this count; an old drag's leftovers do not.
            baselineChangeCount = NSPasteboard(name: .drag).changeCount
            startPolling()
        case .leftMouseDragged:
            evaluate()
        case .leftMouseUp:
            handleRelease()
        default:
            break
        }
    }

    private func handleRelease() {
        guard mouseIsDown else { return }
        mouseIsDown = false
        stopPolling()
        // Leave the panel up briefly so a drop on it can be delivered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.hideIfIdle()
        }
    }

    private func hideIfIdle() {
        if !mouseIsDown { panel.hide() }
    }

    /// Modifier keys produce no mouse events, so they are polled while the
    /// button is held. This also catches Shift pressed on a stationary drag.
    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func draggedFileURLs() -> [URL] {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baselineChangeCount else { return [] }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    private func evaluate() {
        guard mouseIsDown else { return }
        // Watchdog: a mouse-up can go unobserved (for example when the drag
        // ends inside another app's modal loop). The real button state is
        // checked on every tick so the panel and the timer cannot linger.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            handleRelease()
            return
        }
        let flags = NSEvent.modifierFlags
        if panel.isVisible {
            // The panel stays where it appeared so its chips can be reached.
            panel.setMode(flags.contains(.option) ? .tools : .formats)
            return
        }
        guard !dismissedThisDrag, flags.contains(.shift) else { return }
        let location = NSEvent.mouseLocation
        let distance = hypot(location.x - downLocation.x, location.y - downLocation.y)
        guard distance >= DragMonitor.minimumDragDistance else { return }
        let urls = draggedFileURLs()
        guard !urls.isEmpty else { return }
        panel.show(at: location, urls: urls, mode: flags.contains(.option) ? .tools : .formats)
    }
}
