import XCTest

final class FlowUITests: XCTestCase {
    enum Language: String {
        case en, simplified = "zh-Hans", traditional = "zh-Hant", ja

        var locale: String {
            switch self {
            case .en: return "en_US"
            case .simplified: return "zh_CN"
            case .traditional: return "zh_TW"
            case .ja: return "ja_JP"
            }
        }
    }

    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 900
    }

    private func launch(_ arguments: [String] = [], language: Language = .simplified, reset: Bool = true,
                        environment: [String: String] = [:]) {
        app.terminate()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language.rawValue))", "-AppleLocale", language.locale]
            + (reset ? ["-reset"] : []) + arguments
        app.launchEnvironment = environment
        app.launch()
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons.matching(identifier: id).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), id, file: file, line: line)
        for _ in 0..<6 {
            if button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.isHittable, id, file: file, line: line)
        button.tap()
    }

    private func text(_ id: String, timeout: TimeInterval = 12) -> XCUIElement {
        let element = app.staticTexts.matching(identifier: id).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), id)
        return element
    }

    private func expectNotice(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let notice = app.staticTexts.matching(identifier: "status.notice")
            .matching(NSPredicate(format: "label == %@", message)).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 12), "status.notice: \(message)", file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(data: app.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func selected(_ button: String = "home.pickPhotos") {
        tap(button)
        XCTAssertTrue(app.otherElements["home.selection"].waitForExistence(timeout: 30))  // 11-26 #15 云端慢：15 秒没等到
    }

    private func compress() {
        tap("home.compress")
        _ = text("result.pass")
    }

    func testFreeUsesThenOneTimeUnlockSheet() {
        launch(["-fixture", "sample", "-free-used", "0"])
        XCTAssertTrue(app.buttons["home.pickPhotos"].waitForExistence(timeout: 12))
        selected()
        _ = text("unlock.left")
        compress()
        launch(["-fixture", "sample", "-free-used", "1"])
        XCTAssertTrue(app.buttons["home.pickPhotos"].waitForExistence(timeout: 12))
        selected()
        tap("home.compress")
        _ = text("unlock.title")
        XCTAssertTrue(app.buttons["unlock.buy"].exists)
        XCTAssertTrue(app.buttons["unlock.restore"].exists)
        capture("paid-01-paywall")
        tap("unlock.close")
        XCTAssertFalse(app.staticTexts["unlock.title"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["result.pass"].exists)
    }

    func testSinglePhotoSaveShareAndRememberLimit() {
        launch(["-fixture", "sample"])
        XCTAssertTrue(app.buttons["home.pickPhotos"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        tap("limit.100")
        selected()
        compress()
        XCTAssertTrue(text("result.pass").label.contains("100"))
        _ = text("result.bytes")
        tap("result.share")
        _ = text("share.requested")
        tap("result.save")
        XCTAssertTrue(text("status.notice").label.contains("已存到照片"))
        launch(reset: false)
        XCTAssertEqual(app.textFields["home.limit"].value as? String, "100")
    }

    func testInvalidLimitAndCancelThenChangeLimit() {
        launch(["-fixture", "sample", "-hold-compression-at", "200"])
        selected()
        let field = app.textFields["home.limit"]
        XCTAssertEqual(field.value as? String, "200")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + "0")
        XCTAssertEqual(field.value as? String, "0")
        tap("home.compress")
        expectNotice("请输入 1 到 10,000 之间的整数 KB。")
        XCTAssertFalse(app.buttons["home.cancel"].exists)
        tap("limit.200")
        tap("home.compress")
        tap("home.cancel")
        expectNotice("已取消，可继续操作。")
        XCTAssertFalse(app.staticTexts["result.pass"].exists)
        selected()
        tap("home.compress")
        XCTAssertTrue(app.buttons["home.cancel"].waitForExistence(timeout: 12))
        tap("limit.500")
        XCTAssertEqual(field.value as? String, "500")
        compress()
        XCTAssertTrue(text("result.pass").label.contains("500"))
    }

    func testBatchPartialFailureSharesOnlyPreparedFiles() {
        launch(["-fixture", "batch"])
        selected("home.pickBatch")
        compress()
        let summary = text("batch.summary").label
        XCTAssertTrue(summary.contains("2 张达标"))
        XCTAssertTrue(summary.contains("1 张失败"))
        tap("result.share")
        _ = text("share.requested")
    }

    func testPDFEntryCompressesAtCurrentLimitAndShares() {
        launch(["-seedPDF"])
        tap("limit.100")
        openSeededPDF()
        XCTAssertTrue(text("pdf.pass").label.contains("100"))
        XCTAssertTrue(app.buttons["pdf.save"].exists)
        tap("pdf.share")
        _ = text("share.requested")
        tap("pdf.newTask")
        XCTAssertEqual(app.textFields["home.limit"].value as? String, "100")
    }

    private func openSeededPDF() {
        tap("home.pickPDF")
        _ = text("pdf.pass", timeout: 45)
        let comparison = app.descendants(matching: .any).matching(identifier: "pdf.comparison").firstMatch
        XCTAssertTrue(comparison.waitForExistence(timeout: 12))
        XCTAssertTrue(comparison.label.contains("→"))
        let pages = app.descendants(matching: .any).matching(identifier: "pdf.pages").firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 12))
        XCTAssertTrue(pages.label.contains("3"))
    }

    func testPasteCodeAndImportRuleFile() {
        launch(["-fixture-rule"], environment: ["PHOTOKB_RULE_PASTE": "\nKBPHOTO1:500\n"])
        tap("home.settings")
        tap("settings.paste")
        XCTAssertTrue(text("rule.previewValue").label.contains("500"))
        tap("rule.apply")
        XCTAssertEqual(app.textFields["home.limit"].value as? String, "500")
        tap("home.settings")
        tap("settings.importFixture")
        XCTAssertTrue(text("rule.previewValue").label.contains("320"))
        tap("rule.apply")
        XCTAssertEqual(app.textFields["home.limit"].value as? String, "320")
    }

    func testSavedRulesAndResultsPersistAcrossLaunches() {
        launch(["-fixture", "simple"])
        selected()
        compress()
        tap("result.newTask")
        tap("home.settings")
        tap("settings.newRule")
        let name = app.textFields["rule.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Form")
        tap("rule.save")
        XCTAssertTrue(app.buttons["rule.apply.Form"].waitForExistence(timeout: 8))
        tap("rule.edit.Form")
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "Permit")
        tap("rule.save")
        XCTAssertTrue(app.buttons["rule.apply.Permit"].waitForExistence(timeout: 8))

        launch(["-fixture", "simple"], reset: false)
        tap("home.settings")
        tap("rule.apply.Permit")
        tap("home.settings")
        tap("settings.last")
        tap("result.share")
        _ = text("share.requested")
        tap("result.newTask")
        selected()
        compress()
        tap("result.save")
        _ = text("status.notice")
    }

    func testStoreScreenshotsEnglish() { storeScreenshots(language: .en) }
    func testStoreScreenshotsSimplified() { storeScreenshots(language: .simplified) }
    func testStoreScreenshotsTraditional() { storeScreenshots(language: .traditional) }
    func testStoreScreenshotsJapanese() { storeScreenshots(language: .ja) }

    private func storeScreenshots(language: Language) {
        let prefix = "store-\(language.rawValue)"
        launch(["-fixture", "sample"], language: language)
        XCTAssertTrue(app.buttons["home.pickPhotos"].waitForExistence(timeout: 12))
        let expectedPhotoLabel: String
        switch language {
        case .en: expectedPhotoLabel = "Choose photo"
        case .simplified: expectedPhotoLabel = "选照片"
        case .traditional: expectedPhotoLabel = "選擇照片"
        case .ja: expectedPhotoLabel = "写真を選択"
        }
        XCTAssertEqual(app.buttons["home.pickPhotos"].label, expectedPhotoLabel)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(app.textFields["home.limit"].value as? String, "200")
        capture(prefix + "-01-home")
        selected()
        compress()
        _ = text("result.bytes")
        capture(prefix + "-02-result")

        launch(["-fixture", "heic"], language: language)
        selected()
        compress()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "HEIC")).firstMatch.exists)
        capture(prefix + "-03-copy")

        launch(["-fixture", "batch"], language: language)
        selected("home.pickBatch")
        compress()
        _ = text("batch.summary")
        capture(prefix + "-04-batch")

        tap("result.shareRule")
        XCTAssertTrue(app.otherElements["card.preview"].waitForExistence(timeout: 10))
        let loadingQR = app.descendants(matching: .any)["card.qrLoading"]
        if loadingQR.exists || app.buttons["card.share"].isEnabled {
            let qr = app.images.matching(NSPredicate(format: "label CONTAINS %@", "App Store")).firstMatch
            XCTAssertTrue(qr.waitForExistence(timeout: 20))
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["card.qrPlaceholder"].exists)
        }
        capture(prefix + "-05-rule-card")
        if app.buttons["card.share"].isEnabled {
            tap("card.share")
            _ = text("share.requested")
        }
        tap("card.file")
        _ = text("share.requested")

        launch(["-seedPDF"], language: language)
        tap("limit.100")
        openSeededPDF()
        capture(prefix + "-06-pdf-result")
    }
}
