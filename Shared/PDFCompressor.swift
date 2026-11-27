import CoreGraphics
import Foundation
import PDFKit

struct PDFCompression {
    let url: URL
    let inputBytes: Int
    let outputBytes: Int
    let pageCount: Int
    let limitKB: Int
    let rasterized: Bool

    var fits: Bool { Limit.fits(outputBytes, kb: limitKB) }
}

enum PDFCompressor {
    static let freePageLimit = 5
    static let minimumDPI = 110
    private static let resolutions = [180, 144, minimumDPI]
    private static let qualities = [0.9, 0.7, 0.5, 0.32, 0.16, 0.08]

    static func compress(_ source: URL, to output: URL, limitKB: Int, hasAdvancedAccess: Bool) throws -> PDFCompression {
        guard Limit.range.contains(limitKB) else { throw Issue.invalidLimit }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        guard let originalBytes = try? size(of: source), originalBytes > 0,
              let document = PDFDocument(url: source) else { throw Issue.pdfUnreadable }
        guard !document.isLocked, !document.isEncrypted else { throw Issue.pdfLocked }
        let pages = document.pageCount
        guard pages > 0 else { throw Issue.pdfUnreadable }
        guard hasAdvancedAccess || pages <= freePageLimit else { throw Issue.pdfPageLimit }

        let files = FileManager.default
        let candidate = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? files.removeItem(at: candidate) }
        func result(bytes: Int, rasterized: Bool) -> PDFCompression {
            PDFCompression(url: output, inputBytes: originalBytes, outputBytes: bytes, pageCount: pages,
                           limitKB: limitKB, rasterized: rasterized)
        }
        func retainCandidate() throws {
            if files.fileExists(atPath: output.path) { try files.removeItem(at: output) }
            try files.moveItem(at: candidate, to: output)
        }
        func copyOriginal() throws {
            try files.copyItem(at: source, to: output)
            guard try size(of: output) == originalBytes else { throw Issue.writeFailed }
        }

        var smallest = originalBytes
        var flattened = false
        var hasText = false
        for index in 0..<pages {
            try Task.checkCancellation()
            if autoreleasepool(invoking: { (document.page(at: index)?.numberOfCharacters ?? 0) > 0 }) {
                hasText = true
                break
            }
        }
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        if hasText, document.write(to: candidate, withOptions: options),
           let written = try? size(of: candidate), written > 0, written <= originalBytes,
           PDFDocument(url: candidate)?.pageCount == pages {
            try Task.checkCancellation()
            try retainCandidate()
            smallest = written
            if Limit.fits(written, kb: limitKB) { return result(bytes: written, rasterized: false) }
        }
        if Limit.fits(originalBytes, kb: limitKB) {
            try copyOriginal()
            return result(bytes: originalBytes, rasterized: false)
        }

        let budget = limitKB * 1_000
        for dpi in resolutions {
            for quality in qualities {
                try Task.checkCancellation()
                try? files.removeItem(at: candidate)
                let ceiling = dpi == minimumDPI || quality == qualities.last ? smallest - 1 : budget
                let bytes = try render(document, dpi: dpi, quality: quality, to: candidate, ceiling: ceiling)
                guard let bytes, autoreleasepool(invoking: { PDFDocument(url: candidate)?.pageCount == pages }) else { continue }
                try retainCandidate()
                smallest = bytes
                flattened = true
                if bytes <= budget { return result(bytes: bytes, rasterized: true) }
            }
        }
        if !files.fileExists(atPath: output.path) { try copyOriginal() }
        return result(bytes: smallest, rasterized: flattened)
    }

    private static func render(_ document: PDFDocument, dpi: Int, quality: Double, to url: URL,
                               ceiling: Int) throws -> Int? {
        let writer = try ImagePDFWriter(url: url, pages: document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let appended = try autoreleasepool {
                guard let page = document.page(at: index), let reference = page.pageRef else {
                    throw Issue.pdfUnreadable
                }
                let box = page.bounds(for: .cropBox)
                let turned = reference.rotationAngle % 180 != 0
                let width = turned ? box.height : box.width
                let height = turned ? box.width : box.height
                guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw Issue.pdfUnreadable }
                let scale = CGFloat(dpi) / 72
                let w = ceil(width * scale), h = ceil(height * scale)
                guard w <= CGFloat(Compressor.sideBudget), h <= CGFloat(Compressor.sideBudget),
                      w * h <= CGFloat(Compressor.pixelBudget) else { return false }
                let context = try Compressor.whiteContext(width: Int(w), height: Int(h))
                let rect = CGRect(x: 0, y: 0, width: w, height: h)
                context.saveGState()
                context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
                context.clip(to: box)
                context.drawPDFPage(reference)
                context.translateBy(x: box.minX, y: box.minY)
                for annotation in page.annotations where annotation.shouldDisplay {
                    context.saveGState()
                    annotation.draw(with: .cropBox, in: context)
                    context.restoreGState()
                }
                context.restoreGState()
                guard let image = context.makeImage() else { throw Issue.pdfUnreadable }
                let jpeg = try Compressor.encodeJPEG(image, quality: quality)
                try writer.add(jpeg, width: width, height: height)
                return true
            }
            guard appended, try writer.byteCount <= ceiling else { return nil }
        }
        let written = try writer.finish()
        return written <= ceiling ? written : nil
    }

    private static func size(of url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Issue.unreadable }
        return size
    }
}

private final class ImagePDFWriter {
    private let file: FileHandle
    private var offsets: [UInt64] = [0]
    private var nextPage = 3
    private let locale = Locale(identifier: "en_US_POSIX")

    init(url: URL, pages: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Issue.writeFailed }
        file = try FileHandle(forWritingTo: url)
        try write("%PDF-1.4\n%")
        try file.write(contentsOf: Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
        try object("<< /Type /Catalog /Pages 2 0 R >>")
        let kids = (0..<pages).map { "\(3 + 3 * $0) 0 R" }.joined(separator: " ")
        try object("<< /Type /Pages /Count \(pages) /Kids [\(kids)] >>")
    }

    deinit { try? file.close() }

    var byteCount: Int { get throws { Int(try file.offset()) } }

    func add(_ jpeg: CompressedJPEG, width: CGFloat, height: CGFloat) throws {
        let w = String(format: "%.4f", locale: locale, Double(width))
        let h = String(format: "%.4f", locale: locale, Double(height))
        let contents = "q \(w) 0 0 \(h) 0 0 cm /Im0 Do Q\n"
        try object("""
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)]
            /Resources << /XObject << /Im0 \(nextPage + 2) 0 R >> >>
            /Contents \(nextPage + 1) 0 R >>
            """)
        try object("<< /Length \(contents.utf8.count) >>\nstream\n\(contents)endstream")
        try beginObject()
        try write("""
            << /Type /XObject /Subtype /Image /Width \(jpeg.width) /Height \(jpeg.height)
            /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.data.count) >>
            stream

            """)
        try file.write(contentsOf: jpeg.data)
        try write("\nendstream\nendobj\n")
        nextPage += 3
    }

    func finish() throws -> Int {
        let start = try byteCount
        try write("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
        for offset in offsets.dropFirst() {
            guard offset < 10_000_000_000 else { throw Issue.tooLarge }
            try write(String(format: "%010llu 00000 n \n", offset))
        }
        try write("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n")
        return try byteCount
    }

    private func object(_ body: String) throws {
        try beginObject()
        try write(body + "\nendobj\n")
    }

    private func beginObject() throws {
        let number = offsets.count
        offsets.append(try file.offset())
        try write("\(number) 0 obj\n")
    }

    private func write(_ string: String) throws {
        try file.write(contentsOf: Data(string.utf8))
    }
}
