import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import Vision

public struct LoadedImage {
    /// First frame, with the EXIF orientation already applied.
    public let image: CGImage
    public let frameCount: Int
    public let properties: [CFString: Any]
}

/// Top-left-origin RGBA view of an image, used to verify pixels.
public struct PixelGrid {
    public let width: Int
    public let height: Int
    let bytes: [UInt8]

    /// Out-of-range coordinates read as transparent black.
    public func rgba(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
}

/// Native image work: ImageIO for decode/encode, Core Graphics for geometry
/// and compositing, Core Image for colour adjustment, Vision for codes and
/// subject masks. Tool output is 8-bit sRGB.
public enum ImageEngine {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let maximumSide = 30_000
    /// Total pixel budget for any decoded or rendered bitmap (100 MP is
    /// about 400 MB as RGBA), limiting each bitmap allocation.
    static let maximumPixels = 100_000_000

    /// Validates a size given as floating point and only then converts it.
    static func checkedSize(width: Double, height: Double, what: String) throws -> (width: Int, height: Int) {
        guard width.isFinite, height.isFinite else {
            throw OrbitError.invalidOptions("\(what) has a size that is not a number.")
        }
        let roundedWidth = width.rounded(), roundedHeight = height.rounded()
        guard roundedWidth >= 1, roundedHeight >= 1,
              roundedWidth <= Double(maximumSide), roundedHeight <= Double(maximumSide),
              roundedWidth * roundedHeight <= Double(maximumPixels) else {
            throw OrbitError.invalidOptions(
                "\(what) would be \(String(format: "%.0f×%.0f", min(roundedWidth, 1e12), min(roundedHeight, 1e12))) pixels; "
                + "the limit is \(maximumSide) per side and \(maximumPixels / 1_000_000) megapixels in total.")
        }
        return (Int(roundedWidth), Int(roundedHeight))
    }

    // MARK: Decode / encode

    /// A small, orientation-corrected preview plus the full pixel size, for editors.
    public struct Preview {
        public let image: CGImage
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    public static func preview(_ url: URL, maxPixelSize: Int = 900) -> Preview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        guard let declaredWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let declaredHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              let dimensions = try? checkedSize(width: declaredWidth, height: declaredHeight, what: "The preview") else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(2048, max(16, maxPixelSize)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        var width = dimensions.width, height = dimensions.height
        // Orientations 5–8 display the stored pixels turned by a quarter.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation >= 5 { swap(&width, &height) }
        return Preview(image: image, pixelWidth: width, pixelHeight: height)
    }

    public static func load(_ url: URL) throws -> LoadedImage {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw OrbitError.malformed("\(name) could not be opened as an image.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw OrbitError.malformed("\(name) is not a decodable image.")
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        // Refuse oversized images from the header, before any pixels are decoded.
        let tooLarge = OrbitError.unsupported(
            "\(name) is larger than \(maximumPixels / 1_000_000) megapixels (or \(maximumSide) pixels on a side) and is not processed.")
        if let declaredWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let declaredHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            guard declaredWidth <= Double(maximumSide), declaredHeight <= Double(maximumSide),
                  declaredWidth * declaredHeight <= Double(maximumPixels) else { throw tooLarge }
        }

        var image: CGImage?
        if orientation != 1,
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            // A full-size "thumbnail" is the ImageIO way to bake in orientation.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if image == nil {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let decoded = image, decoded.width > 0, decoded.height > 0 else {
            throw OrbitError.malformed("\(name) is damaged or not a decodable image.")
        }
        guard decoded.width <= maximumSide, decoded.height <= maximumSide,
              decoded.width * decoded.height <= maximumPixels else { throw tooLarge }
        return LoadedImage(image: decoded, frameCount: count, properties: properties)
    }

    /// EXIF/GPS/IPTC/TIFF metadata worth carrying over, minus orientation and
    /// pixel-size fields that no longer describe the processed pixels.
    static func preservedMetadata(_ properties: [CFString: Any]) -> [CFString: Any] {
        var kept: [CFString: Any] = [:]
        let keys: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
        ]
        for key in keys {
            if let value = properties[key] { kept[key] = value }
        }
        if var tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            kept[kCGImagePropertyExifDictionary] = exif
        }
        return kept
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    public static func write(
        _ image: CGImage, to url: URL, spec: ImageFormatSpec, quality: Double? = nil, metadata: [CFString: Any]? = nil
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, spec.uti as CFString, 1, nil) else {
            throw OrbitError.unsupported("This Mac cannot write \(spec.ext.uppercased()) images.")
        }
        var properties: [CFString: Any] = metadata ?? [:]
        if spec.lossy {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality ?? 0.9, 0.01), 1)
        }
        var output = image
        if !spec.supportsAlpha && hasAlpha(image) {
            // Formats without transparency are flattened onto white.
            output = try redraw(image, width: image.width, height: image.height, background: CGColor(gray: 1, alpha: 1))
        }
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OrbitError.engineFailure("Writing the \(spec.ext.uppercased()) image failed.")
        }
    }

    /// One PDF page per image; one pixel maps to one point, capped at the PDF page limit.
    public static func writePDF(images: [CGImage], to url: URL) throws {
        guard let first = images.first else {
            throw OrbitError.invalidInput("No images to place in the PDF.")
        }
        var box = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw OrbitError.engineFailure("Could not create the PDF.")
        }
        for image in images {
            let scale = min(1, 14_400 / CGFloat(max(image.width, image.height)))
            var pageBox = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.beginPage(mediaBox: &pageBox)
            context.draw(image, in: pageBox)
            context.endPage()
        }
        context.closePDF()
    }

    // MARK: Bitmap helpers

    static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= maximumSide, height <= maximumSide,
              width * height <= maximumPixels,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OrbitError.invalidOptions("Image size \(width)×\(height) is not supported.")
        }
        return context
    }

    static func finish(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw OrbitError.engineFailure("Rendering the image failed.")
        }
        return image
    }

    static func redraw(_ image: CGImage, width: Int, height: Int, background: CGColor? = nil) throws -> CGImage {
        let context = try self.context(width: width, height: height)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.setFillColor(background)
            context.fill(full)
        }
        context.interpolationQuality = .high
        context.draw(image, in: full)
        return try finish(context)
    }

    /// Converts a top-left-origin rectangle to Core Graphics coordinates.
    static func flipped(_ rect: CGRect, imageHeight: Int) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(imageHeight) - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func pixels(of image: CGImage) throws -> PixelGrid {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw OrbitError.engineFailure("Could not read image pixels.")
        }
        return PixelGrid(width: width, height: height, bytes: bytes)
    }

    public static func color(hex: String) throws -> CGColor {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else {
            throw OrbitError.invalidOptions("Colour \"\(hex)\" must look like #RRGGBB or #RRGGBBAA.")
        }
        let rgba = text.count == 6 ? (value << 8) | 0xFF : value
        func component(_ shift: UInt64) -> CGFloat { CGFloat((rgba >> shift) & 0xFF) / 255 }
        return CGColor(srgbRed: component(24), green: component(16), blue: component(8), alpha: component(0))
    }

    // MARK: Operations

    /// Resolves `width`/`height` (pixels), `scale` (percent) or `maxDimension`.
    static func targetSize(for image: CGImage, options: ToolOptions) throws -> (width: Int, height: Int) {
        let width = Double(image.width), height = Double(image.height)
        var target: (Double, Double)
        let requestedWidth = try options.double("width")
        let requestedHeight = try options.double("height")
        if let requestedWidth, let requestedHeight {
            target = (requestedWidth, requestedHeight)
        } else if let requestedWidth {
            target = (requestedWidth, height * requestedWidth / width)
        } else if let requestedHeight {
            target = (width * requestedHeight / height, requestedHeight)
        } else if let scale = try options.double("scale") {
            target = (width * scale / 100, height * scale / 100)
        } else if let maxDimension = try options.double("maxDimension") {
            let factor = min(1, maxDimension / max(width, height))
            target = (width * factor, height * factor)
        } else {
            throw OrbitError.invalidOptions("Give a width, a height, a scale in percent, or a maxDimension.")
        }
        // Range-checked as Double first: converting 1e300 to Int would trap.
        return try checkedSize(width: target.0, height: target.1, what: "The resized image")
    }

    // MARK: Framing

    /// Parses `"16:9"`, `"1.5"` or `"original"` (nil) into a width/height ratio.
    public static func aspectRatio(_ text: String?) throws -> Double? {
        guard let text, !text.isEmpty, text.lowercased() != "original" else { return nil }
        let parts = text.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        var ratio: Double?
        if parts.count == 2, let width = parts[0], let height = parts[1], height > 0 {
            ratio = width / height
        } else if parts.count == 1 {
            ratio = parts[0]
        }
        guard let ratio, ratio.isFinite, ratio >= 0.05, ratio <= 20 else {
            throw OrbitError.invalidOptions("Aspect ratio \"\(text)\" must look like 16:9 (between 1:20 and 20:1).")
        }
        return ratio
    }

    /// Places the untouched image on a larger solid canvas with padding,
    /// rounded corners and a soft shadow. `padding` and `cornerRadius` are in
    /// pixels, `shadow` is a 0–100 strength and `aspect` (width/height)
    /// widens or heightens the canvas around the centred image.
    public static func frame(
        _ image: CGImage, padding: Double, cornerRadius: Double, shadow: Double, color: CGColor, aspect: Double?
    ) throws -> CGImage {
        let imageWidth = Double(image.width), imageHeight = Double(image.height)
        guard padding.isFinite, cornerRadius.isFinite, shadow.isFinite, padding >= 0, cornerRadius >= 0 else {
            throw OrbitError.invalidOptions("Padding and corner radius must be zero or more.")
        }
        var canvasWidth = imageWidth + padding * 2
        var canvasHeight = imageHeight + padding * 2
        if let aspect {
            if canvasWidth / canvasHeight < aspect {
                canvasWidth = canvasHeight * aspect
            } else {
                canvasHeight = canvasWidth / aspect
            }
        }
        let size = try checkedSize(width: canvasWidth, height: canvasHeight, what: "The framed image")
        let context = try self.context(width: size.width, height: size.height)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))

        // Whole-pixel placement keeps the original pixels unresampled.
        let rect = CGRect(
            x: ((Double(size.width) - imageWidth) / 2).rounded(.down),
            y: ((Double(size.height) - imageHeight) / 2).rounded(.down),
            width: imageWidth, height: imageHeight)
        let radius = CGFloat(min(cornerRadius, min(imageWidth, imageHeight) / 2))
        let outline = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        let strength = min(max(shadow, 0), 100) / 100
        if strength > 0 {
            let blur = CGFloat(strength * 0.08 * max(imageWidth, imageHeight))
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                color: CGColor(gray: 0, alpha: CGFloat(0.25 + 0.3 * strength)))
            context.setFillColor(color.copy(alpha: 1) ?? color)
            context.addPath(outline)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.interpolationQuality = .none
        context.draw(image, in: rect)
        context.restoreGState()
        return try finish(context)
    }

    /// `frame` with sizes relative to the image: `paddingPercent` of its
    /// longer side and `cornerPercent` of its shorter side (50 = fully round).
    /// Being relative, a downscaled preview frames exactly like the original.
    public static func frame(
        _ image: CGImage, paddingPercent: Double, cornerPercent: Double, shadow: Double, color: CGColor, aspect: Double?
    ) throws -> CGImage {
        guard paddingPercent.isFinite, cornerPercent.isFinite,
              (0...200).contains(paddingPercent), (0...50).contains(cornerPercent) else {
            throw OrbitError.invalidOptions("Padding must be 0–200 % and corners 0–50 %.")
        }
        let longer = Double(max(image.width, image.height)), shorter = Double(min(image.width, image.height))
        return try frame(
            image, padding: (longer * paddingPercent / 100).rounded(), cornerRadius: shorter * cornerPercent / 100,
            shadow: shadow, color: color, aspect: aspect)
    }

    /// Crops to a top-left-origin pixel rectangle, clamped to the image.
    static func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = rect.integral.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1, let cropped = image.cropping(to: clamped) else {
            throw OrbitError.invalidOptions("The crop rectangle lies outside the image.")
        }
        return cropped
    }

    /// Rotates clockwise by a multiple of 90° and optionally mirrors.
    static func rotate(_ image: CGImage, degrees: Int, flipHorizontal: Bool, flipVertical: Bool) throws -> CGImage {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized % 90 == 0 else {
            throw OrbitError.invalidOptions("Rotation must be 0, 90, 180 or 270 degrees.")
        }
        let swaps = normalized == 90 || normalized == 270
        let width = swaps ? image.height : image.width
        let height = swaps ? image.width : image.height
        let context = try self.context(width: width, height: height)
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(normalized) * .pi / 180)
        context.scaleBy(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
        context.draw(image, in: CGRect(
            x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
            width: CGFloat(image.width), height: CGFloat(image.height)))
        return try finish(context)
    }

    static func adjust(
        _ image: CGImage, brightness: Double, contrast: Double, saturation: Double, exposure: Double
    ) throws -> CGImage {
        let input = CIImage(cgImage: image)
        var output = input.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness,
            kCIInputContrastKey: contrast,
            kCIInputSaturationKey: saturation,
        ])
        if exposure != 0 {
            output = output.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }
        guard let rendered = CIContext(options: nil).createCGImage(output, from: input.extent) else {
            throw OrbitError.engineFailure("Core Image could not render the adjusted image.")
        }
        return rendered
    }

    /// Composites outlined boxes and one line of text onto the image.
    static func annotate(
        _ image: CGImage, text: String?, origin: CGPoint, fontSize: Double, color: CGColor,
        boxes: [CGRect], lineWidth: Double
    ) throws -> CGImage {
        let context = try self.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setStrokeColor(color)
        context.setLineWidth(CGFloat(lineWidth))
        for box in boxes {
            context.stroke(flipped(box, imageHeight: image.height))
        }
        if let text, !text.isEmpty {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(fontSize), nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            context.textPosition = CGPoint(x: origin.x, y: CGFloat(image.height) - origin.y - CTFontGetAscent(font))
            CTLineDraw(line, context)
        }
        return try finish(context)
    }

    /// Paints opaque black over the rectangles. The result is a new bitmap,
    /// so the covered pixels no longer exist in the output.
    static func redact(_ image: CGImage, rects: [CGRect]) throws -> CGImage {
        let context = try self.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects {
            context.fill(flipped(rect, imageHeight: image.height))
        }
        return try finish(context)
    }

    /// Scales to fit a transparent square canvas (used for ICO).
    static func fitSquare(_ image: CGImage, side: Int) throws -> CGImage {
        let context = try self.context(width: side, height: side)
        let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        return try finish(context)
    }

    /// Keeps the foreground subject and makes everything else transparent.
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        guard #available(macOS 14.0, *) else {
            throw OrbitError.unsupported("Background removal needs macOS 14 or later.")
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else {
                throw OrbitError.engineFailure("No foreground subject was found in the image.")
            }
            let buffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
            let masked = CIImage(cvPixelBuffer: buffer)
            guard let rendered = CIContext(options: nil).createCGImage(masked, from: masked.extent) else {
                throw OrbitError.engineFailure("Could not render the masked image.")
            }
            return rendered
        } catch let error as OrbitError {
            throw error
        } catch {
            throw OrbitError.engineFailure("Vision could not isolate the subject: \(error.localizedDescription)")
        }
    }

    /// Payloads of QR codes and other barcodes found by Vision.
    static func readCodes(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OrbitError.engineFailure("Vision barcode detection failed: \(error.localizedDescription)")
        }
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}
