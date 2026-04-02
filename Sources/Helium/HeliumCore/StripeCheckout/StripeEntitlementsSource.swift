import Foundation

// MARK: - API Response Types

struct StripeEntitlementResponse: Codable, Sendable {
    let hasActiveEntitlement: Bool
    let subscriptions: [StripeSubscriptionInfo]
    let customerId: String?
}

struct StripeSubscriptionInfo: Codable, Sendable {
    let subscriptionId: String
    let productId: String
    let status: String
    let priceId: String?
    let productName: String?
    let productDescription: String?
    let currentPeriodEnd: String?
    let cancelAtPeriodEnd: Bool?
    let trialEnd: String?

    var isActive: Bool {
        ["active", "trialing"].contains(status)
    }
}

// MARK: - Snapshots

/// A product entitlement with its subscription expiration date.
private struct ProductEntitlement: Codable {
    let productId: String
    let priceId: String?
    /// When the subscription period actually ends (from Stripe's currentPeriodEnd/trialEnd).
    /// Nil for one-time purchases (permanent entitlement).
    let subscriptionExpiresAt: Date?

    var isActive: Bool {
        guard let subscriptionExpiresAt else { return true }
        return Date() < subscriptionExpiresAt
    }

    var heliumProductId: String {
        if let priceId { return "\(productId):\(priceId)" }
        return productId
    }
}

/// In-memory cache from the latest server fetch.
private struct CachedSnapshot {
    let products: [ProductEntitlement]
    /// TTL — when to re-fetch from the server. Independent of per-product expiration.
    let refreshAfter: Date

    var needsRefresh: Bool { Date() > refreshAfter }

    var activeProductIds: Set<String> {
        Set(products.filter { $0.isActive }.map { $0.productId })
    }

    var activeHeliumProductIds: Set<String> {
        Set(products.filter { $0.isActive }.map { $0.heliumProductId })
    }

    var activeSubscriptionProductIds: Set<String> {
        Set(products.filter { $0.subscriptionExpiresAt != nil && $0.isActive }.map { $0.productId })
    }
}

private struct PersistedStripeEntitlements: Codable {
    let products: [ProductEntitlement]
}

// MARK: - StripeEntitlementsSource

open class StripeEntitlementsSource: ThirdPartyEntitlementsSource, @unchecked Sendable {

    private let lock = NSLock()

    /// Authoritative once set — populated by a successful server fetch.
    private var cached: CachedSnapshot?
    /// Cold-start backup — loaded from disk, used only until first fetch completes.
    private var persisted: [ProductEntitlement] = []
    /// Tracks the in-flight fetch so concurrent callers coalesce onto one request.
    private var currentFetchTask: Task<Void, Never>?
    private var fetchId: UInt = 0

    private static let cacheTTL: TimeInterval = 60 * 60 // 60 minutes

    private static let persistenceFileName = "helium_stripe_entitlements.json"

    public init() {}

    func configure() {
        loadPersistedData()
        Task { await fetchFromServer() }
    }

    // MARK: - ThirdPartyEntitlementsSource

    open func purchasedHeliumProductIds() async -> Set<String> {
        await refreshIfNeeded()
        return lock.withLock { currentHeliumProductIds }
    }

    open func entitledProductIds() async -> Set<String> {
        await refreshIfNeeded()
        return lock.withLock { currentProductIds }
    }

    open func hasAnyActiveSubscription() async -> Bool {
        await refreshIfNeeded()
        return lock.withLock { !currentSubscriptionProductIds.isEmpty }
    }

    open func activeSubscriptions() async -> Set<String> {
        await refreshIfNeeded()
        return lock.withLock { currentSubscriptionProductIds }
    }

    open func refreshEntitlements() async {
        await fetchFromServer(forceNew: true)
    }

    open func didCompletePurchase(heliumProductId: String, subscriptionExpiresAt: Date?) {
        guard !heliumProductId.isEmpty else { return }
        let parts = heliumProductId.split(separator: ":", maxSplits: 1)
        guard !parts.isEmpty else { return }
        let productId = String(parts[0])
        let priceId: String? = parts.count > 1 ? String(parts[1]) : nil

        let newEntitlement = ProductEntitlement(
            productId: productId,
            priceId: priceId,
            subscriptionExpiresAt: subscriptionExpiresAt
        )
        lock.withLock {
            var products = cached?.products ?? []
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

    /// Best available product IDs: cached (authoritative) > persisted.
    /// Both tiers filter by per-product subscription expiration.
    private var currentProductIds: Set<String> {
        if let cached {
            return cached.activeProductIds
        }
        return Set(persisted.filter { $0.isActive }.map { $0.productId })
    }

    private var currentHeliumProductIds: Set<String> {
        if let cached {
            return cached.activeHeliumProductIds
        }
        return Set(persisted.filter { $0.isActive }.map { $0.heliumProductId })
    }

    private var currentSubscriptionProductIds: Set<String> {
        if let cached {
            return cached.activeSubscriptionProductIds
        }
        return Set(persisted.filter { $0.subscriptionExpiresAt != nil && $0.isActive }.map { $0.productId })
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
            // If there's already an in-flight fetch, just await it.
            // Only force a new fetch when explicitly requested.
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
        // Clear the task ref so future calls (e.g. after cache TTL) create a new fetch.
        // Only clear if no newer fetch has replaced ours.
        lock.withLock {
            if fetchId == myId {
                currentFetchTask = nil
            }
        }
    }

    private func performFetch() async {
        let body = HeliumStripeAPIClient.shared.baseRequestBody()
        guard !body.isEmpty else { return }

        do {
            let response: StripeEntitlementResponse = try await HeliumStripeAPIClient.shared.post("stripe/check-entitlement", body: body)

            // If superseded by a newer fetch, discard this result
            guard !Task.isCancelled else { return }

            let activeSubscriptions = response.subscriptions.filter { $0.isActive }

            // Build per-product entries from subscription expiration dates
            let productEntitlements: [ProductEntitlement] = activeSubscriptions.map { sub in
                let dateString = sub.currentPeriodEnd ?? sub.trialEnd
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Helium", isDirectory: true)
            .appendingPathComponent(Self.persistenceFileName)
    }

    private func loadPersistedData() {
        guard let fileURL = persistenceFileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedStripeEntitlements.self, from: data) else {
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
            let snapshot = PersistedStripeEntitlements(products: persisted)
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
