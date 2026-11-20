import PhotosUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct PhotoKBApp: App {
    @StateObject private var model = PhotoModel()

    var body: some Scene {
        WindowGroup {
            HomeView(model: model, purchases: model.purchases)
                .tint(Theme.blue)
                .preferredColorScheme(.light)
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: PhotoModel
    @ObservedObject var purchases: Purchases
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var type
    @FocusState private var limitFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var limitSize = 48.0
    @State private var photoPickerCount: Int?
    @State private var filePicker = false
    @State private var fileKind = PickerKind.files
    @State private var fileBatch = false
    @State private var pendingFile: PickerKind?
    @State private var showBatchOptions = false

    var body: some View {
        GeometryReader { bounds in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topBar
                    if let group = model.results {
                        ResultView(group: group, model: model)
                    } else {
                        inputView
                    }
                    if model.panel == nil {
                        if model.shareRequested { Notice(text: L.t("status.share"), isShare: true) }
                        if model.results != nil, let status = model.status { Notice(text: status) }
                    }
                    if model.results == nil {
                        Spacer(minLength: 14)
                        Text(L.t("home.footer"))
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 13)
                .padding(.bottom, 16)
                .frame(minHeight: bounds.size.height, alignment: .top)
                .frame(maxWidth: 570)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.panel == nil, model.results == nil, let status = model.status {
                    Notice(text: status)
                        .frame(maxWidth: 570)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Theme.paper)
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .background(Theme.paper.ignoresSafeArea())
        .task { await model.open() }
        .onChange(of: model.ratingPending) { _, _ in checkRating() }
        .onChange(of: model.ratingIdle) { _, _ in checkRating() }
        .onChange(of: purchases.busy) { _, _ in checkRating() }
        .onChange(of: scenePhase) { _, _ in checkRating() }
        .onOpenURL { url in if url.isFileURL { model.importRule(url) } }
        .sheet(isPresented: Binding(get: { model.panel != nil }, set: { if !$0 { model.panel = nil } }),
               onDismiss: afterPanel) {
            PanelView(model: model, purchases: purchases, importRuleFile: {
                model.panel = nil
                pendingFile = .rule
            })
            .shareSheet(model)
        }
        .sheet(isPresented: Binding(get: { photoPickerCount != nil }, set: { if !$0 { photoPickerCount = nil } })) {
            if let count = photoPickerCount {
                SystemPhotoPicker(limit: count) { items in
                    photoPickerCount = nil
                    model.receivePhotos(items)
                }
                .ignoresSafeArea()
            }
        }
        .fileImporter(isPresented: $filePicker,
                      allowedContentTypes: fileKind == .rule ? [RulePayload.type] : PhotoFormat.allCases.map(\.type),
                      allowsMultipleSelection: fileBatch) { result in
            switch result {
            case .success(let urls):
                if fileKind == .rule {
                    if let url = urls.first { model.importRule(url) }
                } else {
                    model.receiveFiles(urls, batch: fileBatch)
                }
            case .failure: model.report(.unreadable)
            }
        }
        .sheet(item: Binding(get: { model.panel == nil ? model.share : nil }, set: { model.share = $0 })) { request in
            SystemShare(request: request) { finished in model.finishShare(request, completed: finished) }
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(L.t("app.name")).font(.subheadline.weight(.bold))
            Spacer(minLength: 2)
            if model.results != nil {
                Button(L.t("home.changePhoto")) { choosePhotos() }
                    .buttonStyle(ActionStyle.menu)
                    .accessibilityIdentifier("home.changePhoto")
                    .disabled(model.working)
            } else {
                Button(L.t("settings.title")) { model.clearNotice(); model.panel = .settings }
                    .buttonStyle(ActionStyle.menu)
                    .accessibilityIdentifier("home.settings")
                    .disabled(!model.ready || model.working)
            }
        }
        .padding(.bottom, 2)
    }

    private var inputView: some View {
        Group {
            PageHeading(title: "home.title", subtitle: "home.subtitle")
            limitCard
            if model.loading || model.compressing {
                HStack {
                    ProgressView()
                    Text(L.t(model.loading ? "home.loading" : "home.compressing"))
                    Spacer()
                    if !model.committing {
                        Button(L.t("common.cancel")) { model.cancel() }
                            .buttonStyle(ActionStyle.menu)
                            .accessibilityIdentifier("home.cancel")
                    }
                }
            } else if !model.inputs.isEmpty {
                inputSummary
                Button(L.t(model.inputs.count > 1 ? "batch.compress" : "home.compress")) {
                    limitFocused = false
                    model.beginCompression()
                }
                .buttonStyle(ActionStyle.primary)
                .accessibilityIdentifier("home.compress")
                Button(L.t("home.changePhoto")) { choosePhotos() }
                    .buttonStyle(ActionStyle.quiet)
                    .accessibilityIdentifier("home.changeSelected")
            } else {
                VStack(spacing: 4) {
                    Button(L.t("home.photos")) { choosePhotos() }
                        .buttonStyle(ActionStyle.primary)
                        .accessibilityIdentifier("home.pickPhotos")
                    ActionPair {
                        Button(L.t("home.files")) { chooseFiles() }
                            .buttonStyle(ActionStyle.quiet)
                            .accessibilityIdentifier("home.pickFiles")
                    } second: {
                        Button(L.t("batch.select")) {
                            limitFocused = false
                            if purchases.hasPro {
                                if !model.selectFixture(batch: true) { showBatchOptions = true }
                            } else {
                                model.panel = .paywall
                            }
                        }
                        .buttonStyle(ActionStyle.quiet)
                        .accessibilityIdentifier("home.pickBatch")
                        .confirmationDialog(L.t("batch.select"), isPresented: $showBatchOptions, titleVisibility: .visible) {
                            Button(L.t("home.photos")) { choosePhotos(batch: true) }
                            Button(L.t("home.files")) { chooseFiles(batch: true) }
                        }
                    }
                }
                .disabled(!model.ready)
                .opacity(model.ready ? 1 : 0.55)
            }
        }
    }

    private var limitCard: some View {
        Card {
            Text(L.t("home.limit")).font(.body.weight(.bold))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("", text: Binding(get: { model.limitText }, set: model.updateLimit),
                          prompt: Text(verbatim: "—").foregroundColor(Theme.muted))
                    .font(.system(size: limitSize, weight: .bold))
                    .monospacedDigit()
                    .keyboardType(.numberPad)
                    .focused($limitFocused)
                    .accessibilityLabel(Text(L.t("home.limit")))
                    .accessibilityIdentifier("home.limit")
                    .fixedSize(horizontal: model.limitText.count <= 5 && !model.limitText.isEmpty && !type.isAccessibilitySize, vertical: false)
                Text(L.t("unit.kb")).font(.headline).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 74)
            .padding(.horizontal, 11)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.border).allowsHitTesting(false) }
            .contentShape(Rectangle())
            .onTapGesture { limitFocused = true }
            let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 7)) : AnyLayout(HStackLayout(spacing: 7))
            layout {
                ForEach(Limit.presets, id: \.self) { value in
                    Button(L.f("size.kb", L.integer(value))) {
                        limitFocused = false
                        model.updateLimit(String(value))
                    }
                    .buttonStyle(model.limit == value ? ActionStyle.selected : ActionStyle.preset)
                    .accessibilityAddTraits(model.limit == value ? .isSelected : [])
                    .accessibilityIdentifier("limit.\(value)")
                }
            }
            Text(L.t("home.units")).font(.caption).foregroundStyle(Theme.muted)
        }
        .disabled(model.committing)
    }

    private var inputSummary: some View {
        Card {
            if model.inputs.count > 1 {
                Text(L.f("batch.selected", L.integer(model.inputs.count))).font(.headline)
            } else if let info = model.inputs.first?.info {
                Fact(label: "result.original", value: L.f("result.input", info.format.rawValue, L.kb(info.bytes)))
                Fact(label: "result.dimensions", value: L.f("result.pixels", L.integer(info.width), L.integer(info.height)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.selection")
    }

    private func choosePhotos(batch: Bool = false) {
        limitFocused = false
        if !model.selectFixture(batch: batch) { photoPickerCount = batch ? 10 : 1 }
    }

    private func chooseFiles(batch: Bool = false) {
        limitFocused = false
        if !model.selectFixture(batch: batch) {
            fileKind = .files
            fileBatch = batch
            filePicker = true
        }
    }

    private func afterPanel() {
        guard let pendingFile else { return }
        fileKind = pendingFile
        fileBatch = false
        self.pendingFile = nil
        filePicker = true
    }

    private func checkRating() {
        guard scenePhase == .active, photoPickerCount == nil, !filePicker, !showBatchOptions else { return }
        model.rateIfPending { requestReview() }
    }
}
