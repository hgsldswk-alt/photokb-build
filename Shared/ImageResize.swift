import Foundation

struct ImageResize: Equatable {
    static let presets = [(600, 600), (1080, 1080), (1920, 1080)]
    let width: Int
    let height: Int
    let lockRatio: Bool

    init(width: Int, height: Int, lockRatio: Bool) throws {
        guard (1...Compressor.sideBudget).contains(width), (1...Compressor.sideBudget).contains(height),
              lockRatio || width * height <= Compressor.pixelBudget else { throw Issue.invalidPixels }
        self.width = width
        self.height = height
        self.lockRatio = lockRatio
    }
}
