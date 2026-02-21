import Foundation
import PassKit
import StoreKit

public class HeliumIdentityManager {
    // MARK: - Singleton
    public static let shared = HeliumIdentityManager()
    static func reset(clearUserTraits: Bool) {
        if clearUserTraits {
            shared.heliumUserTraits = HeliumUserTraits([:])
        }
        shared.heliumInitializeId = UUID().uuidString
    }
    private init() {
        // Check before anything is created to determine if this is a new user
        let hasExistingPersistentId = UserDefaults.standard.string(forKey: Self.heliumPersistentIdKey) != nil
        self.isFirstHeliumSession = !hasExistingPersistentId
        
        self.heliumSessionId = UUID().uuidString
        self.heliumInitializeId = UUID().uuidString
        self.heliumUserTraits = HeliumUserTraits([:])
    }
    
    // MARK: - Properties
    private let heliumSessionId: String
    private(set) var heliumInitializeId: String
    private var heliumUserTraits: HeliumUserTraits
    private(set) var isFirstHeliumSession: Bool = false
    
    // Used to connect StoreKit purchase events
    var appAttributionToken: UUID {
        if let customAppAccountToken {
            return customAppAccountToken
        }
        if let persistentIdAsUUID = UUID(uuidString: getHeliumPersistentId()) {
            return persistentIdAsUUID
        }
        // Persistent ID is always UUID -- not expected to get here
        return UUID()
    }
    private var customAppAccountToken: UUID? = nil
    // Used to connect RevenueCat purchase events
    var revenueCatAppUserId: String? = nil
    
    @HeliumAtomic private var _appTransactionID: String? = nil
    var appTransactionID: String? {
        get {
            return _appTransactionID ?? UserDefaults.standard.string(forKey: heliumAppTransactionIDKey)
        }
        set {
            if let newValue {
                _appTransactionID = newValue
                UserDefaults.standard.set(newValue, forKey: heliumAppTransactionIDKey)
            }
        }
    }
    
    // MARK: - Constants
    private let userContextKey = "heliumUserContext"
    private let heliumUserIdKey = "heliumUserId"
    private static let heliumPersistentIdKey = "heliumPersistentUserId"
    private let heliumFirstSeenDateKey = "heliumFirstSeenDate"
    private let heliumUserSeedKey = "heliumUserSeed"
    private let heliumHasCustomUserIdKey = "heliumHasCustomUserId"
    private let heliumStripeCustomerIdKey = "heliumStripeCustomerId"
    private let heliumAppTransactionIDKey = "heliumAppTransactionID"
    
    /// We may remove this at some point but for now it ensures a user id always set
    func getResolvedUserId() -> String {
        return getCustomUserId() ?? getHeliumPersistentId()
    }
    
    func hasCustomUserId() -> Bool {
        return UserDefaults.standard.bool(forKey: heliumHasCustomUserIdKey)
    }
    
    /// Returns the current user ID
    func getCustomUserId() -> String? {
        return UserDefaults.standard.string(forKey: heliumUserIdKey)
    }
    
    /// Sets a custom user ID
    /// - Parameter userId: The custom user ID to set
    func setCustomUserId(_ userId: String?) {
        if let userId {
            UserDefaults.standard.setValue(userId, forKey: heliumUserIdKey)
            UserDefaults.standard.setValue(true, forKey: heliumHasCustomUserIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: heliumUserIdKey)
            UserDefaults.standard.removeObject(forKey: heliumHasCustomUserIdKey)
        }
    }
    
    func setCustomUserTraits(_ traits: HeliumUserTraits) {
        heliumUserTraits = traits
    }
    
    func addToCustomUserTraits(_ additionalTraits: HeliumUserTraits) {
        heliumUserTraits.merge(additionalTraits)
    }
    
    func getUserTraits() -> HeliumUserTraits {
        return heliumUserTraits
    }
    
    /// Creates or retrieves the Helium persistent ID
    /// - Returns: The Helium persistent ID
    public func getHeliumPersistentId() -> String {
        if let existingUserId = UserDefaults.standard.string(forKey: Self.heliumPersistentIdKey) {
            return existingUserId
        } else {
            let newUserId = UUID().uuidString
            UserDefaults.standard.setValue(newUserId, forKey: Self.heliumPersistentIdKey)
            return newUserId
        }
    }
    
    /// Gets the current session ID
    /// - Returns: The session ID for this instance
    public func getHeliumSessionId() -> String {
        return heliumSessionId
    }
    
    func setCustomAppAccountToken(_ token: UUID) {
        customAppAccountToken = token
    }
    
    func setRevenueCatAppUserId(_ rcAppUserId: String) {
        revenueCatAppUserId = rcAppUserId
    }
    
    public func setStripeCustomerId(_ customerId: String) {
        UserDefaults.standard.setValue(customerId, forKey: heliumStripeCustomerIdKey)
    }
    
    public func getStripeCustomerId() -> String? {
        return UserDefaults.standard.string(forKey: heliumStripeCustomerIdKey)
    }
    
    public func getAppTransactionID() -> String? {
        return appTransactionID
    }
    
    /// Gets or creates the Helium first seen date
    /// - Returns: The timestamp of when the user was first seen
    func getHeliumFirstSeenDate() -> String {
        if let existingDate = UserDefaults.standard.string(forKey: heliumFirstSeenDateKey) {
            return existingDate
        } else {
            let newDate = formatAsTimestamp(date: Date())
            UserDefaults.standard.setValue(newDate, forKey: heliumFirstSeenDateKey)
            return newDate
        }
    }
    
    /// Gets or creates the user seed (random value 1-100, persisted)
    /// Note that this has nothing to do with experiments, it just allows user to run their own targeting logic if desired.
    /// - Returns: The user seed value
    func getUserSeed() -> Int {
        if let existingSeed = UserDefaults.standard.object(forKey: heliumUserSeedKey) as? Int {
            return existingSeed
        } else {
            let newSeed = Int.random(in: 1...100)
            UserDefaults.standard.setValue(newSeed, forKey: heliumUserSeedKey)
            return newSeed
        }
    }
    
    /// Gets the current user context, creating it if necessary
    /// - Returns: The current user context
    public func getUserContext() -> CodableUserContext {
        let userContext = CodableUserContext.create(userTraits: self.heliumUserTraits)
        return userContext
    }
}

class AppStoreCountryHelper {
    static let shared = AppStoreCountryHelper()
    
    private let persistedCountryCode2Key = "heliumStoreCountryCode2"
    
    @HeliumAtomic private var cachedCountryCode3: String?  // Alpha-3 (e.g., "USA")
    @HeliumAtomic private var cachedCountryCode2: String?  // Alpha-2 (e.g., "US")
    @HeliumAtomic private var cachedStorefrontId: String?
    @HeliumAtomic private var cachedStorefrontCurrency: String?
    private var fetchTask: Task<String?, Never>?
    
    private init() {
        // Load persisted country code for immediate use
        cachedCountryCode2 = UserDefaults.standard.string(forKey: persistedCountryCode2Key)
        
        // Always refresh in background to stay current
        fetchTask = Task { await self.performFetch() }
    }
    
    private func performFetch() async -> String? {
        if let storefront = await Storefront.current {
            cachedCountryCode3 = storefront.countryCode
            cachedCountryCode2 = convertAlpha3ToAlpha2(storefront.countryCode)
            cachedStorefrontId = storefront.id
#if compiler(>=6.2)
            if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
                cachedStorefrontCurrency = storefront.currency?.identifier
            }
#endif
            // Persist country code for next launch
            UserDefaults.standard.set(cachedCountryCode2, forKey: persistedCountryCode2Key)
        }
        return cachedCountryCode2
    }
    
    /// Ensures the store country code is available (returns immediately if cached, otherwise awaits fetch)
    func fetchStoreCountryCode() async {
        if cachedCountryCode2 != nil {
            return
        }
        let _ = await fetchTask?.value
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

    /// Returns the cached storefront ID synchronously
    /// - Returns: The cached storefront ID, or nil if fetch not yet complete
    func getStorefrontId() -> String? {
        return cachedStorefrontId
    }

    /// Returns the cached storefront currency synchronously
    /// - Returns: The cached storefront currency identifier, or nil if fetch not yet complete or unavailable
    func getStorefrontCurrency() -> String? {
        return cachedStorefrontCurrency
    }
}

/// Configuration for SDK identification, used by wrapper SDKs (React Native, Flutter) to identify themselves.
public class HeliumSdkConfig {
    public static let shared = HeliumSdkConfig()
    
    // Private storage for wrapper SDK info
    @HeliumAtomic
    private var wrapperSdk: String?
    @HeliumAtomic
    private var wrapperSdkVersion: String?
    
    // Private storage for initialization config
    private(set) var purchaseDelegate: String = "unknown"
    // Note that this is not logged anywhere at the moment.
    private(set) var customAPIEndpoint: String?
    
    /// Called by wrapper SDKs (React Native, Flutter) before Helium.initialize()
    /// - Parameters:
    ///   - sdk: The wrapper SDK identifier (e.g., "react-native", "flutter")
    ///   - version: The wrapper SDK version
    public func setWrapperSdkInfo(sdk: String, version: String) {
        self.wrapperSdk = sdk
        self.wrapperSdkVersion = version
    }
    
    /// Called during Helium.initialize() to set initialization config
    func setInitializeConfig(purchaseDelegate: String, customAPIEndpoint: String?) {
        self.purchaseDelegate = purchaseDelegate
        self.customAPIEndpoint = customAPIEndpoint
    }
    
    /// The platform identifier, always "ios" for this SDK
    var heliumPlatform: String {
        return "ios"
    }
    
    /// The SDK identifier - wrapper SDK name or "ios" for native
    var heliumSdk: String {
        return wrapperSdk ?? "ios"
    }
    
    /// The native SDK version, always the Swift SDK version
    var heliumSdkVersion: String {
        return BuildConstants.version
    }
    
    /// The SDK version - wrapper SDK version or native SDK version
    var heliumWrapperSdkVersion: String {
        return wrapperSdkVersion ?? BuildConstants.version
    }
}

class ApplePayHelper {
    static let shared = ApplePayHelper()

    @HeliumAtomic private var cachedCanMakePayments: Bool?

    private init() {
        cachedCanMakePayments = PKPaymentAuthorizationController.canMakePayments()
    }

    /// Checks if the device supports Apple Pay (cached)
    func canMakePayments() -> Bool {
        return cachedCanMakePayments ?? PKPaymentAuthorizationController.canMakePayments()
    }
}

class LowPowerModeHelper {
    static let shared = LowPowerModeHelper()

    @HeliumAtomic private var cachedIsLowPowerMode: Bool?
    @HeliumAtomic private var lastFetchTime: Date?
    private let cacheDuration: TimeInterval = 10 * 60 // 10 minutes

    private init() {
        refreshCache()
    }

    private func refreshCache() {
        cachedIsLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        lastFetchTime = Date()
    }

    private func isCacheExpired() -> Bool {
        guard let lastFetch = lastFetchTime else { return true }
        return Date().timeIntervalSince(lastFetch) >= cacheDuration
    }

    /// Checks if the device is in low power mode (cached, refreshes every 10 minutes)
    func isLowPowerModeEnabled() -> Bool {
        if isCacheExpired() {
            refreshCache()
        }
        return cachedIsLowPowerMode ?? ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
