import PDFKit
import XCTest

final class PDFTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testThreePagePDFMeets100KBAndKeepsPageOrder() throws {
        let source = folder.appendingPathComponent("original.pdf")
        let target = folder.appendingPathComponent("compressed.pdf")
        try FixturePDF.write(to: source, scanned: true)
        let input = try Data(contentsOf: source)
        XCTAssertGreaterThan(input.count, 100_000)
        let result = try PDFCompressor.compress(source, to: target, limitKB: 100, hasAdvancedAccess: false)
        XCTAssertTrue(result.fits)
        XCTAssertTrue(result.rasterized)
        XCTAssertEqual(result.inputBytes, input.count)
        XCTAssertEqual(try Data(contentsOf: source), input)
        XCTAssertLessThanOrEqual(result.outputBytes, 100_000)
        XCTAssertEqual(try Data(contentsOf: target).count, result.outputBytes)
        let output = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(output.pageCount, 3)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual((0..<3).compactMap { output.page(at: $0)?.bounds(for: .cropBox).width }, [360, 372, 384])
    }

    func testTextPDFKeepsSearchableText() throws {
        let source = folder.appendingPathComponent("text.pdf")
        let target = folder.appendingPathComponent("kept-text.pdf")
        try FixturePDF.write(to: source, scanned: false)
        let result = try PDFCompressor.compress(source, to: target, limitKB: 100, hasAdvancedAccess: true)
        XCTAssertTrue(result.fits)
        XCTAssertFalse(result.rasterized)
        let output = try XCTUnwrap(PDFDocument(url: target))
        XCTAssertEqual(output.pageCount, 3)
        for index in 0..<3 {
            XCTAssertTrue(output.page(at: index)?.string?.contains("Document sample") == true)
        }
    }

    func testTinyPDFBudgetReturnsUsableMeasuredBestEffort() throws {
        let source = folder.appendingPathComponent("oversize.pdf")
        let target = folder.appendingPathComponent("best.pdf")
        try FixturePDF.write(to: source, scanned: true)
        let result = try PDFCompressor.compress(source, to: target, limitKB: 1, hasAdvancedAccess: true)
        XCTAssertFalse(result.fits)
        XCTAssertTrue(result.rasterized)
        XCTAssertLessThan(result.outputBytes, result.inputBytes)
        XCTAssertEqual(try Data(contentsOf: target).count, result.outputBytes)
        XCTAssertEqual(PDFDocument(url: target)?.pageCount, 3)
    }

    func testFivePageLimitUsesExistingAccessFlag() throws {
        let source = folder.appendingPathComponent("six-pages.pdf")
        let target = folder.appendingPathComponent("result.pdf")
        try FixturePDF.write(to: source, scanned: false, pages: 6)
        XCTAssertThrowsError(try PDFCompressor.compress(source, to: target, limitKB: 100, hasAdvancedAccess: false)) {
            XCTAssertEqual($0 as? Issue, .pdfPageLimit)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try PDFCompressor.compress(source, to: target, limitKB: 100, hasAdvancedAccess: true).pageCount, 6)
    }
}
