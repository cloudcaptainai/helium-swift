//
//  ThirdPartyEntitlementsSource.swift
//  helium-swift
//

/// A protocol for third-party entitlement providers to integrate
/// with `HeliumEntitlementsManager`. The manager queries this source alongside
/// StoreKit using OR-logic: the user is entitled if StoreKit OR the third-party
/// source says so.
///
/// Implementations handle their own caching and persistence. Caching is highly recommended.
public protocol ThirdPartyEntitlementsSource: AnyObject, Sendable {

    /// Returns a set of all purchased product IDs that the user currently has access to.
    func purchasedHeliumProductIds() async -> Set<String>
    
    /// Whether the user has any active subscription from this source.
    func hasAnyActiveSubscription() async -> Bool
    
    /// Returns a set of active subscriptions by product ID.
    func activeSubscriptions() async -> Set<String>

    /// Called when the SDK's entitlement cache is invalidated (e.g. via `Helium.shared.invalidateEntitlementsCache()`).
    /// Implementations should clear any cached entitlement data so the next query fetches fresh state.
    func invalidateCache()
}
