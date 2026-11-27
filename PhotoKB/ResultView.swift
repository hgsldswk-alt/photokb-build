import SwiftUI

struct ResultView: View {
    let group: ResultGroup
    @ObservedObject var model: PhotoModel
    @ScaledMetric(relativeTo: .largeTitle) private var size = 51.0
    @State private var showPixels = false

    var body: some View {
        if group.isBatch {
            batch
        } else if let item = group.results.first {
            PageHeading(title: "result.title", subtitle: "result.subtitle")
            Card(highlighted: true) {
                if group.hasLimit { achieved }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        sizeText(item)
                        Text(L.t("unit.kb")).font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        sizeText(item)
                        Text(L.t("unit.kb")).font(.headline)
                    }
                }
                .foregroundStyle(Theme.blue)
                Text(L.f("result.bytes", L.integer(item.outputBytes)))
                    .font(.caption).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("result.bytes")
                Divider().padding(.vertical, 4)
                Fact(label: "result.original", value: L.f("result.input", item.input.format.rawValue, L.kb(item.input.bytes)))
                Fact(label: "result.copy", value: L.f("result.jpeg", L.integer(item.width), L.integer(item.height)))
            }
            actions(item)
            Button { showPixels = true } label: {
                Label(L.t("pixel.title"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(ActionStyle.secondary)
            .accessibilityIdentifier("result.pixels")
            .disabled(model.working)
            .sheet(isPresented: $showPixels) {
                PixelEditor(initialLimit: model.limit ?? group.limitKB) { size, limit in
                    showPixels = false
                    model.resizePhoto(size, limitKB: limit)
                }
            }
            if model.compressing {
                HStack {
                    ProgressView()
                    Text(L.t("pixel.resizing"))
                    Spacer()
                    if !model.committing {
                        Button(L.t("common.cancel")) { model.cancel(keepSelection: true) }
                            .buttonStyle(ActionStyle.menu)
                    }
                }
            }
            followup
        }
    }

    private func sizeText(_ item: CompressionResult) -> some View {
        Text(L.kb(item.outputBytes))
            .font(.system(size: size, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .accessibilityLabel(Text(L.f("size.kb", L.kb(item.outputBytes))))
    }

    private var achieved: some View {
        Text(L.f("result.pass", L.integer(group.limitKB)))
            .font(.footnote.weight(.bold))
            .foregroundStyle(Theme.blue)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("result.pass")
    }

    private var batch: some View {
        Group {
            PageHeading(title: group.results.isEmpty ? "batch.failedTitle" : "batch.title")
            Card(highlighted: true) {
                Text(L.f("batch.summary", L.integer(group.results.count), L.integer(group.failures.count)))
                    .font(.headline)
                    .accessibilityIdentifier("batch.summary")
                if !group.results.isEmpty { achieved }
                ForEach(group.results) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Divider()
                        Text(item.name).font(.subheadline.weight(.semibold))
                        Text(L.f("size.kb", L.kb(item.outputBytes))).font(.footnote).foregroundStyle(Theme.muted)
                        Button(L.t("result.share")) { model.export(group: group, result: item, toPhotos: false) }
                            .buttonStyle(ActionStyle.menu)
                            .accessibilityIdentifier("batch.shareItem.\(item.filename)")
                            .disabled(model.working)
                    }
                }
                ForEach(group.failures) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Divider()
                        Text(item.name).font(.subheadline.weight(.semibold))
                        Text(item.issue.message).font(.footnote).foregroundStyle(Theme.muted)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("batch.failure")
                }
            }
            if !group.results.isEmpty {
                actions(nil)
                followup
            } else {
                Button(L.t("batch.retry")) { model.newPhoto() }
                    .buttonStyle(ActionStyle.primary)
                    .accessibilityIdentifier("batch.retry")
            }
        }
    }

    private func actions(_ item: CompressionResult?) -> some View {
        ActionPair {
            Button(L.t(item == nil ? "batch.save" : "result.save")) {
                model.export(group: group, result: item, toPhotos: true)
            }
            .buttonStyle(ActionStyle.primary)
            .accessibilityIdentifier("result.save")
        } second: {
            Button(L.t(item == nil ? "batch.share" : "result.share")) {
                model.export(group: group, result: item, toPhotos: false)
            }
            .buttonStyle(ActionStyle.secondary)
            .accessibilityIdentifier("result.share")
        }
        .disabled(model.working)
        .opacity(model.working ? 0.6 : 1)
    }

    private var followup: some View {
        ActionPair {
            if group.hasLimit {
                Button(L.t("card.title")) { model.shareRule(group.limitKB) }
                    .buttonStyle(ActionStyle.quiet)
                    .accessibilityIdentifier("result.shareRule")
            }
        } second: {
            Button(L.t("home.newTask")) { model.newPhoto() }
                .buttonStyle(ActionStyle.quiet)
                .accessibilityIdentifier("result.newTask")
        }
        .disabled(model.working)
    }
}
