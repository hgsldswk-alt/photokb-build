import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PhotoModel
    let importRuleFile: () -> Void
    @State private var code = ""
    @State private var name = ""
    @State private var ruleLimit = ""
    @State private var confirmDelete: CompressionRule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L.t("app.name")).font(.subheadline.weight(.bold))
                    Spacer()
                    Button(L.t("common.done")) { model.panel = nil; model.clearNotice() }
                        .buttonStyle(ActionStyle.menu)
                        .accessibilityIdentifier("panel.done")
                }
                content
                if model.shareRequested { Notice(text: L.t("status.share"), isShare: true) }
                if let status = model.status { Notice(text: status) }
            }
            .padding(24)
            .frame(maxWidth: 570)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(Theme.ink)
        .background(Theme.paper.ignoresSafeArea())
        .onChange(of: model.panel, initial: true) { _, panel in
            switch panel {
            case .editRule:
                name = model.editingRule?.name ?? ""
                ruleLimit = String(model.editingRule?.limitKB ?? Limit.initial)
            case .paste:
                code = model.isolated ? (ProcessInfo.processInfo.environment["PHOTOKB_RULE_CODE"] ?? "") : ""
            default: break
            }
        }
        .alert(L.t("rule.deleteConfirm"), isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { rule in
            Button(L.t("common.delete"), role: .destructive) { model.delete(rule) }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder private var content: some View {
        switch model.panel {
        case .settings: settings
        case .ruleShare: CardShareView(model: model, milestone: false)
        case .milestone: CardShareView(model: model, milestone: true)
        case .paste: paste
        case .rulePreview: preview
        case .editRule: editor
        case nil: EmptyView()
        }
    }

    private var settings: some View {
        Group {
            PageHeading(title: "settings.title")
            if model.latest != nil {
                Button(L.t("result.last")) { model.reviewLast() }
                    .buttonStyle(ActionStyle.secondary)
                    .accessibilityIdentifier("settings.last")
            }
            Card {
                Text(L.t("rule.title")).font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(model.rules) { rule in
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
                            model.apply(rule.limitKB)
                        } label: {
                            Fact(label: rule.name, value: L.f("size.kb", L.integer(rule.limitKB)), localized: false)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("rule.apply.\(rule.name)")
                        ruleActions(rule)
                        Divider()
                    }
                }
                Button(L.t("rule.new")) { model.edit() }
                    .buttonStyle(ActionStyle.secondary)
                    .accessibilityIdentifier("settings.newRule")
                if model.isolated {
                    Button(L.t("rule.paste")) {
                        if let text = ProcessInfo.processInfo.environment["PHOTOKB_RULE_PASTE"] {
                            model.paste(text)
                        } else {
                            model.panel = .paste
                        }
                    }
                    .buttonStyle(ActionStyle.quiet)
                    .accessibilityIdentifier("settings.paste")
                } else {
                    PasteButton(payloadType: String.self) { strings in
                        if let text = strings.first { model.paste(text) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("settings.paste")
                }
                Button(L.t("rule.enter")) { model.clearNotice(); model.panel = .paste }
                    .buttonStyle(ActionStyle.quiet)
                    .accessibilityIdentifier("settings.enterCode")
                Button(L.t("rule.importFile"), action: importRuleFile)
                    .buttonStyle(ActionStyle.quiet)
                    .accessibilityIdentifier("settings.import")
                if model.isolated && model.args.contains("-fixture-rule") {
                    Button(L.t("rule.importFixture")) { model.importFixtureRule() }
                        .buttonStyle(ActionStyle.quiet)
                        .accessibilityIdentifier("settings.importFixture")
                }
                if let limit = model.limit {
                    Button(L.t("card.title")) { model.shareRule(limit) }
                        .buttonStyle(ActionStyle.quiet)
                        .accessibilityIdentifier("settings.shareRule")
                }
            }
            if model.showsMilestone {
                Card(highlighted: true) {
                    Button(L.t("card.milestone")) { model.clearNotice(); model.panel = .milestone }
                        .buttonStyle(ActionStyle.secondary)
                        .accessibilityIdentifier("settings.milestone")
                    Button(L.t("card.hideMilestone")) { model.dismissMilestone() }
                        .buttonStyle(ActionStyle.quiet)
                        .accessibilityIdentifier("settings.hideMilestone")
                }
            }
            moreSettings
        }
    }

    @ViewBuilder private func ruleActions(_ rule: CompressionRule) -> some View {
        ActionPair {
            Button(L.t("common.edit")) { model.edit(rule) }
                .buttonStyle(ActionStyle.quiet)
                .accessibilityIdentifier("rule.edit.\(rule.name)")
        } second: {
            Button(L.t("rule.export")) { model.shareRule(rule.limitKB) }
                .buttonStyle(ActionStyle.quiet)
                .accessibilityIdentifier("rule.export.\(rule.name)")
        }
        Button(L.t("common.delete"), role: .destructive) { confirmDelete = rule }
            .font(.footnote.weight(.semibold))
            .frame(minHeight: 44)
            .accessibilityIdentifier("rule.delete.\(rule.name)")
    }

    private var moreSettings: some View {
        Card {
            if model.appStoreURL != nil {
                Button(L.t("settings.shareApp")) { model.shareApp() }
                    .buttonStyle(ActionStyle.quiet)
                    .accessibilityIdentifier("settings.shareApp")
                if let url = model.appStoreURL,
                   let writeReview = URL(string: url.absoluteString + "?action=write-review") {
                    Link(L.t("settings.rate"), destination: writeReview)
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("settings.rate")
                }
            } else {
                Text(L.t("settings.storeUnavailable")).font(.footnote).foregroundStyle(Theme.muted)
            }
            Divider()
            Text(L.t("settings.privacy")).font(.headline).accessibilityAddTraits(.isHeader)
            Text(L.t("settings.privacyBody")).font(.footnote).foregroundStyle(Theme.muted)
        }
    }

    private var paste: some View {
        Group {
            PageHeading(title: "rule.enter", subtitle: "rule.codeHelp")
            Card {
                TextField(L.t("rule.code"), text: $code)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("rule.code")
            }
            Button(L.t("rule.preview")) { model.paste(code) }
                .buttonStyle(ActionStyle.primary)
                .accessibilityIdentifier("rule.preview")
        }
    }

    private var preview: some View {
        Group {
            PageHeading(title: "rule.preview", subtitle: "rule.previewSubtitle")
            if let rule = model.ruleDraft {
                Card(highlighted: true) {
                    Text(L.f("rule.previewValue", L.integer(rule.limitKB)))
                        .font(.title2.weight(.bold)).monospacedDigit()
                        .accessibilityIdentifier("rule.previewValue")
                }
                Button(L.t("rule.apply")) { model.apply(rule.limitKB) }
                    .buttonStyle(ActionStyle.primary)
                    .accessibilityIdentifier("rule.apply")
                Button(L.t("rule.saveNamed")) { model.edit(defaultLimit: rule.limitKB) }
                    .buttonStyle(ActionStyle.quiet)
                    .accessibilityIdentifier("rule.saveNamed")
            }
        }
    }

    private var editor: some View {
        Group {
            PageHeading(title: model.editingRule?.name.isEmpty == false ? "rule.edit" : "rule.new")
            Card {
                TextField(L.t("rule.name"), text: $name)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("rule.name")
                Divider()
                TextField(L.t("home.limit"), text: $ruleLimit)
                    .keyboardType(.numberPad)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("rule.limit")
            }
            Button(L.t("common.save")) {
                guard let limit = Limit.parse(ruleLimit), var rule = model.editingRule else {
                    model.report(.invalidLimit)
                    return
                }
                rule.name = name
                rule.limitKB = limit
                model.storeRule(rule)
            }
            .buttonStyle(ActionStyle.primary)
            .accessibilityIdentifier("rule.save")
        }
    }
}
