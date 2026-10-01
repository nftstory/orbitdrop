import AppKit
import OrbitCore

enum RadialChoice {
    case format(OutputFormat)
    case tool(ToolDescriptor)
    case openWindow
}

struct RadialChip {
    let label: String
    let title: String
    let symbol: String?
    let choice: RadialChoice
}

/// Owns the non-activating panel that appears at the cursor during a
/// Shift-drag. The panel never becomes key and never moves once shown.
final class RadialPanelController {
    enum Mode {
        case formats, tools
    }

    static let side: CGFloat = 320
    static let maximumChips = 10

    var onPick: (([URL], RadialChoice) -> Void)?
    private(set) var isVisible = false

    private let model: AppModel
    private let panel: NSPanel
    private let radialView: RadialView
    private var urls: [URL] = []
    private var mode = Mode.formats

    init(model: AppModel) {
        self.model = model
        let frame = NSRect(x: 0, y: 0, width: RadialPanelController.side, height: RadialPanelController.side)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        radialView = RadialView(frame: frame)
        panel.contentView = radialView
        radialView.onDrop = { [weak self] dropped, chip in
            guard let self else { return }
            let files = dropped.isEmpty ? self.urls : dropped
            self.hide()
            self.onPick?(files, chip.choice)
        }
    }

    func show(at point: NSPoint, urls: [URL], mode: Mode) {
        self.urls = urls
        self.mode = mode
        reloadChips()

        // Centre on the cursor, kept inside the visible frame of its screen.
        let side = RadialPanelController.side
        var origin = NSPoint(x: point.x - side / 2, y: point.y - side / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - side)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - side)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func setMode(_ newMode: Mode) {
        guard isVisible, newMode != mode else { return }
        mode = newMode
        reloadChips()
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        isVisible = false
    }

    private func reloadChips() {
        let engine = model.engine
        var chips: [RadialChip]
        switch mode {
        case .formats:
            chips = engine.commonTargets(for: urls).formats.map {
                RadialChip(label: $0.ext.uppercased(), title: $0.title, symbol: nil, choice: .format($0))
            }
        case .tools:
            chips = engine.commonTools(for: urls).map {
                RadialChip(label: "", title: $0.title, symbol: $0.symbol, choice: .tool($0))
            }
        }
        // Too many to place on one ring: the last chip opens the full window.
        if chips.count > RadialPanelController.maximumChips {
            chips = Array(chips.prefix(RadialPanelController.maximumChips - 1))
            chips.append(RadialChip(label: "", title: "More in window…", symbol: "ellipsis", choice: .openWindow))
        }
        if chips.isEmpty {
            chips = [RadialChip(label: "", title: "Open OrbitDrop", symbol: "macwindow", choice: .openWindow)]
        }
        let count = urls.count == 1 ? "1 file" : "\(urls.count) files"
        radialView.configure(
            chips: chips,
            title: mode == .formats ? "Convert" : "Tools",
            subtitle: mode == .formats ? "\(count) · ⌥ for tools" : "\(count) · release ⌥ for formats")
    }
}

/// Draws circular chips on a ring over system material and accepts the drop.
final class RadialView: NSView {
    var onDrop: (([URL], RadialChip) -> Void)?

    private var chips: [RadialChip] = []
    private var title = ""
    private var subtitle = ""
    private var highlighted: Int?

    private let effectView = NSVisualEffectView()
    private let canvas = ChipCanvas()

    private static let chipRadius: CGFloat = 29
    private static let ringRadius: CGFloat = 112

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = RadialView.circleMask(diameter: bounds.width)
        addSubview(effectView)

        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.drawHandler = { [weak self] in self?.drawContents() }
        addSubview(canvas)

        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private static func circleMask(diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    func configure(chips: [RadialChip], title: String, subtitle: String) {
        self.chips = chips
        self.title = title
        self.subtitle = subtitle
        highlighted = nil
        canvas.needsDisplay = true
    }

    // MARK: Geometry

    private func chipCenter(_ index: Int) -> NSPoint {
        // Clockwise from the top.
        let angle = CGFloat.pi / 2 - 2 * CGFloat.pi * CGFloat(index) / CGFloat(max(chips.count, 1))
        return NSPoint(
            x: bounds.midX + RadialView.ringRadius * cos(angle),
            y: bounds.midY + RadialView.ringRadius * sin(angle))
    }

    private func chipIndex(at point: NSPoint) -> Int? {
        chips.indices.first { index in
            let center = chipCenter(index)
            return hypot(point.x - center.x, point.y - center.y) <= RadialView.chipRadius + 6
        }
    }

    // MARK: Drawing

    private func drawCentered(_ text: String, at center: NSPoint, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    private func drawContents() {
        for (index, chip) in chips.enumerated() {
            let center = chipCenter(index)
            let radius = RadialView.chipRadius
            let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let isHighlighted = index == highlighted
            let path = NSBezierPath(ovalIn: rect)
            (isHighlighted ? NSColor.systemTeal : NSColor.windowBackgroundColor.withAlphaComponent(0.9)).setFill()
            path.fill()
            (isHighlighted ? NSColor.systemBlue : NSColor.systemTeal.withAlphaComponent(0.7)).setStroke()
            path.lineWidth = isHighlighted ? 2.5 : 1.5
            path.stroke()

            let foreground = isHighlighted ? NSColor.white : NSColor.labelColor
            if let name = chip.symbol {
                let configuration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [foreground]))
                let image = (NSImage(systemSymbolName: name, accessibilityDescription: chip.title)
                    ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: chip.title))?
                    .withSymbolConfiguration(configuration)
                if let image {
                    let size = image.size
                    image.draw(in: NSRect(
                        x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
                }
            } else {
                let size: CGFloat = chip.label.count > 4 ? 10 : 12
                drawCentered(chip.label, at: center, font: .systemFont(ofSize: size, weight: .semibold), color: foreground)
            }
        }

        let middle = NSPoint(x: bounds.midX, y: bounds.midY)
        let heading = highlighted.map { chips[$0].title } ?? title
        drawCentered(
            heading, at: NSPoint(x: middle.x, y: middle.y + 9),
            font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        drawCentered(
            highlighted == nil ? subtitle : "Drop to start", at: NSPoint(x: middle.x, y: middle.y - 11),
            font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    }

    // MARK: Drag destination

    private func update(with sender: NSDraggingInfo) -> NSDragOperation {
        let index = chipIndex(at: convert(sender.draggingLocation, from: nil))
        if index != highlighted {
            highlighted = index
            canvas.needsDisplay = true
        }
        return index == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(with: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(with: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
        canvas.needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = chipIndex(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let chip = chips[index]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let urls = (objects as? [URL]) ?? []
        let handler = onDrop
        // Let the drag session finish before any window is shown.
        DispatchQueue.main.async {
            handler?(urls, chip)
        }
        return true
    }
}

/// Transparent layer above the material that draws the chips.
final class ChipCanvas: NSView {
    var drawHandler: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        drawHandler?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
