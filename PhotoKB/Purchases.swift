import Foundation
import StoreKit
import SwiftUI

@MainActor
final class Purchases: ObservableObject {
    static let proID = "com.hgsldswk.photokb.pro"
    static let trialID = "com.hgsldswk.photokb.trial"

    @Published private(set) var value: Entitlement?
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published var message: String?
    let isolated: Bool
    let free: Bool
    private let fixtureNow: Date?
    private let vault = EntitlementVault()
    private var listener: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var started = false

    init(arguments: [String]) {
        let isTest = arguments.contains("-ui-testing")
        isolated = isTest
        free = Launch.isFree(arguments: arguments)
        fixtureNow = isTest ? Date(timeIntervalSince1970: 1_800_000_000) : nil
        if isTest {
            let now = fixtureNow ?? Date()
            let start = arguments.contains("-expired") ? now.addingTimeInterval(-40 * 86_400) : now
            value = Entitlement(firstOpen: start, proStartedAt: start)
        }
    }

    deinit {
        listener?.cancel()
        expiry?.cancel()
    }

    var hasPro: Bool { free || (value?.hasPro(at: fixtureNow ?? Date(), free: false) ?? false) }
    var pro: Product? { products.first { $0.id == Self.proID } }
    var trial: Product? { products.first { $0.id == Self.trialID } }

    func start() async {
        guard !isolated, !started else { return }
        started = true
        value = await vault.open(at: Date(), free: free)
        scheduleExpiry()
        guard !free else { return }
        listener = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { break }
                if case .verified(let transaction) = update {
                    await self?.apply(transaction)
                    await transaction.finish()
                }
            }
        }
        await refresh()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let end = value?.trialEnd, !free,
              let value, !value.purchasedPro, end > Date() else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
            catch { return }
            self?.objectWillChange.send()
        }
    }

    func load() async {
        guard !isolated, !free, products.isEmpty else { return }
        do {
            products = try await Product.products(for: [Self.proID, Self.trialID])
            if products.isEmpty { message = L.t("pay.unavailable") }
        } catch {
            message = L.t("pay.unavailable")
        }
    }

    private func apply(_ transaction: StoreKit.Transaction) async {
        guard var state = value else { return }
        switch transaction.productID {
        case Self.proID:
            state.purchasedPro = transaction.revocationDate == nil
        case Self.trialID where transaction.revocationDate == nil:
            state.applyTrial(originalPurchaseDate: transaction.originalPurchaseDate)
        default:
            return
        }
        value = state
        scheduleExpiry()
        await vault.save(state)
    }

    private func refresh() async {
        for id in [Self.proID, Self.trialID] {
            if case .verified(let transaction)? = await StoreKit.Transaction.latest(for: id) {
                await apply(transaction)
            }
        }
    }

    func buy(_ product: Product?) async {
        guard !busy, !free else { return }
        message = nil
        guard let product, !isolated else {
            message = L.t("pay.unavailable")
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await apply(transaction)
                await transaction.finish()
                message = L.t("pay.completed")
            case .success(.unverified):
                message = L.t("pay.failed")
            case .pending:
                message = L.t("pay.pending")
            case .userCancelled:
                break
            @unknown default:
                message = L.t("pay.failed")
            }
        } catch {
            message = L.t("pay.failed")
        }
    }

    func restore() async {
        guard !busy, !free else { return }
        guard !isolated else {
            message = L.t("pay.none")
            return
        }
        busy = true
        defer { busy = false }
        message = nil
        do {
            try await AppStore.sync()
            await refresh()
            message = value?.purchasedPro == true || value?.trialClaimedAt != nil ? L.t("pay.restored") : L.t("pay.none")
        } catch {
            message = L.t("pay.restoreFailed")
        }
    }
}
