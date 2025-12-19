import Foundation
import StoreKit

public class HeliumIdentityManager {
    // MARK: - Singleton
    public static let shared = HeliumIdentityManager()
    static func reset(clearUserTraits: Bool) {
        if clearUserTraits {
            shared.heliumUserTraits = HeliumUserTraits([:])
        }
        shared.heliumInitializeId = UUID().uuidString
        shared.clearPaywallSessionId()
    }
    private init() {
        self.heliumSessionId = UUID().uuidString
        self.heliumInitializeId = UUID().uuidString
        self.heliumUserTraits = HeliumUserTraits([:]);
    }
    
    // MARK: - Properties
    private let heliumSessionId: String
    private(set) var heliumInitializeId: String
    private var heliumUserTraits: HeliumUserTraits
    private var heliumPaywallSessionId: String?
    
    private(set) var appAttributionToken: UUID = UUID() // Used to connect StoreKit purchase events with Helium paywall events
    private(set) var revenueCatAppUserId: String? = nil // Used to connect RevenueCat purchase events with Helium paywall events
    
    var appTransactionID: String? = nil
    
    // MARK: - Constants
    private let userContextKey = "heliumUserContext"
    private let heliumUserIdKey = "heliumUserId"
    private let heliumPersistentIdKey = "heliumPersistentUserId"
    
    // MARK: - Public Methods
    
    /// Gets the current user ID, creating one if it doesn't exist
    /// - Returns: The current user ID
    public func getUserId() -> String {
        if let existingUserId = UserDefaults.standard.string(forKey: heliumUserIdKey) {
            return existingUserId
        } else {
            let newUserId = UUID().uuidString
            UserDefaults.standard.setValue(newUserId, forKey: heliumUserIdKey)
            return newUserId
        }
    }
    
    /// Sets a custom user ID
    /// - Parameter userId: The custom user ID to set
    public func setCustomUserId(_ userId: String) {
        UserDefaults.standard.setValue(userId, forKey: heliumUserIdKey)
    }
    
    public func setCustomUserTraits(traits: HeliumUserTraits) {
        self.heliumUserTraits = traits;
    }
    
    func setPaywallSessionId() {
        self.heliumPaywallSessionId = UUID().uuidString;
    }
    
    func clearPaywallSessionId() {
        self.heliumPaywallSessionId = nil
    }
    
    func getPaywallSessionId() -> String? {
        return self.heliumPaywallSessionId;
    }
    
    /// Creates or retrieves the Helium persistent ID
    /// - Returns: The Helium persistent ID
    public func getHeliumPersistentId() -> String {
        if let existingUserId = UserDefaults.standard.string(forKey: heliumPersistentIdKey) {
            return existingUserId
        } else {
            let newUserId = UUID().uuidString
            UserDefaults.standard.setValue(newUserId, forKey: heliumPersistentIdKey)
            return newUserId
        }
    }
    
    /// Gets the current session ID
    /// - Returns: The session ID for this instance
    public func getHeliumSessionId() -> String {
        return heliumSessionId
    }
    
    func setDefaultAppAttributionToken() {
        if let persistentIdUUID = UUID(uuidString: getHeliumPersistentId()) { // this should always be successful
            appAttributionToken = persistentIdUUID
        }
    }
    func setCustomAppAttributionToken(_ token: UUID) {
        appAttributionToken = token
    }
    
    func setRevenueCatAppUserId(_ rcAppUserId: String) {
        revenueCatAppUserId = rcAppUserId
    }
    
    public func getAppTransactionID() -> String? {
        return appTransactionID
    }
    
    /// Gets the current user context, creating it if necessary
    /// - Returns: The current user context
    public func getUserContext(
        skipDeviceCapacity: Bool = false
    ) -> CodableUserContext {
        let userContext = CodableUserContext.create(userTraits: self.heliumUserTraits, skipDeviceCapacity: skipDeviceCapacity)
        return userContext
    }
}

class AppStoreCountryHelper {
    static let shared = AppStoreCountryHelper()
    
    private var cachedCountryCode3: String?  // Alpha-3 (e.g., "USA")
    private var cachedCountryCode2: String?  // Alpha-2 (e.g., "US")
    private var fetchTask: Task<String?, Never>?
    
    private init() {
        fetchTask = Task { await self.performFetch() }
    }
    
    private func performFetch() async -> String? {
        if let alpha3 = await Storefront.current?.countryCode {
            cachedCountryCode3 = alpha3
            cachedCountryCode2 = convertAlpha3ToAlpha2(alpha3)
        }
        return cachedCountryCode2
    }
    
    /// Awaits the fetch task and returns the 2-char alpha-2 country code
    /// - Returns: The 2-char country code (e.g., "US", "GB"), or nil if unavailable
    func fetchStoreCountryCode() async -> String? {
        return await fetchTask?.value
    }
    
    /// Returns the cached 2-char store country code synchronously
    /// - Returns: The cached alpha-2 country code, or nil if fetch not yet complete
    func getStoreCountryCode() -> String? {
        return cachedCountryCode2
    }
    
    /// Returns the cached 3-char store country code synchronously
    /// - Returns: The cached alpha-3 country code, or nil if fetch not yet complete
    func getStoreCountryCode3() -> String? {
        return cachedCountryCode3
    }
}
