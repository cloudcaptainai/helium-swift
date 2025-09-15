import Foundation

public class HeliumIdentityManager {
    // MARK: - Singleton
    public static let shared = HeliumIdentityManager()
    private init() {
        self.heliumSessionId = UUID().uuidString
        self.heliumUserTraits = HeliumUserTraits([:]);
    }
    
    // MARK: - Properties
    private let heliumSessionId: String
    private var heliumUserTraits: HeliumUserTraits?
    private var heliumPaywallSessionId: String?
    
    private(set) var appAttributionToken: UUID = UUID() // Used to connect StoreKit purchase events with Helium paywall events
    private(set) var revenueCatAppUserId: String? = nil // Used to connect RevenueCat purchase events with Helium paywall events
    
    private var cachedUserContext: CodableUserContext? = nil
    
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
    
    /// Gets the current user context, creating it if necessary
    /// - Returns: The current user context
    public func getUserContext(
        skipDeviceCapacity: Bool = false,
        useCachedIfAvailable: Bool = false
    ) -> CodableUserContext {
        if useCachedIfAvailable, let cachedUserContext {
            return cachedUserContext
        }
        let userContext = CodableUserContext.create(userTraits: self.heliumUserTraits, skipDeviceCapacity: skipDeviceCapacity)
        cachedUserContext = userContext
        return userContext
    }
}
