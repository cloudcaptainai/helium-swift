import Foundation

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

/// Configuration for SDK identification, used by wrapper SDKs (React Native, Flutter) to identify themselves.
public class HeliumSdkConfig {
    public static let shared = HeliumSdkConfig()
    private init() {}

    // Private storage for wrapper SDK info
    private var wrapperSdk: String?
    private var wrapperSdkVersion: String?

    /// Called by wrapper SDKs (React Native, Flutter) before Helium.initialize()
    /// - Parameters:
    ///   - sdk: The wrapper SDK identifier (e.g., "react-native", "flutter")
    ///   - version: The wrapper SDK version
    public func setWrapperSdkInfo(sdk: String, version: String) {
        self.wrapperSdk = sdk
        self.wrapperSdkVersion = version
    }

    /// The platform identifier, always "ios" for this SDK
    var heliumPlatform: String {
        return "ios"
    }

    /// The SDK identifier - wrapper SDK name or "ios" for native
    var heliumSdk: String {
        return wrapperSdk ?? "ios"
    }

    /// The SDK version - wrapper SDK version or native SDK version
    var heliumSdkVersion: String {
        return wrapperSdkVersion ?? BuildConstants.version
    }

    /// The native SDK version, always the Swift SDK version
    var heliumNativeSdkVersion: String {
        return BuildConstants.version
    }
}
