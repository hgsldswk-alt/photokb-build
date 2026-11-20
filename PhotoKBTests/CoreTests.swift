import CoreImage
import XCTest

final class CoreTests: XCTestCase {
    func testLimitUsesDecimalByteBoundaryAndLocalizedDigits() {
        XCTAssertTrue(Limit.fits(199_999, kb: 200))
        XCTAssertTrue(Limit.fits(200_000, kb: 200))
        XCTAssertFalse(Limit.fits(200_001, kb: 200))
        for invalid in ["", "0", "-1", "0.5", "199.0", "١٫٥", "+5", "10,001", "10001", "1 00", "²", "①"] {
            XCTAssertNil(Limit.parse(invalid), invalid)
        }
        XCTAssertEqual(Limit.parse("２００"), 200)
        XCTAssertEqual(Limit.parse("٢٣٥"), 235)
        XCTAssertEqual(Limit.parse(" 10000 "), 10_000)
        XCTAssertEqual(Limit.parse("10,000", locale: Locale(identifier: "en_US")), 10_000)
        XCTAssertNil(Limit.parse("1,00", locale: Locale(identifier: "en_US")))
        XCTAssertEqual(Limit.presets, [100, 200, 500])
    }

    func testRuleRoundTripAndInvalidInputs() throws {
        let rule = RulePayload(limitKB: 200)
        XCTAssertEqual(rule.code, "KBPHOTO1:200")
        XCTAssertEqual(try RulePayload.from(code: "\n\(rule.code)\n"), rule)
        XCTAssertEqual(try RulePayload.from(data: rule.data()), rule)
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: rule.data()) as? [String: Any]).keys),
                       ["version", "limitKB"])
        for invalid in ["KBPHOTO2:200", "KBPHOTO1:-1", "KBPHOTO1:10001", "KBPHOTO1:+20",
                        "KBPHOTO1:1e2", String(repeating: "x", count: 1025)] {
            XCTAssertThrowsError(try RulePayload.from(code: invalid))
        }
        for json in [#"{"version":2,"limitKB":200}"#, #"{"version":1,"limitKB":1.1}"#,
                     #"{"version":1,"limitKB":0}"#, String(repeating: " ", count: 1025)] {
            XCTAssertThrowsError(try RulePayload.from(data: Data(json.utf8)))
        }
    }

    func testQRDecodesAppStoreLinkAndNoQRWithoutID() throws {
        XCTAssertNil(DownloadQR.url(appStoreID: ""))
        XCTAssertNil(DownloadQR.url(appStoreID: "id000"))
        let url = try XCTUnwrap(DownloadQR.url(appStoreID: "1234567890"))
        let image = try XCTUnwrap(DownloadQR.image(for: url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                 options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image))
        XCTAssertEqual(features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }, [url.absoluteString])
    }

    func testLocalizationComesFromTheCompiledTestBundle() {
        XCTAssertNotEqual(L.t("home.title"), "home.title")
        XCTAssertTrue(L.f("result.pass", "200").contains("200"))
    }

    func testEntitlementFirstLaunchExpiryMigrationAndVerifiedRestoration() throws {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = first.addingTimeInterval(30 * 86_400)
        var trial = Entitlement(firstOpen: first)
        trial.startPaidPeriod(at: first, free: true)
        XCTAssertNil(trial.proStartedAt)
        XCTAssertTrue(trial.hasPro(at: expiry, free: true))
        trial.startPaidPeriod(at: first, free: false)
        XCTAssertEqual(trial.trialStart, first)
        XCTAssertTrue(trial.hasPro(at: expiry.addingTimeInterval(-1), free: false))
        XCTAssertFalse(trial.hasPro(at: expiry, free: false))
        XCTAssertFalse(trial.hasPro(at: first.addingTimeInterval(-601), free: false))

        var upgrade = Entitlement(firstOpen: first)
        let launchPaid = expiry.addingTimeInterval(100)
        upgrade.startPaidPeriod(at: launchPaid, free: false)
        upgrade.startPaidPeriod(at: launchPaid.addingTimeInterval(500), free: false)
        XCTAssertEqual(upgrade.trialStart, launchPaid)
        upgrade.applyTrial(originalPurchaseDate: launchPaid.addingTimeInterval(1000))
        XCTAssertEqual(upgrade.trialStart, launchPaid)
        upgrade.applyTrial(originalPurchaseDate: first)
        XCTAssertEqual(upgrade.trialStart, first)
        XCTAssertFalse(upgrade.hasPro(at: launchPaid, free: false))
        upgrade.purchasedPro = true
        let restored = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(upgrade))
        XCTAssertTrue(restored.hasPro(at: launchPaid, free: false))
        XCTAssertFalse(Launch.isFree(arguments: ["-paywall"]))
    }

    func testExportDeduplicationMilestoneAndReviewThrottle() {
        let version = "1.0"
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 86_400
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var history = ExportHistory()

        func record(_ group: UUID, _ ids: [UUID], on dayOffset: Int, version: String = "1.0") -> Bool {
            history.record(group: group, ids: ids, now: start.addingTimeInterval(Double(dayOffset) * day),
                           version: version, calendar: calendar)
        }

        let a = UUID(), b = UUID(), c = UUID()
        let first = [UUID(), UUID()]
        XCTAssertFalse(record(a, first, on: 0))
        XCTAssertFalse(record(a, first, on: 1))
        XCTAssertEqual(history.count, 2)
        XCTAssertFalse(record(b, [UUID()], on: 1))
        XCTAssertFalse(record(c, [UUID(), UUID()], on: 2))
        XCTAssertEqual(history.count, 5)
        XCTAssertTrue(record(c, [UUID()], on: 2))
        history.markRated(now: start.addingTimeInterval(2 * day), version: version)
        XCTAssertFalse(record(c, [UUID(), UUID(), UUID(), UUID()], on: 2))
        XCTAssertEqual(history.count, 10)
        XCTAssertFalse(record(UUID(), [UUID()], on: 150))
        XCTAssertFalse(record(UUID(), [UUID()], on: 40, version: "1.1"))
        XCTAssertTrue(record(UUID(), [UUID()], on: 92, version: "1.1"))
    }
}
