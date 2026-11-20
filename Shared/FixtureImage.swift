import CoreGraphics
import Foundation
import ImageIO

enum FixtureImage {
    static func write(to url: URL, format: PhotoFormat, width: Int, height: Int,
                      noise: Bool = false, transparent: Bool = false, orientation: Int = 1) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Issue.writeFailed }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if noise, let buffer = context.data?.assumingMemoryBound(to: UInt8.self) {
            var seed: UInt32 = 77
            for row in 0..<height {
                for column in 0..<width {
                    seed = 1_664_525 &* seed &+ 1_013_904_223
                    let index = row * context.bytesPerRow + column * 4
                    buffer[index] = UInt8(truncatingIfNeeded: seed >> 24)
                    buffer[index + 1] = UInt8(truncatingIfNeeded: seed >> 16)
                    buffer[index + 2] = UInt8(truncatingIfNeeded: seed >> 8)
                    buffer[index + 3] = 255
                }
            }
        } else {
            if !transparent {
                context.setFillColor(red: 0.85, green: 0.89, blue: 0.96, alpha: 1)
                context.fill(bounds)
            }
            context.setFillColor(red: 0.14, green: 0.28, blue: 0.75, alpha: 1)
            context.fill(bounds.insetBy(dx: Double(width) / 4, dy: Double(height) / 4))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw Issue.writeFailed
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        if format != .png {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Issue.writeFailed }
    }
}
