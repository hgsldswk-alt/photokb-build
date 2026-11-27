import PhotosUI
import SwiftUI

enum Panel: String, Identifiable {
    case settings, ruleShare, milestone, paste, rulePreview, editRule
    var id: String { rawValue }
}

enum PickerKind { case files, rule }

@MainActor
final class PhotoModel: ObservableObject {
    @Published var panel: Panel?
    @Published private(set) var limitText = String(Limit.initial)
    @Published private(set) var inputs: [PhotoInput] = []
    @Published private(set) var results: ResultGroup?
    @Published private(set) var pdfResult: PDFCompression?
    @Published private(set) var processingPDF = false
    @Published private(set) var latest: ResultGroup?
    @Published private(set) var rules: [CompressionRule] = []
    @Published private(set) var preferences = Preferences()
    @Published private(set) var status: String?
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var compressing = false
    @Published private(set) var committing = false
    @Published private(set) var exporting = false
    @Published private(set) var shareRequested = false
    @Published private(set) var ratingPending = false
    @Published var share: ShareRequest?
    @Published private(set) var ruleDraft: RulePayload?
    @Published private(set) var editingRule: CompressionRule?
    @Published private(set) var sharingLimit = Limit.initial

    let args: [String]
    let isolated: Bool
    let appStoreURL: URL?
    var limit: Int? { Limit.parse(limitText) }
    var showsMilestone: Bool { preferences.exports.count >= 10 && !preferences.exports.milestoneDismissed }
    var working: Bool { loading || compressing || exporting }
    var ratingIdle: Bool { !working && panel == nil && share == nil }
    private let store: PhotoStore
    private var selection: UUID?
    private var photoOriginal: PhotoInput?
    private var pdfStage: UUID?
    private var operation: UUID?
    private var previousAction: Task<Void, Never>?
    private var opened = false
    private var awaitedRuleFile: URL?
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        args = arguments
        isolated = arguments.contains("-ui-testing")
        let subdirectory = isolated ? "PhotoKB-UITests" : "PhotoKB"
        store = PhotoStore(root: URL.applicationSupportDirectory.appendingPathComponent(subdirectory, isDirectory: true),
                           temp: URL.temporaryDirectory.appendingPathComponent(subdirectory, isDirectory: true))
        let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? ""
        appStoreURL = DownloadQR.url(appStoreID: id)
    }

    func open() async {
        guard !opened else { return }
        opened = true
        do {
            let (stored, savedRules, savedPreferences) = try await store.open(reset: isolated && args.contains("-reset"))
            latest = stored
            rules = savedRules
            preferences = savedPreferences
            let lastLimit = preferences.lastLimit
            limitText = String(Limit.range.contains(lastLimit) ? lastLimit : Limit.initial)
            ready = true
            if let url = awaitedRuleFile {
                awaitedRuleFile = nil
                importRule(url)
            }
        } catch {
            status = Issue.writeFailed.message
        }
    }

    func updateLimit(_ value: String) {
        guard !committing, value != limitText else { return }
        if compressing { cancel(keepSelection: true) }
        limitText = value
        results = nil
        photoOriginal = nil
        status = nil
    }

    func clearNotice() {
        status = nil
        shareRequested = false
    }

    func cancel(keepSelection: Bool = false) {
        guard !committing else { return }
        previousAction?.cancel()
        previousAction = nil
        operation = nil
        loading = false
        compressing = false
        if processingPDF { clearPDF() }
        if !keepSelection, let selection {
            self.selection = nil
            inputs = []
            photoOriginal = nil
            Task { await store.removeStaging(id: selection) }
        }
        status = L.t("status.cancelled")
    }

    private func select(_ load: @escaping (URL) async throws -> [PhotoInput]) {
        clearPDF()
        if let selection { Task { await store.removeStaging(id: selection) } }
        previousAction?.cancel()
        let id = UUID()
        selection = id
        operation = id
        inputs = []
        photoOriginal = nil
        results = nil
        shareRequested = false
        status = nil
        loading = true
        previousAction = Task {
            do {
                let folder = try await store.staging(id: id)
                let items = try await load(folder)
                guard operation == id, !Task.isCancelled else {
                    await store.removeStaging(id: id)
                    return
                }
                inputs = items
                if let item = items.first, items.count == 1, let issue = item.issue {
                    inputs = []
                    status = issue.message
                    await store.removeStaging(id: id)
                }
            } catch {
                guard operation == id, !Task.isCancelled else { return }
                status = (error as? Issue ?? .unreadable).message
                await store.removeStaging(id: id)
            }
            if operation == id { loading = false }
        }
    }

    func receivePhotos(_ items: [PHPickerResult]) {
        guard !items.isEmpty else { return }
        select { folder in try await PhotoAccess.load(items, folder: folder) }
    }

    func receiveFiles(_ urls: [URL], batch: Bool) {
        guard !urls.isEmpty else { return }
        guard urls.count <= (batch ? 10 : 1) else {
            status = L.t("batch.tooMany")
            return
        }
        select { folder in
            try await Task.detached(priority: .userInitiated) {
                urls.map { url in
                    do {
                        return try PhotoStore.stage(url, in: folder)
                    } catch {
                        return PhotoInput(name: url.lastPathComponent, url: nil, info: nil,
                                          issue: error as? Issue ?? .unreadable)
                    }
                }
            }.value
        }
    }

    func selectFixture(batch: Bool) -> Bool {
        guard isolated, let fixture = Launch.value("-fixture", in: args) else { return false }
        select { folder in
            try await Task.detached(priority: .userInitiated) {
                let isHEIC = fixture == "heic"
                let format: PhotoFormat = isHEIC ? .heic : .png
                let name = isHEIC ? "Portrait.HEIC" : "Upload.png"
                let file = folder.appendingPathComponent(name)
                do {
                    try FixtureImage.write(to: file, format: format, width: 1_600, height: 1_200,
                                           noise: fixture == "sample", transparent: !isHEIC, orientation: isHEIC ? 6 : 1)
                    let input = PhotoInput(name: name, url: file, info: try Compressor.inspect(file), issue: nil)
                    if !batch { return [input] }
                    let second = PhotoInput(name: "Listing.png", url: file, info: input.info, issue: nil)
                    let failed = PhotoInput(name: "Unreadable.png", url: nil, info: nil, issue: .unreadable)
                    return [input, second, failed]
                } catch {
                    throw Issue.unavailable
                }
            }.value
        }
        return true
    }

    func beginCompression() {
        guard ready, !working, !inputs.isEmpty else { return }
        guard let limit else {
            status = Issue.invalidLimit.message
            return
        }
        guard inputs.count == 1 || Launch.freePeriod else { return }
        guard Unlock.shared.mayStart() else { return }
        let id = UUID()
        let staged = selection
        let source = inputs
        operation = id
        status = nil
        shareRequested = false
        compressing = true
        previousAction = Task {
            do {
                while isolated && Launch.value("-hold-compression-at", in: args) == String(limit) {
                    try await Task.sleep(for: .seconds(60))
                }
                let group = try await store.process(source, limit: limit, id: id)
                guard operation == id, !Task.isCancelled else {
                    await store.discard(id)
                    return
                }
                guard !group.results.isEmpty else {
                    results = group.isBatch ? group : nil
                    status = group.isBatch ? nil : group.failures.first?.issue.message
                    compressing = false
                    return
                }
                try await commitPhoto(group)
                photoOriginal = source.count == 1 ? source.first : nil
                inputs = []
                if photoOriginal == nil, let staged {
                    selection = nil
                    await store.removeStaging(id: staged)
                }
                await recordPhotoCompletion(group)
            } catch {
                committing = false
                await store.discard(id)
                guard operation == id, !Task.isCancelled else { return }
                status = (error as? Issue ?? .writeFailed).message
                compressing = false
            }
        }
    }

    func resizePhoto(_ dimensions: ImageResize, limitKB: Int?) {
        guard !working, let group = results, !group.isBatch, let item = group.results.first else { return }
        let id = UUID()
        let original = photoOriginal
        let limit = limitKB ?? self.limit ?? group.limitKB
        operation = id
        clearNotice()
        compressing = true
        previousAction = Task {
            do {
                let input: PhotoInput
                if let original { input = original }
                else { input = try await store.reopenInput(item, in: group) }
                let resized = try await store.process([input], limit: limit, id: id,
                                                      resize: dimensions, applyLimit: limitKB != nil)
                guard operation == id, !Task.isCancelled else {
                    await store.discard(id)
                    return
                }
                guard !resized.results.isEmpty else { throw resized.failures.first?.issue ?? Issue.writeFailed }
                try await commitPhoto(resized)
                if let limitKB { limitText = String(limitKB) }
                await recordPhotoCompletion(resized)
            } catch {
                committing = false
                await store.discard(id)
                guard operation == id, !Task.isCancelled else { return }
                status = (error as? Issue ?? .writeFailed).message
                compressing = false
            }
        }
    }

    private func commitPhoto(_ group: ResultGroup) async throws {
        committing = true
        try await store.commit(group)
        latest = group
        if group.hasLimit { preferences.lastLimit = group.limitKB }
        results = group
        committing = false
        compressing = false
    }

    private func recordPhotoCompletion(_ group: ResultGroup) async {
        let counted = group.failures.isEmpty && !isolated
        if group.failures.isEmpty { Unlock.shared.consume() }
        if counted { preferences.coreReviewProgress = .recording(preferences.coreReviewProgress) }
        await persistPreferences()
        if counted && status == nil { CoreReview.shared.record(preferences.coreReviewProgress) }
    }

    var usesSeedPDF: Bool { isolated && args.contains("-seedPDF") }

    func compressPDF(_ url: URL?) {
        guard ready, !working, url != nil || usesSeedPDF else { return }
        guard let limit else { report(.invalidLimit); return }
        guard Unlock.shared.mayStart() else { return }
        newPhoto()
        let id = UUID()
        operation = id
        pdfStage = id
        processingPDF = true
        compressing = true
        let advanced = Launch.freePeriod && !(isolated && args.contains("-pdf-basic"))
        previousAction = Task {
            do {
                let source: URL
                if let url { source = url }
                else { source = try await store.seedPDF(id: id) }
                let result = try await store.processPDF(source, limit: limit, id: id, hasAdvancedAccess: advanced)
                guard operation == id, !Task.isCancelled else {
                    await store.removeStaging(id: id)
                    return
                }
                pdfResult = result
                if result.fits {
                    Unlock.shared.consume()
                    preferences.lastLimit = limit
                    if !isolated { preferences.coreReviewProgress = .recording(preferences.coreReviewProgress) }
                    await persistPreferences()
                    if !isolated && status == nil { CoreReview.shared.record(preferences.coreReviewProgress) }
                }
            } catch {
                await store.removeStaging(id: id)
                guard operation == id, !Task.isCancelled else { return }
                pdfStage = nil
                status = (error as? Issue ?? .writeFailed).message
            }
            if operation == id {
                processingPDF = false
                compressing = false
            }
        }
    }

    func sharePDF(_ result: PDFCompression) {
        guard !working, share == nil else { return }
        clearNotice()
        submitShare(ShareRequest(id: UUID(), items: [result.url]))
    }

    func savedPDF() {
        status = L.t("pdf.saved")
    }

    private func clearPDF() {
        if let pdfStage { Task { await store.removeStaging(id: pdfStage) } }
        pdfStage = nil
        pdfResult = nil
        processingPDF = false
    }

    func reviewLast() {
        guard let latest, !working else { return }
        clearPDF()
        if let selection { Task { await store.removeStaging(id: selection) } }
        selection = nil
        photoOriginal = nil
        inputs = []
        limitText = String(latest.limitKB)
        results = latest
        panel = nil
        clearNotice()
    }

    func newPhoto() {
        clearPDF()
        if let selection { Task { await store.removeStaging(id: selection) } }
        selection = nil
        inputs = []
        photoOriginal = nil
        results = nil
        clearNotice()
    }

    func report(_ issue: Issue) {
        status = issue.message
    }

    func didCopy(_ rule: RulePayload) {
        status = L.f("status.copied", rule.code)
    }

    func export(group: ResultGroup, result: CompressionResult? = nil, toPhotos: Bool) {
        guard !exporting, share == nil else { return }
        let items = result.map { [$0] } ?? group.results
        guard !items.isEmpty else { return }
        let stage = UUID()
        let ids = items.map(\.id)
        exporting = true
        clearNotice()
        Task {
            do {
                let urls = try await store.prepareExport(group: group, results: items, stage: stage)
                if toPhotos {
                    if !isolated { try await PhotoAccess.save(urls) }
                    status = L.t("status.saved")
                    await exported(group.id, ids: ids)
                    await store.removeStaging(id: stage)
                } else if isolated {
                    shareRequested = true
                    await store.removeStaging(id: stage)
                } else {
                    share = ShareRequest(id: stage, items: urls.map { $0 as Any }, group: group.id, resultIDs: ids)
                }
            } catch {
                status = (error as? Issue ?? .saveFailed).message
                await store.removeStaging(id: stage)
            }
            exporting = false
        }
    }

    func finishShare(_ request: ShareRequest, completed: Bool) {
        exporting = true
        if share?.id == request.id { share = nil }
        Task {
            if completed, let group = request.group { await exported(group, ids: request.resultIDs) }
            await store.removeStaging(id: request.id)
            exporting = false
        }
    }

    private func exported(_ group: UUID, ids: [UUID]) async {
        if preferences.exports.record(group: group, ids: ids, now: Date(), version: version) {
            ratingPending = !isolated
        }
        await persistPreferences()
    }

    var reviewedThisVersion: Bool { preferences.exports.ratedVersion == version }

    func rateIfPending(_ request: () -> Void) {
        guard ratingPending, ratingIdle, !isolated, status == nil, !reviewedThisVersion,
              CoreReview.shared.attempt(request) else { return }
        markReviewRequested()
    }

    func markReviewRequested() {
        ratingPending = false
        preferences.exports.markRated(now: Date(), version: version)
        Task { await persistPreferences() }
    }

    func dismissMilestone() {
        preferences.exports.milestoneDismissed = true
        Task { await persistPreferences() }
    }

    private func persistPreferences() async {
        do { try await store.save(preferences: preferences) }
        catch { status = Issue.writeFailed.message }
    }

    func shareRule(_ value: Int) {
        sharingLimit = value
        clearNotice()
        panel = .ruleShare
    }

    func shareApp() {
        guard !exporting, share == nil, let appStoreURL else { return }
        clearNotice()
        submitShare(ShareRequest(id: UUID(), items: [appStoreURL]))
    }

    func makeShare(rule: RulePayload, image: Data? = nil, milestone: Bool = false) {
        guard !exporting, share == nil else { return }
        exporting = true
        clearNotice()
        let stage = UUID()
        Task {
            defer { exporting = false }
            do {
                let data: Data
                let filename: String
                if let image {
                    data = image
                    filename = milestone ? "PhotoKB-10.jpg" : "PhotoKB-\(rule.limitKB).jpg"
                } else {
                    data = try rule.data()
                    filename = "PhotoKB-\(rule.limitKB).kbrule"
                }
                let url = try await store.writeShare(data, filename: filename, id: stage)
                let text = milestone ? L.t("card.milestoneShare") : L.f("card.shareText", L.integer(rule.limitKB))
                submitShare(ShareRequest(id: stage, items: [url, text]))
            } catch {
                await store.removeStaging(id: stage)
                status = Issue.writeFailed.message
            }
        }
    }

    private func submitShare(_ request: ShareRequest) {
        if isolated {
            shareRequested = true
            Task { await store.removeStaging(id: request.id) }
        } else {
            share = request
        }
    }

    func paste(_ text: String) {
        do {
            ruleDraft = try RulePayload.from(code: text)
            clearNotice()
            panel = .rulePreview
        } catch {
            status = Issue.ruleInvalid.message
        }
    }

    func importRule(_ url: URL) {
        guard ready else { awaitedRuleFile = url; return }
        Task {
            do {
                ruleDraft = try await Task.detached { try RulePayload.read(url) }.value
                clearNotice()
                panel = .rulePreview
            } catch {
                status = Issue.ruleInvalid.message
            }
        }
    }

    func importFixtureRule() {
        guard isolated else { return }
        let stage = UUID()
        Task {
            defer { Task { await store.removeStaging(id: stage) } }
            do {
                let payload = RulePayload(limitKB: 320)
                let file = try await store.writeShare(payload.data(), filename: "Fixture.kbrule", id: stage)
                ruleDraft = try await Task.detached { try RulePayload.read(file) }.value
                clearNotice()
                panel = .rulePreview
            } catch {
                status = Issue.ruleInvalid.message
            }
        }
    }

    func apply(_ limit: Int) {
        updateLimit(String(limit))
        clearNotice()
        panel = nil
    }

    func edit(_ rule: CompressionRule? = nil, defaultLimit: Int? = nil) {
        guard Launch.freePeriod else { return }
        editingRule = rule ?? .init(name: "", limitKB: defaultLimit ?? limit ?? Limit.initial)
        clearNotice()
        panel = .editRule
    }

    func storeRule(_ rule: CompressionRule) {
        guard Launch.freePeriod else { return }
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count) else { status = Issue.ruleName.message; return }
        guard Limit.range.contains(rule.limitKB) else { status = Issue.invalidLimit.message; return }
        var updated = rules
        var clean = rule
        clean.name = name
        if let index = updated.firstIndex(where: { $0.id == clean.id }) {
            updated[index] = clean
        } else {
            updated.append(clean)
        }
        saveRules(updated)
    }

    func delete(_ rule: CompressionRule) {
        saveRules(rules.filter { $0.id != rule.id })
    }

    private func saveRules(_ updated: [CompressionRule]) {
        guard !savingRules else { return }
        savingRules = true
        Task {
            defer { savingRules = false }
            do {
                try await store.save(rules: updated)
                rules = updated
                clearNotice()
                panel = .settings
            } catch {
                status = Issue.writeFailed.message
            }
        }
    }

    private var savingRules = false
}
