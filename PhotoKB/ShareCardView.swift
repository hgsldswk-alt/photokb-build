import SwiftUI
import UIKit

struct ShareCardView: View {
    let limit: Int
    let milestone: Bool
    let qr: CGImage?
    let export: Bool
    var expectsQR = false
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 62.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.t(milestone ? "card.milestoneTag" : "card.jpeg"))
                .font(.subheadline.weight(.bold))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(L.integer(milestone ? 10 : limit))
                        .font(.system(size: numberSize, weight: .bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(L.t(milestone ? "card.photos" : "unit.kb")).font(.title3.weight(.bold))
                }
                Text(milestone ? L.t("card.milestone") : L.f("card.line", L.integer(limit)))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Rectangle().fill(.white.opacity(0.35)).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 10) { signature; qrArea }
                VStack(alignment: .leading, spacing: 10) { signature; qrArea }
            }
        }
        .padding(export ? 28 : 21)
        .frame(maxWidth: export ? 360 : 284)
        .frame(minHeight: export ? 480 : 365)
        .foregroundStyle(.white)
        .background(Theme.blue, in: RoundedRectangle(cornerRadius: export ? 0 : 20))
    }

    private var signature: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.t("app.name")).fontWeight(.semibold)
            Text(L.t(milestone ? "card.tagOne" : "card.tags"))
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var qrArea: some View {
        Group {
            if let qr {
                Image(qr, scale: 1, label: Text(L.t("card.downloadQR")))
                    .interpolation(.none)
                    .resizable().scaledToFit().padding(9)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "qrcode")
                        .font(.title2)
                        .accessibilityHidden(true)
                    Text(L.t("card.qrPlaceholder")).font(.caption2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(expectsQR ? "card.qrLoading" : "card.qrPlaceholder")
            }
        }
        .frame(width: export ? 106 : 86, height: export ? 106 : 86)
    }
}

struct CardShareView: View {
    @ObservedObject var model: PhotoModel
    let milestone: Bool
    @State private var qr: CGImage?
    @State private var rendering = false

    var body: some View {
        let value = model.sharingLimit
        PageHeading(title: milestone ? "card.milestone" : "card.title")
        ShareCardView(limit: value, milestone: milestone, qr: qr, export: false, expectsQR: model.appStoreURL != nil)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("card.preview")
            .task(id: model.appStoreURL) {
                if let url = model.appStoreURL {
                    qr = await Task.detached { DownloadQR.image(for: url) }.value
                }
            }
        if qr != nil || model.isolated {
            Button(L.t(milestone ? "card.shareMilestone" : "card.share")) {
                render(limit: value)
            }
            .buttonStyle(ActionStyle.primary)
            .accessibilityIdentifier("card.share")
            .disabled(rendering || qr == nil)
        }
        if !milestone {
            let rule = RulePayload(limitKB: value)
            ActionPair {
                Button(L.t("card.copy")) {
                    UIPasteboard.general.string = rule.code
                    model.didCopy(rule)
                }
                .buttonStyle(ActionStyle.quiet)
                .accessibilityIdentifier("card.copy")
            } second: {
                Button(L.t("card.file")) { model.makeShare(rule: rule) }
                    .buttonStyle(ActionStyle.quiet)
                    .accessibilityIdentifier("card.file")
            }
        }
    }

    @MainActor private func render(limit: Int) {
        guard let qr else { return }
        rendering = true
        let card = ShareCardView(limit: limit, milestone: milestone, qr: qr, export: true)
            .environment(\.dynamicTypeSize, .large)
            .frame(width: 360, height: 480)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.isOpaque = true
        defer { rendering = false }
        guard let image = renderer.uiImage, let pixels = image.cgImage,
              pixels.width == 1_080, pixels.height == 1_440,
              let data = image.jpegData(compressionQuality: 0.94) else {
            model.report(.writeFailed)
            return
        }
        model.makeShare(rule: RulePayload(limitKB: limit), image: data, milestone: milestone)
    }
}
