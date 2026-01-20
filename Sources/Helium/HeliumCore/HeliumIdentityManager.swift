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
    
    // Used to connect StoreKit purchase events
    var appAttributionToken: UUID {
        if let customAppAttributionToken {
            return customAppAttributionToken
        }
        if let persistentIdAsUUID = UUID(uuidString: getHeliumPersistentId()) {
            return persistentIdAsUUID
        }
        return UUID()
    }
    private var customAppAttributionToken: UUID? = nil
    // Used to connect RevenueCat purchase events
    var revenueCatAppUserId: String? = nil
    
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
    
    func setCustomUserTraits(_ traits: HeliumUserTraits) {
        heliumUserTraits = traits
    }
    
    func addToCustomUserTraits(_ additionalTraits: HeliumUserTraits) {
        heliumUserTraits.merge(additionalTraits)
    }
    
    func getUserTraits() -> [String : Any] {
        return heliumUserTraits.dictionaryRepresentation
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
    
    func setCustomAppAttributionToken(_ token: UUID) {
        customAppAttributionToken = token
    }
    
    func setRevenueCatAppUserId(_ rcAppUserId: String?) {
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
    
    @HeliumAtomic private var cachedCountryCode3: String?  // Alpha-3 (e.g., "USA")
    @HeliumAtomic private var cachedCountryCode2: String?  // Alpha-2 (e.g., "US")
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
