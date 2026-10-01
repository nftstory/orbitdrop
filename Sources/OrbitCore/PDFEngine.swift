import Foundation
import CoreGraphics
import PDFKit

/// Native PDF work with PDFKit (page assembly, text) and Core Graphics
/// (rasterization).
public enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw OrbitError.malformed("\(url.lastPathComponent) is damaged or not a PDF.")
        }
        if document.isLocked {
            throw OrbitError.unsupported("\(url.lastPathComponent) is password-protected and cannot be processed.")
        }
        guard document.pageCount > 0 else {
            throw OrbitError.malformed("\(url.lastPathComponent) has no pages.")
        }
        return document
    }

    static func openForDrawing(_ url: URL) throws -> CGPDFDocument {
        _ = try open(url)
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            throw OrbitError.malformed("\(url.lastPathComponent) is damaged or not a PDF.")
        }
        return document
    }

    /// Extracted text of every page, in page order.
    public static func pageTexts(_ url: URL) throws -> [String] {
        let document = try open(url)
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    public static func pageCount(_ url: URL) throws -> Int {
        try open(url).pageCount
    }

    /// Writes a new PDF containing the given 1-based pages, in that order.
    static func write(pages: [Int], from document: PDFDocument, to url: URL) throws {
        let output = PDFDocument()
        for number in pages {
            guard let page = document.page(at: number - 1), let copy = page.copy() as? PDFPage else {
                throw OrbitError.engineFailure("Could not copy page \(number).")
            }
            output.insert(copy, at: output.pageCount)
        }
        guard output.pageCount > 0, output.write(to: url) else {
            throw OrbitError.engineFailure("Writing the PDF failed.")
        }
    }

    static func merge(_ urls: [URL], to url: URL, token: CancellationToken?) throws {
        let output = PDFDocument()
        for source in urls {
            try token?.check()
            let document = try open(source)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else {
                    throw OrbitError.engineFailure("Could not copy page \(index + 1) of \(source.lastPathComponent).")
                }
                output.insert(copy, at: output.pageCount)
            }
        }
        guard output.pageCount > 0, output.write(to: url) else {
            throw OrbitError.engineFailure("Writing the merged PDF failed.")
        }
    }

    /// Rotates the selected 1-based pages (all when `pages` is nil) clockwise.
    static func rotate(_ source: URL, degrees: Int, pages: Set<Int>?, to url: URL) throws {
        guard degrees % 90 == 0 else {
            throw OrbitError.invalidOptions("Rotation must be a multiple of 90 degrees.")
        }
        let document = try open(source)
        for index in 0..<document.pageCount where pages == nil || pages!.contains(index + 1) {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (((page.rotation + degrees) % 360) + 360) % 360
        }
        guard document.write(to: url) else {
            throw OrbitError.engineFailure("Writing the rotated PDF failed.")
        }
    }

    /// Size of the page as displayed (rotation applied), in points.
    static func displaySize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.mediaBox)
        let quarterTurns = Int(page.rotationAngle) / 90
        return quarterTurns % 2 != 0 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Pixel size of a page of `size` points at `dpi`, validated before any
    /// integer conversion or allocation (page boxes are untrusted input).
    static func pixelSize(points size: CGSize, dpi: Double) throws -> (width: Int, height: Int) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw OrbitError.malformed("The PDF contains a page with no usable area.")
        }
        guard dpi.isFinite, dpi > 0 else {
            throw OrbitError.invalidOptions("The resolution must be a positive number.")
        }
        return try ImageEngine.checkedSize(
            width: max(1, Double(size.width) * dpi / 72), height: max(1, Double(size.height) * dpi / 72),
            what: "A page at \(Int(min(dpi, 100_000))) dpi")
    }

    /// The highest resolution up to `dpi` at which a page of `size` points
    /// still fits the pixel limits.
    static func fittingDPI(points size: CGSize, dpi: Double) -> Double {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return dpi }
        let width = Double(size.width), height = Double(size.height)
        let bySide = Double(ImageEngine.maximumSide) * 72 / max(width, height)
        let byArea = (Double(ImageEngine.maximumPixels) / (width * height)).squareRoot() * 72
        return min(dpi, bySide * 0.999, byArea * 0.999)
    }

    static func renderPage(_ page: CGPDFPage, dpi: Double) throws -> CGImage {
        let size = displaySize(page)
        let (width, height) = try pixelSize(points: size, dpi: dpi)
        let context = try ImageEngine.context(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.concatenate(page.getDrawingTransform(
            .mediaBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return try ImageEngine.finish(context)
    }

    /// Rebuilds the PDF from page bitmaps with opaque boxes painted in.
    /// Every page becomes an image, so no original text or vector content
    /// survives anywhere in the output. `rects` are in points, top-left origin.
    static func redactRasterized(
        _ source: URL, rects: [CGRect], pages: Set<Int>?, dpi: Double, to url: URL, token: CancellationToken?,
        progress: ((Double) -> Void)?
    ) throws {
        let document = try openForDrawing(source)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw OrbitError.engineFailure("Could not create the PDF.")
        }
        var closed = false
        defer { if !closed { pdf.closePDF() } }

        let scale = CGFloat(dpi / 72)
        let total = document.numberOfPages
        for number in 1...total {
            try token?.check()
            guard let page = document.page(at: number) else {
                throw OrbitError.malformed("Page \(number) could not be read.")
            }
            var image = try renderPage(page, dpi: dpi)
            if pages == nil || pages!.contains(number) {
                let context = try ImageEngine.context(width: image.width, height: image.height)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                for rect in rects {
                    context.fill(CGRect(
                        x: rect.minX * scale, y: CGFloat(image.height) - rect.maxY * scale,
                        width: rect.width * scale, height: rect.height * scale))
                }
                image = try ImageEngine.finish(context)
            }
            var pageBox = CGRect(origin: .zero, size: displaySize(page))
            pdf.beginPage(mediaBox: &pageBox)
            pdf.draw(image, in: pageBox)
            pdf.endPage()
            progress?(Double(number) / Double(total))
        }
        pdf.closePDF()
        closed = true
    }
}
