import XCTest

final class StorageTests: XCTestCase {
    func testBatchSerialResultsAndPersistentExportUseVerifiedFiles() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let support = folder.appendingPathComponent("support", isDirectory: true)
        let temporary = folder.appendingPathComponent("temp", isDirectory: true)
        let store = PhotoStore(root: support, temp: temporary)
        _ = try await store.open(reset: false)
        let png = folder.appendingPathComponent("input.png")
        try FixtureImage.write(to: png, format: .png, width: 150, height: 100)
        let info = try Compressor.inspect(png)
        let inputs = [
            PhotoInput(name: "Same.png", url: png, info: info, issue: nil),
            PhotoInput(name: "Bad.png", url: nil, info: nil, issue: .unreadable),
            PhotoInput(name: "Same.png", url: png, info: info, issue: nil)
        ]

        let all = try await store.process([inputs[0], inputs[2]], limit: 200, id: UUID())
        XCTAssertEqual(all.results.count, 2)
        XCTAssertTrue(all.failures.isEmpty)
        try await store.commit(all)

        let partial = try await store.process(inputs, limit: 200, id: UUID())
        XCTAssertEqual(partial.results.map(\.id), [inputs[0].id, inputs[2].id])
        XCTAssertEqual(partial.failures.map(\.issue), [.unreadable])
        XCTAssertEqual(Set(partial.results.map(\.filename)).count, 2)
        try await store.commit(partial)
        let urls = try await store.prepareExport(group: partial, results: partial.results, stage: UUID())
        for (url, result) in zip(urls, partial.results) {
            XCTAssertEqual(url.pathExtension, "jpg")
            XCTAssertEqual(try Data(contentsOf: url).count, result.outputBytes)
            XCTAssertTrue(Limit.fits(result.outputBytes, kb: 200))
        }

        let failed = try await store.process([inputs[1], inputs[1]], limit: 200, id: UUID())
        XCTAssertEqual(failed.failures.count, 2)
        XCTAssertTrue(failed.results.isEmpty)
        try await store.commit(failed)
        let savedRule = CompressionRule(name: "Application", limitKB: 320)
        try await store.save(rules: [savedRule])
        let reopened = PhotoStore(root: support, temp: temporary)
        let (latest, rules, _) = try await reopened.open(reset: false)
        XCTAssertEqual(latest?.id, partial.id)
        XCTAssertEqual(rules, [savedRule])
    }

    func testCancellationCannotReplaceLatestIndexAndWriteFailuresThrow() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let support = folder.appendingPathComponent("support", isDirectory: true)
        let temporary = folder.appendingPathComponent("temp", isDirectory: true)
        let store = PhotoStore(root: support, temp: temporary)
        _ = try await store.open(reset: false)
        let file = folder.appendingPathComponent("picture.jpg")
        try FixtureImage.write(to: file, format: .jpeg, width: 150, height: 100)
        let input = PhotoInput(name: "Photo", url: file, info: try Compressor.inspect(file), issue: nil)
        let group = try await store.process([input], limit: 200, id: UUID())
        try await store.commit(group)
        let pending = try await store.process([input], limit: 100, id: UUID())
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.commit(pending)
        }

        do {
            try await cancelled.value
            XCTFail("Cancelled results became the latest index")
        } catch is CancellationError {}
        await store.discard(pending.id)
        let (restored, _, _) = try await store.open(reset: false)
        XCTAssertEqual(restored?.id, group.id)

        let results = support.appendingPathComponent("Results")
        try FileManager.default.removeItem(at: results)
        try Data("unwritable results directory".utf8).write(to: results)
        do {
            _ = try await store.process([input], limit: 200, id: UUID())
            XCTFail("Disk failure produced results")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: results.path))
        }
    }
}
