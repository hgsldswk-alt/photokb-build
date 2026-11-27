import StoreKit
import SwiftUI

@MainActor final class Unlock: ObservableObject {
    static let shared = Unlock()
    static let productID = "com.hgsldswk.photokb.pro"
    static let freeLimit = 1
    static let lastPaidBuild = 318

    @Published private(set) var used: Int
    @Published private(set) var purchased: Bool
    @Published private(set) var price: String?
    @Published private(set) var working = false
    @Published var showPaywall = false
    @Published var message: String?

    private let defaults = UserDefaults.standard
    private let args = ProcessInfo.processInfo.arguments
    private var product: Product?

    private init() {
        used = defaults.integer(forKey: "unlock.used")
        purchased = defaults.bool(forKey: "unlock.purchased")
        if args.contains("-ui-testing") {
            used = Int(Launch.value("-free-used", in: args) ?? "") ?? 0
            purchased = !args.contains("-paywall") && !args.contains("-free-used")
            showPaywall = args.contains("-paywall")
        }
    }

    var unlocked: Bool { purchased }
    var remaining: Int { max(0, Self.freeLimit - used) }

    func mayStart() -> Bool {
        if unlocked || used < Self.freeLimit { return true }
        showPaywall = true
        return false
    }

    func consume() {
        guard !unlocked else { return }
        used += 1
        if !args.contains("-ui-testing") { defaults.set(used, forKey: "unlock.used") }
    }

    func start() async {
        guard !args.contains("-ui-testing") else { price = "$0.99"; return }
        Task { for await update in Transaction.updates { await handle(update) } }
        await refresh()
        await checkLegacyBuyer()
        await loadProduct()
    }

    private func loadProduct() async {
        product = try? await Product.products(for: [Self.productID]).first
        price = product?.displayPrice
    }

    private func refresh() async {
        for await result in Transaction.currentEntitlements {
            if case let .verified(t) = result, t.productID == Self.productID, t.revocationDate == nil { grant() }
        }
    }

    private func checkLegacyBuyer() async {
        guard !purchased, case let .verified(app)? = try? await AppTransaction.shared else { return }
        if let build = Int(app.originalAppVersion), build <= Self.lastPaidBuild { grant() }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case let .verified(t) = result, t.productID == Self.productID else { return }
        if t.revocationDate == nil { grant() } else { purchased = false; defaults.set(false, forKey: "unlock.purchased") }
        await t.finish()
    }

    private func grant() {
        purchased = true
        showPaywall = false
        defaults.set(true, forKey: "unlock.purchased")
    }

    func buy() async {
        if product == nil { await loadProduct() }
        guard let product, !working else { message = L.t("unlock.unavailable"); return }
        working = true
        defer { working = false }
        do {
            switch try await product.purchase() {
            case let .success(result): await handle(result)
            case .pending: message = L.t("unlock.pending")
            default: break
            }
        } catch { message = L.t("unlock.unavailable") }
    }

    func restore() async {
        working = true
        defer { working = false }
        try? await AppStore.sync()
        await refresh()
        await checkLegacyBuyer()
        if !purchased { message = L.t("unlock.nothing") }
    }
}

struct UnlockSheet: View {
    @ObservedObject var unlock: Unlock
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(Theme.muted) }
                    .accessibilityLabel(L.t("unlock.later"))
                    .accessibilityIdentifier("unlock.close")
            }
            Text(L.t("unlock.title")).font(.title2.bold()).accessibilityIdentifier("unlock.title")
            Text(L.t("unlock.body")).foregroundStyle(Theme.muted)
            Button {
                Task { await unlock.buy() }
            } label: {
                Text(unlock.price.map { L.f("unlock.buy", $0) } ?? L.t("unlock.buyPlain")).frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionStyle.primary)
            .disabled(unlock.working)
            .accessibilityIdentifier("unlock.buy")
            Button(L.t("unlock.restore")) { Task { await unlock.restore() } }
                .buttonStyle(ActionStyle.quiet)
                .disabled(unlock.working)
                .accessibilityIdentifier("unlock.restore")
            if let message = unlock.message {
                Text(message).font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .foregroundStyle(Theme.ink)
        .background(Theme.paper.ignoresSafeArea())
        .presentationDetents([.medium])
        .onChange(of: unlock.purchased) { _, ok in if ok { dismiss() } }
    }
}
