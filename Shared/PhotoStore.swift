import Foundation

actor PhotoStore {
    private let root: URL
    private let temp: URL
    private let files = FileManager.default
    private var latest: ResultGroup?

    init(root: URL, temp: URL) {
        self.root = root
        self.temp = temp
    }

    func open(reset: Bool) throws -> (ResultGroup?, [CompressionRule], Preferences) {
        if reset { try? files.removeItem(at: root) }
        try? files.removeItem(at: temp)
        try files.createDirectory(at: temp, withIntermediateDirectories: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var resultsRoot = root.appendingPathComponent("Results", isDirectory: true)
        try files.createDirectory(at: resultsRoot, withIntermediateDirectories: true)
        var options = URLResourceValues()
        options.isExcludedFromBackup = true
        try resultsRoot.setResourceValues(options)
        let group = read(ResultGroup.self, from: resultsRoot.appendingPathComponent("Latest.json"))
        latest = group.flatMap { candidate in
            candidate.results.isEmpty || candidate.results.contains(where: {
                !candidate.accepts($0.outputBytes) ||
                (try? url(for: $0, in: candidate).resourceValues(forKeys: [.fileSizeKey]).fileSize) != $0.outputBytes
            }) ? nil : candidate
        }
        cleanResults(keeping: latest?.id)
        let book = read(RuleBook.self, from: root.appendingPathComponent("Rules.json"))
        let rules = book?.version == 1 ? (book?.rules ?? []).filter { Limit.range.contains($0.limitKB) } : []
        var fallback = Preferences()
        fallback.lastLimit = latest?.limitKB ?? Limit.initial
        return (latest, rules, read(Preferences.self, from: root.appendingPathComponent("Preferences.json")) ?? fallback)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save(rules: [CompressionRule]) throws {
        try JSONEncoder().encode(RuleBook(rules: rules)).write(to: root.appendingPathComponent("Rules.json"), options: .atomic)
    }

    func save(preferences: Preferences) throws {
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("Preferences.json"), options: .atomic)
    }

    func staging(id: UUID) throws -> URL {
        let folder = temp.appendingPathComponent(id.uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func removeStaging(id: UUID) {
        try? files.removeItem(at: temp.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    static func stage(_ url: URL, in folder: URL, name: String? = nil) throws -> PhotoInput {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let info = try Compressor.inspect(url)
        let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(info.format.type.preferredFilenameExtension ?? "img")
        try FileManager.default.copyItem(at: url, to: target)
        return PhotoInput(name: name ?? url.lastPathComponent, url: target, info: info, issue: nil)
    }

    func process(_ inputs: [PhotoInput], limit: Int, id: UUID,
                 resize: ImageResize? = nil, applyLimit: Bool = true) throws -> ResultGroup {
        try Task.checkCancellation()
        let work = directory(for: id)
        var group = ResultGroup(id: id, limitKB: limit, date: Date())
        if !applyLimit { group.withoutLimit = true }
        do {
            try files.createDirectory(at: work, withIntermediateDirectories: true)
            for (position, input) in inputs.enumerated() {
                try Task.checkCancellation()
                do {
                    let result = try autoreleasepool {
                        try compress(input, position: position, group: group, resize: resize)
                    }
                    group.results.append(result)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let issue as Issue {
                    group.failures.append(.init(name: input.name, issue: issue))
                } catch {
                    group.failures.append(.init(name: input.name, issue: .writeFailed))
                }
            }
            try Task.checkCancellation()
            if group.results.isEmpty { try? files.removeItem(at: work) }
            return group
        } catch {
            try? files.removeItem(at: work)
            throw error
        }
    }

    func reopenInput(_ item: CompressionResult, in group: ResultGroup) throws -> PhotoInput {
        let source = url(for: item, in: group)
        return PhotoInput(name: item.name, url: source, info: try Compressor.inspect(source), issue: nil)
    }

    func processPDF(_ source: URL, limit: Int, id: UUID, hasAdvancedAccess: Bool) throws -> PDFCompression {
        let folder = try staging(id: id)
        let name = safeStem(source.lastPathComponent)
        let output = folder.appendingPathComponent("PDF-\(name).pdf")
        let result = try PDFCompressor.compress(source, to: output, limitKB: limit, hasAdvancedAccess: hasAdvancedAccess)
        try Task.checkCancellation()
        guard try output.resourceValues(forKeys: [.fileSizeKey]).fileSize == result.outputBytes else {
            throw Issue.writeFailed
        }
        return result
    }

    func seedPDF(id: UUID) throws -> URL {
        let file = try staging(id: id).appendingPathComponent("Sample.pdf")
        try FixturePDF.write(to: file, scanned: true)
        return file
    }

    func commit(_ group: ResultGroup) throws {
        try Task.checkCancellation()
        guard !group.results.isEmpty else { return }
        let index = root.appendingPathComponent("Results/Latest.json")
        try JSONEncoder().encode(group).write(to: index, options: .atomic)
        latest = group
        cleanResults(keeping: group.id)
    }

    func discard(_ group: UUID) {
        guard group != latest?.id else { return }
        try? files.removeItem(at: directory(for: group))
    }

    func writeShare(_ data: Data, filename: String, id: UUID) throws -> URL {
        let file = try staging(id: id).appendingPathComponent(filename)
        try data.write(to: file, options: .atomic)
        return file
    }

    func prepareExport(group: ResultGroup, results: [CompressionResult], stage: UUID) throws -> [URL] {
        let folder = try staging(id: stage)
        return try results.map { item in
            let source = url(for: item, in: group)
            let destination = folder.appendingPathComponent(item.filename)
            try files.copyItem(at: source, to: destination)
            guard try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize == item.outputBytes,
                  group.accepts(item.outputBytes) else { throw Issue.writeFailed }
            return destination
        }
    }

    private func compress(_ input: PhotoInput, position: Int, group: ResultGroup, resize: ImageResize?) throws -> CompressionResult {
        guard let source = input.url, let info = input.info else { throw input.issue ?? .unreadable }
        let jpeg: CompressedJPEG
        if let resize {
            jpeg = try Compressor.resize(source, info: info, dimensions: resize, limitKB: group.hasLimit ? group.limitKB : nil)
        } else {
            jpeg = try Compressor.compress(source, info: info, limitKB: group.limitKB)
        }
        try Task.checkCancellation()
        let filename = "JPEG-\(position + 1)-\(safeStem(input.name)).jpg"
        let output = directory(for: group.id).appendingPathComponent(filename)
        try jpeg.data.write(to: output, options: .atomic)
        guard let written = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              written == jpeg.data.count, group.accepts(written) else {
            try? files.removeItem(at: output)
            throw Issue.writeFailed
        }
        return CompressionResult(id: input.id, name: input.name, filename: filename, input: info,
                                 outputBytes: written, width: jpeg.width, height: jpeg.height)
    }

    private func safeStem(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let safe = stem.replacingOccurrences(of: "[^\\p{L}\\p{N} _-]+", with: "-", options: .regularExpression)
        return String(safe.prefix(40))
    }

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent("Results", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func url(for result: CompressionResult, in group: ResultGroup) -> URL {
        directory(for: group.id).appendingPathComponent(result.filename)
    }

    private func cleanResults(keeping id: UUID?) {
        let folder = root.appendingPathComponent("Results", isDirectory: true)
        let contents = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in contents where UUID(uuidString: item.lastPathComponent) != nil && item.lastPathComponent != id?.uuidString {
            try? files.removeItem(at: item)
        }
    }
}
