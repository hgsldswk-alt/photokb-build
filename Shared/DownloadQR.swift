import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum DownloadQR {
    static func url(appStoreID: String) -> URL? {
        guard !appStoreID.isEmpty, appStoreID.first != "0",
              appStoreID.utf8.count <= 20,
              appStoreID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id" + appStoreID)
    }

    static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let result = filter.outputImage else { return nil }
        let scaled = result.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let extent = scaled.extent.insetBy(dx: -32, dy: -32)
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        return CIContext().createCGImage(scaled.composited(over: background), from: extent)
    }
}
