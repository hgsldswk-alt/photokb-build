import SwiftUI

struct PDFResultView: View {
    let result: PDFCompression
    @ObservedObject var model: PhotoModel
    let save: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var size = 52.0
    private var before: String { L.f("size.kb", L.kb(result.inputBytes)) }
    private var after: String { L.f("size.kb", L.kb(result.outputBytes)) }

    var body: some View {
        PageHeading(title: "pdf.title")
        Card(highlighted: true) {
            HStack(alignment: .top) {
                Text(result.fits ? L.f("result.pass", L.integer(result.limitKB))
                     : L.f("pdf.best", L.f("size.kb", L.kb(result.outputBytes))))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(result.fits ? Theme.teal : Theme.amber)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 9)
                    .background(result.fits ? Theme.tealSoft : Theme.amberSoft, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityIdentifier(result.fits ? "pdf.pass" : "pdf.best")
                Spacer(minLength: 6)
                Image(systemName: "doc.text.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.teal)
                    .frame(width: 42, height: 42)
                    .background(Theme.tealSoft, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(before)
                    Image(systemName: "arrow.down")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
                Text(after)
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            }
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L.f("pdf.beforeAfter", before, after)))
            .accessibilityIdentifier("pdf.comparison")
            Divider()
            Fact(label: "pdf.pages", value: L.integer(result.pageCount))
                .accessibilityIdentifier("pdf.pages")
            if !result.fits {
                Fact(label: "home.limit", value: L.f("size.kb", L.integer(result.limitKB)))
            }
            if result.rasterized {
                Text(L.t("pdf.rasterized")).font(.footnote).foregroundStyle(Theme.muted)
            }
        }
        ActionPair {
            Button(action: save) { Label(L.t("pdf.save"), systemImage: "folder") }
                .buttonStyle(ActionStyle.primary)
                .accessibilityIdentifier("pdf.save")
        } second: {
            Button { model.sharePDF(result) } label: { Label(L.t("pdf.share"), systemImage: "square.and.arrow.up") }
                .buttonStyle(ActionStyle.secondary)
                .accessibilityIdentifier("pdf.share")
        }
        .disabled(model.working)
    }
}
