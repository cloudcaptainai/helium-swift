//
//  ThirdPartyEntitlementsSource.swift
//  helium-swift
//

import Foundation

/// A protocol for third-party entitlement providers to integrate
/// with `HeliumEntitlementsManager`. The manager queries this source alongside
/// StoreKit using OR-logic: the user is entitled if StoreKit OR the third-party
/// source says so.
///
/// Implementations handle their own caching and persistence.
public protocol ThirdPartyEntitlementsSource: AnyObject, Sendable {

    /// Product IDs the user is currently entitled to.
    /// Implementation should return cached data when available.
    func entitledProductIds() async -> Set<String>

    /// Whether the user has any active subscription from this source.
    func hasAnyActiveSubscription() async -> Bool

    /// Notify the source that a purchase completed so it can update internal state.
    func didCompletePurchase(productId: String) async
}
