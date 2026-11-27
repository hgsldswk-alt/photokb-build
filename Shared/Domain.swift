import Foundation
import UniformTypeIdentifiers

enum Limit {
    static let range = 1...10_000
    static let presets = [100, 200, 500, 1_000]
    static let initial = 200

    static func parse(_ text: String, locale: Locale = .current) -> Int? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 8 else { return nil }
        let separator = locale.groupingSeparator ?? ","
        let groups = clean.components(separatedBy: separator)
        if groups.count > 1 {
            guard let first = groups.first, (1...3).contains(first.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let digits = groups.joined()
        guard digits.count <= 5 else { return nil }
        var value = 0
        for digit in digits {
            guard digit.unicodeScalars.count == 1,
                  digit.unicodeScalars.first?.properties.numericType == .decimal,
                  let number = digit.wholeNumberValue else { return nil }
            value = value * 10 + number
        }
        return range.contains(value) ? value : nil
    }

    static func fits(_ bytes: Int, kb: Int) -> Bool {
        range.contains(kb) && bytes > 0 && bytes <= kb * 1_000
    }
}

enum Issue: String, Error, Codable, Identifiable {
    case invalidLimit, unsupported, unreadable, cloud, tooLarge, impossible, writeFailed
    case saveFailed, permission, ruleInvalid, ruleName, unavailable
    case pdfUnreadable, pdfLocked, pdfPageLimit, invalidPixels, pixelLimit

    var id: String { rawValue }
    var message: String { L.t("issue." + rawValue) }
}

struct CompressionRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var limitKB: Int
}

struct RuleBook: Codable {
    private(set) var version = 1
    var rules: [CompressionRule]

    init(rules: [CompressionRule]) { self.rules = rules }
}

struct RulePayload: Codable, Equatable {
    static let type = UTType(exportedAs: "com.hgsldswk.photokb.rule")
    static let maxBytes = 1_024
    private static let prefix = "KBPHOTO1:"

    let version: Int
    let limitKB: Int

    init(limitKB: Int) {
        self.version = 1
        self.limitKB = limitKB
    }

    var code: String { Self.prefix + String(limitKB) }

    static func from(code: String) throws -> Self {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.utf8.count <= maxBytes, clean.hasPrefix(prefix) else { throw Issue.ruleInvalid }
        let digits = clean.dropFirst(prefix.count)
        guard let limit = Int(digits), String(limit) == digits,
              Limit.range.contains(limit) else { throw Issue.ruleInvalid }
        return Self(limitKB: limit)
    }

    static func from(data: Data) throws -> Self {
        guard data.count <= maxBytes,
              let rule = try? JSONDecoder().decode(Self.self, from: data),
              rule.version == 1, Limit.range.contains(rule.limitKB) else { throw Issue.ruleInvalid }
        return rule
    }

    static func read(_ url: URL) throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try Self.from(data: file.read(upToCount: maxBytes + 1) ?? Data())
    }

    func data() throws -> Data { try JSONEncoder().encode(self) }
}

enum PhotoFormat: String, Codable, CaseIterable {
    case jpeg = "JPEG", heic = "HEIC", png = "PNG"

    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .png: return .png
        }
    }
}

struct ImageInfo: Codable, Equatable {
    let format: PhotoFormat
    let bytes: Int
    let width: Int
    let height: Int
}

struct PhotoInput: Identifiable {
    let id = UUID()
    let name: String
    let url: URL?
    let info: ImageInfo?
    let issue: Issue?
}

struct CompressionResult: Codable, Identifiable {
    let id: UUID
    let name: String
    let filename: String
    let input: ImageInfo
    let outputBytes: Int
    let width: Int
    let height: Int
}

struct FailedPhoto: Codable, Identifiable {
    var id = UUID()
    let name: String
    let issue: Issue
}

struct ResultGroup: Codable, Identifiable {
    let id: UUID
    let limitKB: Int
    let date: Date
    var results: [CompressionResult] = []
    var failures: [FailedPhoto] = []
    var withoutLimit: Bool?
    var hasLimit: Bool { withoutLimit != true }
    func accepts(_ bytes: Int) -> Bool { bytes > 0 && (!hasLimit || Limit.fits(bytes, kb: limitKB)) }
    var isBatch: Bool { results.count + failures.count > 1 }
}

struct ExportHistory: Codable {
    private(set) var count = 0
    private(set) var days: Set<Date> = []
    private(set) var group: UUID?
    private(set) var seen: Set<UUID> = []
    private(set) var ratedVersion: String?
    private(set) var ratedAt: Date?
    var milestoneDismissed = false

    mutating func record(group: UUID, ids: [UUID], now: Date, version: String,
                         calendar: Calendar = .current) -> Bool {
        let wasEligible = count >= 5 && days.count >= 3
        if group != self.group {
            self.group = group
            seen.removeAll()
        }
        let newIDs = Set(ids).subtracting(seen)
        guard !newIDs.isEmpty else { return false }
        seen.formUnion(newIDs)
        count += newIDs.count
        if days.count < 3 { days.insert(calendar.startOfDay(for: now)) }
        return wasEligible && ratedVersion != version &&
            (ratedAt.map { now.timeIntervalSince($0) >= 90 * 86_400 } ?? true)
    }

    mutating func markRated(now: Date, version: String) {
        ratedAt = now
        ratedVersion = version
    }
}

struct Preferences: Codable {
    var coreReviewProgress: CoreReviewProgress?
    var lastLimit = Limit.initial
    var exports = ExportHistory()
}
