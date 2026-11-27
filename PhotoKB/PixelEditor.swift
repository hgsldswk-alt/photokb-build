import SwiftUI

struct PixelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var type
    @State private var width = "600"
    @State private var height = "600"
    @State private var lockRatio = false
    @State private var useLimit = false
    @State private var limit: String
    @State private var issue: Issue?
    let apply: (ImageResize, Int?) -> Void

    init(initialLimit: Int, apply: @escaping (ImageResize, Int?) -> Void) {
        _limit = State(initialValue: String(initialLimit))
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Card {
                        let layout = type.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
                        layout {
                            ForEach(Array(ImageResize.presets.enumerated()), id: \.offset) { _, size in
                                let selected = Limit.parse(width) == size.0 && Limit.parse(height) == size.1
                                Button {
                                    width = String(size.0)
                                    height = String(size.1)
                                    issue = nil
                                } label: {
                                    Text(verbatim: "\(size.0)×\(size.1)")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                                .buttonStyle(selected ? ActionStyle.selected : ActionStyle.preset)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityHint(size.0 == 600 ? L.t("pixel.passport") : "")
                                .accessibilityIdentifier("pixel.preset.\(size.0)x\(size.1)")
                            }
                        }
                        if Limit.parse(width) == 600 && Limit.parse(height) == 600 {
                            Text(L.t("pixel.passport")).font(.caption).foregroundStyle(Theme.muted)
                        }
                        layout {
                            field("pixel.width", text: $width)
                            field("pixel.height", text: $height)
                        }
                        Toggle(L.t("pixel.lock"), isOn: $lockRatio)
                            .accessibilityIdentifier("pixel.lock")
                        Text(L.t(lockRatio ? "pixel.fit" : "pixel.crop"))
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Card {
                        Toggle(L.t("pixel.useLimit"), isOn: $useLimit)
                            .accessibilityIdentifier("pixel.useLimit")
                        if useLimit { field("home.limit", text: $limit) }
                    }
                    if let issue { Notice(text: issue.message) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.paper)
            .foregroundStyle(Theme.ink)
            .navigationTitle(L.t("pixel.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("pixel.apply"), action: submit)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("pixel.apply")
                }
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.t(title)).font(.footnote.weight(.semibold))
            TextField(L.t(title), text: text)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .accessibilityLabel(L.t(title))
                .accessibilityIdentifier(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        guard let w = Limit.parse(width), let h = Limit.parse(height),
              let resize = try? ImageResize(width: w, height: h, lockRatio: lockRatio) else {
            issue = .invalidPixels
            return
        }
        let cap = useLimit ? Limit.parse(limit) : nil
        guard !useLimit || cap != nil else {
            issue = .invalidLimit
            return
        }
        apply(resize, cap)
    }
}
