import Foundation

// MARK: - Cached Snapshot

private struct CachedSnapshot {
    let products: [ProductEntitlement]
    let refreshAfter: Date

    var needsRefresh: Bool { Date() > refreshAfter }

    var activeHeliumProductIds: Set<String> {
        Set(products.filter { $0.isActive }.map { $0.heliumProductId })
    }

    var activeSubscriptionProductIds: Set<String> {
        Set(products.filter { $0.subscriptionExpiresAt != nil && $0.isActive }.map { $0.heliumProductId })
    }
}

// MARK: - HeliumPaymentEntitlementsSource

open class HeliumPaymentEntitlementsSource: ThirdPartyEntitlementsSource, @unchecked Sendable {

    let provider: PaymentProviderConfig

    private let lock = NSLock()
    private var cached: CachedSnapshot?
    private var persisted: [ProductEntitlement] = []
    private var currentFetchTask: Task<Void, Never>?
    private var fetchId: UInt = 0

    private static let cacheTTL: TimeInterval = 60 * 60

    init(provider: PaymentProviderConfig) {
        self.provider = provider
    }

    private(set) var isConfigured = false
    func configure() {
        let shouldConfigure: Bool = lock.withLock {
            guard !isConfigured else { return false }
            isConfigured = true
            return true
        }
        guard shouldConfigure else { return }
        loadPersistedData()
        Task { await fetchFromServer() }
    }

    // MARK: - ThirdPartyEntitlementsSource

    open func purchasedHeliumProductIds() async -> Set<String> {
        await refreshIfNeeded()
        return lock.withLock { currentHeliumProductIds }
    }

    open func hasAnyActiveSubscription() async -> Bool {
        await refreshIfNeeded()
        return lock.withLock { !currentSubscriptionHeliumProductIds.isEmpty }
    }

    open func activeSubscriptions() async -> Set<String> {
        await refreshIfNeeded()
        return lock.withLock { currentSubscriptionHeliumProductIds }
    }

    open func refreshEntitlements() async {
        await fetchFromServer(forceNew: true)
    }

    open func didCompletePurchase(productId: String, priceId: String?, subscriptionExpiresAt: Date?) {
        guard !productId.isEmpty else { return }

        let newEntitlement = ProductEntitlement(
            productId: productId,
            priceId: priceId,
            subscriptionExpiresAt: subscriptionExpiresAt
        )
        lock.withLock {
            currentFetchTask?.cancel()
            currentFetchTask = nil
            var products = cached?.products ?? persisted
            products.removeAll { $0.productId == productId }
            products.append(newEntitlement)
            cached = CachedSnapshot(
                products: products,
                refreshAfter: Date().addingTimeInterval(Self.cacheTTL)
            )
            persisted = products
        }
        persistData()
    }

    open func clearEntitlements() {
        lock.withLock {
            currentFetchTask?.cancel()
            currentFetchTask = nil
            cached = nil
            persisted = []
        }
        if let fileURL = persistenceFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Private

    private var currentHeliumProductIds: Set<String> {
        if let cached {
            return cached.activeHeliumProductIds
        }
        return Set(persisted.filter { $0.isActive }.map { $0.heliumProductId })
    }

    private var currentSubscriptionHeliumProductIds: Set<String> {
        if let cached {
            return cached.activeSubscriptionProductIds
        }
        return Set(persisted.filter { $0.subscriptionExpiresAt != nil && $0.isActive }.map { $0.heliumProductId })
    }

    private func refreshIfNeeded() async {
        let needsRefresh: Bool = lock.withLock {
            guard let cached else { return true }
            return cached.needsRefresh
        }
        if needsRefresh {
            await fetchFromServer()
        }
    }

    private func fetchFromServer(forceNew: Bool = false) async {
        let (task, myId): (Task<Void, Never>, UInt) = lock.withLock {
            if !forceNew, let existing = currentFetchTask {
                return (existing, fetchId)
            }
            currentFetchTask?.cancel()
            fetchId += 1
            let id = fetchId
            let t = Task { [self] in await performFetch() }
            currentFetchTask = t
            return (t, id)
        }
        await task.value
        lock.withLock {
            if fetchId == myId {
                currentFetchTask = nil
            }
        }
    }

    private func performFetch() async {
        do {
            let body = try HeliumPaymentAPIClient.shared.baseRequestBody(provider: provider)
            let response: PaymentEntitlementResponse = try await HeliumPaymentAPIClient.shared.post(provider.checkEntitlementPath, body: body)

            guard !Task.isCancelled else { return }

            if let customerId = response.customerId, !customerId.isEmpty {
                provider.setCustomerId(customerId)
            }

            let activeSubscriptions = response.subscriptions.filter { $0.isActive }

            let productEntitlements: [ProductEntitlement] = activeSubscriptions.map { sub in
                let dateString = sub.currentPeriodEnd ?? sub.trialEnd ?? sub.trialEndsAt
                let expiresAt = parseISODate(dateString)
                return ProductEntitlement(productId: sub.productId, priceId: sub.priceId, subscriptionExpiresAt: expiresAt)
            }

            lock.withLock {
                cached = CachedSnapshot(
                    products: productEntitlements,
                    refreshAfter: Date().addingTimeInterval(Self.cacheTTL)
                )
                persisted = productEntitlements
            }
            persistData()
        } catch {
            // Silently fail — cached/persisted data remains available
        }
    }

    // MARK: - Persistence

    private var persistenceFileURL: URL? {
        heliumAppSupportDirectory?.appendingPathComponent(provider.entitlementsPersistenceFileName)
    }

    private func loadPersistedData() {
        guard let fileURL = persistenceFileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedPaymentEntitlements.self, from: data) else {
            return
        }
        let active = decoded.products.filter { $0.isActive }
        lock.withLock {
            persisted = active
        }
    }

    private func persistData() {
        guard let fileURL = persistenceFileURL else { return }

        let encoded: Data? = lock.withLock {
            let snapshot = PersistedPaymentEntitlements(products: persisted)
            return try? JSONEncoder().encode(snapshot)
        }
        guard let encoded else { return }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // Silently fail
        }
    }
}

// MARK: - Provider-specific implementations

public class StripeEntitlementsSource: HeliumPaymentEntitlementsSource {
    public init() {
        super.init(provider: .stripe)
    }
}

public class PaddleEntitlementsSource: HeliumPaymentEntitlementsSource {
    public init() {
        super.init(provider: .paddle)
    }
}
