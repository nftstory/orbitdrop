import SwiftUI
import AppKit
import OrbitCore

// Interactive editors for the two image tools that are awkward to drive
// with numbers alone. Both only collect options; the work is done by the
// same OrbitCore tools the CLI uses, on the original pixels.

private func fittedPreview(_ image: CGImage) -> some View {
    Image(decorative: image, scale: 1)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
}

// MARK: - Frame on canvas

/// Live preview of `image-frame`: padding, corners, shadow, colour, shape.
struct FrameEditorSheet: View {
    let tool: ToolDescriptor
    @ObservedObject var model: AppModel

    @State private var preview: ImageEngine.Preview?
    @State private var padding = 8.0
    @State private var corners = 0.0
    @State private var shadow = 40.0
    @State private var color = Color(red: 0.95, green: 0.95, blue: 0.97)
    @State private var aspect = "original"

    private static let aspects = ["original", "1:1", "4:3", "3:2", "16:9", "9:16", "4:5"]

    init(tool: ToolDescriptor, model: AppModel) {
        self.tool = tool
        self.model = model
        _preview = State(initialValue: model.selectedRow.flatMap { ImageEngine.preview($0.url) })
    }

    private var hex: String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "#F2F2F7" }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    private var ratio: Double? {
        (try? ImageEngine.aspectRatio(aspect)) ?? nil
    }

    /// The same algorithm as the final output, run on the small preview.
    /// Sizes are relative, so the preview matches the full-size result.
    private var rendered: CGImage? {
        guard let preview, let canvas = try? ImageEngine.color(hex: hex) else { return nil }
        return try? ImageEngine.frame(
            preview.image, paddingPercent: padding, cornerPercent: corners, shadow: shadow, color: canvas, aspect: ratio)
    }

    private var outputSize: String {
        guard let preview else { return "" }
        let pad = (Double(max(preview.pixelWidth, preview.pixelHeight)) * padding / 100).rounded()
        var width = Double(preview.pixelWidth) + pad * 2, height = Double(preview.pixelHeight) + pad * 2
        if let ratio {
            if width / height < ratio { width = height * ratio } else { height = width / ratio }
        }
        return "Output \(Int(width.rounded())) × \(Int(height.rounded())) px"
    }

    var body: some View {
        if preview == nil {
            // The image could not be previewed; the plain form still works.
            ToolOptionsSheet(tool: tool, model: model)
        } else {
            editor
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.title)
                .font(.headline)
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let rendered {
                        fittedPreview(rendered)
                            .padding(10)
                    } else {
                        Text("These settings cannot be rendered.")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 460, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 10) {
                    slider("Padding", value: $padding, range: 0...40, unit: "%")
                    slider("Corners", value: $corners, range: 0...50, unit: "%")
                    slider("Shadow", value: $shadow, range: 0...100, unit: "")
                    ColorPicker("Canvas colour", selection: $color, supportsOpacity: false)
                    Picker("Canvas shape", selection: $aspect) {
                        ForEach(FrameEditorSheet.aspects, id: \.self) { option in
                            Text(option == "original" ? "Fit image" : option).tag(option)
                        }
                    }
                    Text(outputSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("The image itself is not scaled or cropped; the canvas grows around it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.rows.count > 1 {
                        Text("Applies to all \(model.rows.count) images; the preview shows the selected one.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 230)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingTool = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save Framed Copy") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rendered == nil)
            }
        }
        .padding(20)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(Int(value.wrappedValue.rounded()))\(unit)")
                .font(.callout)
            Slider(value: value, in: range)
        }
    }

    private func apply() {
        let values: [String: Any] = [
            "paddingPercent": padding.rounded(), "cornerPercent": corners.rounded(), "shadow": shadow.rounded(),
            "color": hex, "aspect": aspect,
        ]
        model.pendingTool = nil
        model.runTool(tool, values: values)
    }
}

// MARK: - Crop

/// Drag-to-select crop with corner handles, aspect presets and exact pixel
/// fields. The selection is stored relative to the image and converted to
/// original pixels, so the crop is cut from the full-resolution file.
struct CropEditorSheet: View {
    let tool: ToolDescriptor
    @ObservedObject var model: AppModel

    @State private var preview: ImageEngine.Preview?
    @State private var selection = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var aspect = "Free"

    private static let aspects = ["Free", "Original", "1:1", "4:3", "3:2", "16:9", "9:16", "4:5"]

    init(tool: ToolDescriptor, model: AppModel) {
        self.tool = tool
        self.model = model
        _preview = State(initialValue: model.selectedRow.flatMap { ImageEngine.preview($0.url) })
    }

    private var pixelSize: CGSize {
        CGSize(width: preview?.pixelWidth ?? 1, height: preview?.pixelHeight ?? 1)
    }

    /// Width/height of the selection in normalized units for the chosen preset.
    private var normalizedAspect: CGFloat? {
        let pixelAspect: Double?
        switch aspect {
        case "Free": pixelAspect = nil
        case "Original": pixelAspect = Double(pixelSize.width / pixelSize.height)
        default: pixelAspect = (try? ImageEngine.aspectRatio(aspect)) ?? nil
        }
        guard let pixelAspect else { return nil }
        return CGFloat(pixelAspect) * pixelSize.height / pixelSize.width
    }

    /// The selection in original pixels, top-left origin, inside the image.
    private var pixels: (x: Int, y: Int, width: Int, height: Int) {
        let fullWidth = Int(pixelSize.width), fullHeight = Int(pixelSize.height)
        let x = min(max(Int((selection.minX * pixelSize.width).rounded()), 0), fullWidth - 1)
        let y = min(max(Int((selection.minY * pixelSize.height).rounded()), 0), fullHeight - 1)
        let width = min(max(Int((selection.width * pixelSize.width).rounded()), 1), fullWidth - x)
        let height = min(max(Int((selection.height * pixelSize.height).rounded()), 1), fullHeight - y)
        return (x, y, width, height)
    }

    var body: some View {
        if let preview {
            editor(preview)
        } else {
            ToolOptionsSheet(tool: tool, model: model)
        }
    }

    private func editor(_ preview: ImageEngine.Preview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.title)
                .font(.headline)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                CropCanvas(image: preview.image, selection: $selection, normalizedAspect: normalizedAspect)
                    .padding(10)
            }
            .frame(width: 600, height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Picker("Aspect", selection: $aspect) {
                    ForEach(CropEditorSheet.aspects, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 180)
                pixelField("X", \.minX, full: pixelSize.width)
                pixelField("Y", \.minY, full: pixelSize.height)
                pixelField("W", \.width, full: pixelSize.width)
                pixelField("H", \.height, full: pixelSize.height)
                Spacer()
            }
            Text("Drag inside the rectangle to move it, a corner to resize, or outside to draw a new one. "
                 + "Image \(preview.pixelWidth) × \(preview.pixelHeight) px, crop \(pixels.width) × \(pixels.height) px.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Select All") { selection = CGRect(x: 0, y: 0, width: 1, height: 1); aspect = "Free" }
                Spacer()
                Button("Cancel") { model.pendingTool = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save Cropped Copy") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onChange(of: aspect) { _ in conformToAspect() }
    }

    /// A text field showing one edge of the selection in original pixels.
    private func pixelField(_ label: String, _ keyPath: KeyPath<CGRect, CGFloat>, full: CGFloat) -> some View {
        let binding = Binding<String>(
            get: { String(Int((selection[keyPath: keyPath] * full).rounded())) },
            set: { text in
                guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { return }
                let fraction = min(CGFloat(value) / full, 1)
                var updated = selection
                switch keyPath {
                case \CGRect.minX: updated.origin.x = min(fraction, 1 - updated.width)
                case \CGRect.minY: updated.origin.y = min(fraction, 1 - updated.height)
                case \CGRect.width: updated.size.width = min(max(fraction, 1 / full), 1 - updated.minX)
                default: updated.size.height = min(max(fraction, 1 / full), 1 - updated.minY)
                }
                selection = updated
            })
        return HStack(spacing: 3) {
            Text(label)
                .foregroundColor(.secondary)
            TextField(label, text: binding)
                .frame(width: 62)
        }
    }

    /// Reshapes the selection around its centre to the chosen preset.
    private func conformToAspect() {
        guard let target = normalizedAspect, target > 0 else { return }
        var width = selection.width
        var height = width / target
        if height > 1 {
            height = 1
            width = height * target
        }
        if width > 1 {
            width = 1
            height = width / target
        }
        let x = min(max(selection.midX - width / 2, 0), 1 - width)
        let y = min(max(selection.midY - height / 2, 0), 1 - height)
        selection = CGRect(x: x, y: y, width: width, height: height)
    }

    private func apply() {
        let crop = pixels
        model.pendingTool = nil
        model.runTool(tool, values: ["x": crop.x, "y": crop.y, "width": crop.width, "height": crop.height])
    }
}

/// The image with a dimmed surround, a selection rectangle and four handles.
/// `selection` is normalized (0…1) with the origin at the top-left.
private struct CropCanvas: View {
    let image: CGImage
    @Binding var selection: CGRect
    let normalizedAspect: CGFloat?

    private enum Mode {
        case move(CGRect)
        case stretch(anchor: CGPoint)
    }

    @State private var mode: Mode?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let frame = CGRect(
                x: selection.minX * size.width, y: selection.minY * size.height,
                width: selection.width * size.width, height: selection.height * size.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(frame)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Path { path in path.addRect(frame) }
                    .stroke(Color.white, lineWidth: 1.5)
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.teal, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(
                            x: index % 2 == 0 ? frame.minX : frame.maxX,
                            y: index < 2 ? frame.minY : frame.maxY)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in drag(value, in: size) }
                    .onEnded { _ in mode = nil })
        }
        .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
    }

    private func drag(_ value: DragGesture.Value, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
        }
        let start = normalized(value.startLocation)

        if mode == nil {
            // Corner order: top-left, top-right, bottom-left, bottom-right;
            // the fixed anchor of a resize is the opposite corner.
            let corners = [
                CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
                CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY),
            ]
            let reachX = 14 / size.width, reachY = 14 / size.height
            if let hit = corners.firstIndex(where: { abs($0.x - start.x) <= reachX && abs($0.y - start.y) <= reachY }) {
                mode = .stretch(anchor: corners[3 - hit])
            } else if selection.contains(start) {
                mode = .move(selection)
            } else {
                mode = .stretch(anchor: start)
            }
        }

        switch mode {
        case .move(let original):
            let x = min(max(original.minX + value.translation.width / size.width, 0), 1 - original.width)
            let y = min(max(original.minY + value.translation.height / size.height, 0), 1 - original.height)
            selection = CGRect(x: x, y: y, width: original.width, height: original.height)
        case .stretch(let anchor):
            selection = CropCanvas.rect(from: anchor, to: normalized(value.location), aspect: normalizedAspect)
        case .none:
            break
        }
    }

    /// The rectangle spanned from a fixed anchor to the pointer, kept inside
    /// the unit square and, when asked, at a fixed width/height ratio.
    static func rect(from anchor: CGPoint, to point: CGPoint, aspect: CGFloat?) -> CGRect {
        let right = point.x >= anchor.x, down = point.y >= anchor.y
        let maxWidth = right ? 1 - anchor.x : anchor.x
        let maxHeight = down ? 1 - anchor.y : anchor.y
        var width = min(abs(point.x - anchor.x), maxWidth)
        var height = min(abs(point.y - anchor.y), maxHeight)
        if let aspect, aspect > 0 {
            height = width / aspect
            if height > maxHeight {
                height = maxHeight
                width = height * aspect
            }
            if width > maxWidth {
                width = maxWidth
                height = width / aspect
            }
        }
        width = max(width, 0.004)
        height = max(height, 0.004)
        let rect = CGRect(
            x: right ? anchor.x : anchor.x - width, y: down ? anchor.y : anchor.y - height, width: width, height: height)
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.isEmpty ? rect : clipped
    }
}
