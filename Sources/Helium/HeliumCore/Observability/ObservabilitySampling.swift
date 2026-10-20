import Foundation

struct ObservabilitySampling {
    static let fallbackBundleRate = 0.02

    static func isSelected(persistentId: String, rate: Double) -> Bool {
        guard rate > 0 else { return false }
        guard rate < 1 else { return true }
        let tail = persistentId.replacingOccurrences(of: "-", with: "").suffix(8)
        guard let value = UInt32(tail, radix: 16) else { return true }
        return Double(value % 10_000) < rate * 10_000
    }

    static func includesThisDevice(
        rate: Double,
        isProduction: Bool = AppReceiptsHelper.shared.environment == .production,
        persistentId: String = HeliumIdentityManager.shared.getHeliumPersistentId()
    ) -> Bool {
        !isProduction || isSelected(persistentId: persistentId, rate: rate)
    }
}
