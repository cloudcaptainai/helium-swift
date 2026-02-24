//
//  ThirdPartyEntitlementsSource.swift
//  helium-swift
//

/// A protocol for third-party entitlement providers to integrate
/// with `HeliumEntitlementsManager`. The manager queries this source alongside
/// StoreKit using OR-logic: the user is entitled if StoreKit OR the third-party
/// source says so.
///
/// Implementations handle their own caching and persistence.
public protocol ThirdPartyEntitlementsSource: AnyObject, Sendable {

    /// Returns a set of all purchased product IDs that the user currently has access to.
    func purchasedHeliumProductIds() async -> Set<String>
    
    /// Product IDs the user is currently entitled to, whether through direct purchase or otherwise.
    func entitledProductIds() async -> Set<String>

    /// Whether the user has any active subscription from this source.
    func hasAnyActiveSubscription() async -> Bool
    
    /// Returns a set of active subscriptions by product ID.
    func activeSubscriptions() async -> Set<String>
}
