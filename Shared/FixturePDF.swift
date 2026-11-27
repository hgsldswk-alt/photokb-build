import UIKit

enum FixturePDF {
    static func write(to url: URL, scanned: Bool, pages: Int = 3) throws {
        var texture: UIImage?
        if scanned {
            let imageURL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: imageURL) }
            try FixtureImage.write(to: imageURL, format: .png, width: 900, height: 600, noise: true)
            texture = UIImage(data: try Data(contentsOf: imageURL))
            guard texture != nil else { throw Issue.writeFailed }
        }
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 480)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            for index in 0..<pages {
                let page = CGRect(x: 0, y: 0, width: bounds.width + CGFloat(index * 12), height: bounds.height)
                context.beginPage(withBounds: page, pageInfo: [:])
                UIColor.white.setFill()
                context.cgContext.fill(page)
                if !scanned {
                    ("Document sample · \(index + 1)" as NSString)
                        .draw(at: CGPoint(x: 32, y: 32), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
                }
                texture?.draw(in: CGRect(x: 32, y: 80, width: 120, height: 80))
                UIColor(white: 0.82, alpha: 1).setFill()
                for row in 0..<18 {
                    context.cgContext.fill(CGRect(x: 32, y: 195 + row * 12, width: 220 - row % 5 * 11, height: 2))
                }
            }
        }
    }
}
