import Foundation
import Security

struct Entitlement: Codable, Equatable {
    var firstOpen = Date()
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let local = proStartedAt ?? firstOpen
        return min(local, trialClaimedAt ?? local)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    mutating func startPaidPeriod(at now: Date, free: Bool) {
        if !free && proStartedAt == nil { proStartedAt = now }
    }

    mutating func applyTrial(originalPurchaseDate: Date) {
        trialClaimedAt = min(trialClaimedAt ?? originalPurchaseDate, originalPurchaseDate)
    }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart.addingTimeInterval(-600) && now < trialEnd)
    }
}

actor EntitlementVault {
    private let key = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.hgsldswk.photokb.entitlements",
        kSecAttrAccount as String: "local"
    ]

    func open(at now: Date, free: Bool) -> Entitlement {
        var query: [String: Any] = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        SecItemCopyMatching(query as CFDictionary, &result)
        let stored = (result as? Data).flatMap { try? JSONDecoder().decode(Entitlement.self, from: $0) }
        var value = stored ?? Entitlement(firstOpen: now)
        value.startPaidPeriod(at: now, free: free)
        save(value)
        return value
    }

    func save(_ value: Entitlement) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item: [String: Any] = key
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
