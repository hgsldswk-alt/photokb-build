import CryptoKit
import ImageIO
import XCTest

final class ImageTests: XCTestCase {
    func testExactPixelsWithOptionalLimitAndAspectFit() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("landscape.png")
        try FixtureImage.write(to: source, format: .png, width: 1_600, height: 1_200)
        let info = try Compressor.inspect(source)
        let square = try ImageResize(width: 600, height: 600, lockRatio: false)
        let resized = try Compressor.resize(source, info: info, dimensions: square, limitKB: 100)
        XCTAssertLessThanOrEqual(resized.data.count, 100_000)
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithData(resized.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(jpeg, 0, nil))
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 600)

        let aspectFit = try ImageResize(width: 600, height: 600, lockRatio: true)
        let fit = try Compressor.resize(source, info: info, dimensions: aspectFit, limitKB: nil)
        XCTAssertEqual(fit.width, 600)
        XCTAssertEqual(fit.height, 450)
        let widePreset = try ImageResize(width: 1_920, height: 1_080, lockRatio: true)
        let longSide = try Compressor.resize(source, info: info, dimensions: widePreset, limitKB: nil)
        XCTAssertEqual(longSide.width, 1_920)
        XCTAssertEqual(longSide.height, 1_440)
        XCTAssertThrowsError(try Compressor.resize(source, info: info, dimensions: square, limitKB: 1)) {
            XCTAssertEqual($0 as? Issue, .pixelLimit)
        }
    }

    func testJPEGKeepsOriginalAndStripsMetadata() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("photo.jpg")
        try FixtureImage.write(to: file, format: .jpeg, width: 160, height: 96, orientation: 6)
        let inputBytes = try Data(contentsOf: file)
        let info = try Compressor.inspect(file)
        XCTAssertEqual(info.format, .jpeg)
        XCTAssertEqual(info.width, 96)
        XCTAssertEqual(info.height, 160)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let before = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary])

        let output = try Compressor.compress(file, info: info, limitKB: 200)
        let repeated = try Compressor.compress(file, info: info, limitKB: 200)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: file)), SHA256.hash(data: inputBytes))
        XCTAssertEqual(SHA256.hash(data: repeated.data), SHA256.hash(data: output.data))
        XCTAssertEqual(output.width, 96)
        XCTAssertEqual(output.height, 160)
        let result = try XCTUnwrap(CGImageSourceCreateWithData(output.data as CFData, nil))
        let after = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
        XCTAssertNil(after[kCGImagePropertyGPSDictionary])
        XCTAssertNil(after[kCGImagePropertyIPTCDictionary])
        XCTAssertNil(after[kCGImagePropertyTIFFDictionary].flatMap { ($0 as? [CFString: Any])?[kCGImagePropertyTIFFModel] })
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif[kCGImagePropertyExifLensModel])
        let srgb = try XCTUnwrap(CGImageSourceCreateImageAtIndex(result, 0, nil)?.colorSpace?.name)
        XCTAssertEqual(srgb as String, CGColorSpace.sRGB as String)
    }

    func testPNGWhiteBackgroundAndHEICOrientation() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("transparent.png")
        try FixtureImage.write(to: png, format: .png, width: 120, height: 80, transparent: true)
        let jpeg = try Compressor.compress(png, info: Compressor.inspect(png), limitKB: 200)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let corner = try XCTUnwrap(image.cropping(to: CGRect(x: 2, y: 2, width: 1, height: 1)))
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(canvas.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertTrue((0..<3).allSatisfy { pixel[$0] > 248 })

        let heic = root.appendingPathComponent("portrait.heic")
        try FixtureImage.write(to: heic, format: .heic, width: 640, height: 480, orientation: 6)
        let info = try Compressor.inspect(heic)
        let rotated = try Compressor.compress(heic, info: info, limitKB: 100)
        XCTAssertEqual(info.format, .heic)
        XCTAssertEqual(rotated.width, 480)
        XCTAssertEqual(rotated.height, 640)
    }

    func testQualityBeforeResizingAndHardFloor() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("noise.png")
        try FixtureImage.write(to: png, format: .png, width: 640, height: 480, noise: true)
        let info = try Compressor.inspect(png)
        let full = try Compressor.compress(png, info: info, limitKB: 1_000)
        XCTAssertEqual(full.width, 640)
        XCTAssertGreaterThan(full.data.count, 30_000)
        let lower = try Compressor.compress(png, info: info, limitKB: (full.data.count - 1) / 1_000)
        XCTAssertEqual(lower.width, full.width)
        XCTAssertLessThan(lower.quality, full.quality)
        let resized = try Compressor.compress(png, info: info, limitKB: 30)
        XCTAssertLessThan(resized.width, 640)
        XCTAssertGreaterThanOrEqual(resized.width, 320)
        XCTAssertGreaterThanOrEqual(resized.quality, 0.45)
        XCTAssertLessThanOrEqual(resized.data.count, 30_000)
        XCTAssertThrowsError(try Compressor.compress(png, info: info, limitKB: 1)) {
            XCTAssertEqual($0 as? Issue, .impossible)
        }
    }

    func testDecodeBoundsLargeSquareAndPanorama() throws {
        XCTAssertEqual(Compressor.boundedSide(width: 50_000, height: 20_000), 4_096)
        XCTAssertEqual(Compressor.boundedSide(width: 10_000, height: 10_000), 3_464)
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("oversized.png")
        try FixtureImage.write(to: png, format: .png, width: 5_000, height: 2_500)
        let output = try Compressor.compress(png, info: Compressor.inspect(png), limitKB: 500)
        XCTAssertLessThanOrEqual(output.width, Compressor.sideBudget)
        XCTAssertLessThanOrEqual(output.width * output.height, Compressor.pixelBudget)
    }
}

func makeFolder() throws -> URL {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
