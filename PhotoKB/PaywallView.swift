import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject var purchases: Purchases

    var body: some View {
        PageHeading(title: "pay.title", subtitle: "pay.subtitle")
        Card(highlighted: true) {
            Label(L.t("pay.batch"), systemImage: "photo.on.rectangle")
            Label(L.t("pay.rules"), systemImage: "square.and.pencil")
            Divider()
            Text(stateText).font(.subheadline.weight(.semibold))
            Text(L.t("pay.trialTerms")).font(.footnote).foregroundStyle(Theme.muted)
        }
        if purchases.value?.purchasedPro != true {
            Button(buyTitle) { Task { await purchases.buy(purchases.pro) } }
                .buttonStyle(ActionStyle.primary)
                .accessibilityIdentifier("pay.purchase")
                .disabled(purchases.busy || (purchases.pro == nil && !purchases.isolated))
            if purchases.value?.trialClaimedAt == nil && purchases.hasPro {
                Button(L.t("pay.claim")) { Task { await purchases.buy(purchases.trial) } }
                    .buttonStyle(ActionStyle.secondary)
                    .accessibilityIdentifier("pay.claim")
                    .disabled(purchases.busy || (purchases.trial == nil && !purchases.isolated))
            }
        }
        Button(L.t("pay.restore")) { Task { await purchases.restore() } }
            .buttonStyle(ActionStyle.quiet)
            .accessibilityIdentifier("pay.restore")
            .disabled(purchases.busy)
        if let message = purchases.message { Notice(text: message) }
        if purchases.busy { ProgressView() }
        if !purchases.isolated && purchases.pro == nil {
            Button(L.t("pay.load")) { Task { await purchases.load() } }
                .buttonStyle(ActionStyle.quiet)
                .accessibilityIdentifier("pay.load")
        }
        Text(L.t("pay.freeSingle")).font(.footnote).foregroundStyle(Theme.muted)
            .task { await purchases.load() }
    }

    private var buyTitle: String {
        if let product = purchases.pro { return L.f("pay.buyPrice", product.displayPrice) }
        if purchases.isolated { return L.f("pay.buyPrice", "US$2.99") }
        return L.t("pay.buy")
    }

    private var stateText: String {
        if purchases.value?.purchasedPro == true { return L.t("pay.owned") }
        guard let value = purchases.value else { return L.t("pay.loading") }
        return purchases.hasPro
            ? L.f("pay.trialEnds", value.trialEnd.formatted(date: .abbreviated, time: .omitted))
            : L.t("pay.expired")
    }
}
