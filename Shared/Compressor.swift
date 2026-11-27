import CoreGraphics
import Foundation
import ImageIO

struct CompressedJPEG {
    let data: Data
    let width: Int
    let height: Int
    let quality: Double
}

enum Compressor {
    private enum ImageLayout { case exact, fit, fill }
    static let minimumQuality = 0.45
    static let pixelBudget = 12_000_000
    static let sideBudget = 4_096
    static let inputByteBudget = 160_000_000
    private static let inputPixelBudget = 100_000_000
    private static let inputSideBudget = 32_768
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func inspect(_ url: URL) throws -> ImageInfo {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else { throw Issue.unreadable }
        guard bytes <= inputByteBudget else { throw Issue.tooLarge }
        let source = try read(url)
        guard let identifier = CGImageSourceGetType(source),
              let format = PhotoFormat.allCases.first(where: { $0.type.identifier == (identifier as String) }) else {
            throw Issue.unsupported
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else {
            throw Issue.unreadable
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard max(width, height) <= inputSideBudget, height <= inputPixelBudget / width else { throw Issue.tooLarge }
        let rotated = (5...8).contains(orientation)
        return ImageInfo(format: format, bytes: bytes, width: rotated ? height : width,
                         height: rotated ? width : height)
    }

    static func boundedSide(width: Int, height: Int) -> Int {
        let longest = max(width, height)
        let pixelsPerRow = Double(min(width, height)) / Double(longest)
        let bounded = min(Double(longest), Double(sideBudget), sqrt(Double(pixelBudget) / pixelsPerRow))
        return max(1, Int(bounded.rounded(.down)))
    }

    static func compress(_ url: URL, info: ImageInfo, limitKB: Int) throws -> CompressedJPEG {
        guard Limit.range.contains(limitKB) else { throw Issue.invalidLimit }
        try Task.checkCancellation()
        let originalSide = max(info.width, info.height)
        let minimumSide = min(originalSide, 320)
        var side = boundedSide(width: info.width, height: info.height)
        let decoded = try decode(url, side: side)
        guard max(decoded.width, decoded.height) >= minimumSide else { throw Issue.unreadable }

        for _ in 0..<12 {
            try Task.checkCancellation()
            let candidate = try autoreleasepool {
                let scale = min(1, Double(side) / Double(max(decoded.width, decoded.height)))
                let width = max(1, Int((Double(decoded.width) * scale).rounded()))
                let height = max(1, Int((Double(decoded.height) * scale).rounded()))
                let image = try whiteImage(decoded, width: width, height: height, layout: .exact)
                return try bestJPEG(image, limitKB: limitKB)
            }
            if let candidate { return candidate }
            guard side > minimumSide else { break }
            side = max(minimumSide, Int(Double(side) * 0.73))
        }
        throw Issue.impossible
    }

    static func resize(_ url: URL, info: ImageInfo, dimensions: ImageResize, limitKB: Int?) throws -> CompressedJPEG {
        try Task.checkCancellation()
        let decoded = try decode(url, side: boundedSide(width: info.width, height: info.height))
        let scale = Double(max(dimensions.width, dimensions.height)) / Double(max(info.width, info.height))
        let width = dimensions.lockRatio ? max(1, Int((Double(info.width) * scale).rounded())) : dimensions.width
        let height = dimensions.lockRatio ? max(1, Int((Double(info.height) * scale).rounded())) : dimensions.height
        guard width * height <= pixelBudget else { throw Issue.invalidPixels }
        let image = try whiteImage(decoded, width: width, height: height, layout: dimensions.lockRatio ? .fit : .fill)
        guard let limitKB else { return try encodeJPEG(image, quality: 0.95) }
        guard Limit.range.contains(limitKB) else { throw Issue.invalidLimit }
        guard let candidate = try bestJPEG(image, limitKB: limitKB, qualityFloor: 0.16) else { throw Issue.pixelLimit }
        return candidate
    }

    private static func decode(_ url: URL, side: Int) throws -> CGImage {
        let source = try read(url)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true
        ] as [CFString: Any]
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw Issue.unreadable
        }
        return decoded
    }

    private static func read(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw Issue.unsupported }
        return source
    }

    static func whiteContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Issue.tooLarge }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private static func whiteImage(_ image: CGImage, width: Int, height: Int, layout: ImageLayout) throws -> CGImage {
        let context = try whiteContext(width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        if layout != .exact {
            let xScale = bounds.width / CGFloat(image.width)
            let yScale = bounds.height / CGFloat(image.height)
            let scale = layout == .fill ? max(xScale, yScale) : min(xScale, yScale)
            let drawnWidth = CGFloat(image.width) * scale
            let drawnHeight = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(x: (bounds.width - drawnWidth) / 2, y: (bounds.height - drawnHeight) / 2,
                                           width: drawnWidth, height: drawnHeight))
        } else {
            context.draw(image, in: bounds)
        }
        guard let output = context.makeImage() else { throw Issue.unreadable }
        return output
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) throws -> CompressedJPEG {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, PhotoFormat.jpeg.type.identifier as CFString, 1, nil)
        else { throw Issue.writeFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Issue.writeFailed }
        return CompressedJPEG(data: data as Data, width: image.width, height: image.height, quality: quality)
    }

    private static func bestJPEG(_ image: CGImage, limitKB: Int,
                                 qualityFloor: Double = minimumQuality) throws -> CompressedJPEG? {
        func encode(_ quality: Double) throws -> CompressedJPEG { try encodeJPEG(image, quality: quality) }

        func fits(_ jpeg: CompressedJPEG) -> Bool { Limit.fits(jpeg.data.count, kb: limitKB) }

        let full = try encode(0.95)
        if fits(full) { return full }

        let floor = try encode(qualityFloor)
        var best: CompressedJPEG? = fits(floor) ? floor : nil
        let probes = [0.82, 0.69, 0.57, 0.45, 0.30, 0.22].filter { $0 > qualityFloor }
        var high = full.quality
        for quality in probes {
            let candidate = try encode(quality)
            if fits(candidate) {
                best = candidate
                break
            }
            high = quality
        }
        guard var validated = best else { return nil }
        for _ in 0..<4 {
            let candidate = try encode((validated.quality + high) / 2)
            if fits(candidate) {
                validated = candidate
            } else {
                high = candidate.quality
            }
        }
        return validated
    }
}
