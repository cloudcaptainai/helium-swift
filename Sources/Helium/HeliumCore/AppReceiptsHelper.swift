//
//  AppReceiptsHelper.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 7/30/25.
//

import StoreKit

class AppReceiptsHelper {

    enum Environment: String {
        case debug = "debug"
        case sandbox = "sandbox"
        case production = "production"
    }
    
    static let shared = AppReceiptsHelper()
    
    @HeliumAtomic private var appTransactionEnvironment: Environment? = nil
    @HeliumAtomic private var setupCompleted: Bool = false

    @HeliumAtomic private var appFirstInstallTime: Date? = nil
    @HeliumAtomic private var latestInstallTime: Date? = nil
    private let firstInstallTimeKey = "heliumFirstInstallTime"

    func setUp() {
        // Test-and-set so concurrent callers run the body at most once.
        let alreadySetUp = _setupCompleted.withValue { value in
            if value { return true }
            value = true
            return false
        }
        if alreadySetUp {
            return
        }
        if Bundle.main.appStoreReceiptURL != nil {
            // AppTransaction.shared can trigger Apple account sign-in dialog in debug/sandbox
            // if not signed into a sandbox account, which is annoying for sdk integrators. So avoid
            // that call if can determine sandbox from receipt.
            if environment == .sandbox {
                return
            }
        }
#if !DEBUG && !targetEnvironment(simulator)
        if #available(iOS 16.0, *) {
            Task {
                let verificationResult = try? await AppTransaction.shared
                switch verificationResult {
                case .verified(let appTransaction):
                    // StoreKit verified that the user purchased this app and
                    // the properties in the AppTransaction instance.
                    switch appTransaction.environment {
                    case .xcode:
                        appTransactionEnvironment = .debug
                    case .sandbox:
                        appTransactionEnvironment = .sandbox
                    case .production:
                        appTransactionEnvironment = .production
                    default:
                        break
                    }
                    
                    // Extract first install time from originalPurchaseDate
                    appFirstInstallTime = appTransaction.originalPurchaseDate
                    // Only persist to UserDefaults for production
                    if appTransaction.environment == .production {
                        let formatter = ISO8601DateFormatter()
                        UserDefaults.standard.set(formatter.string(from: appTransaction.originalPurchaseDate), forKey: firstInstallTimeKey)
                    }
                    
#if compiler(>=6.2)
                    HeliumIdentityManager.shared.appTransactionID = appTransaction.appTransactionID
#endif
                case .unverified(let appTransaction, let verificationError):
                    // The app transaction didn't pass StoreKit's verification.
                    // Handle unverified app transaction information according
                    // to your business model.
                    break
                case .none:
                    break
                }
            }
        }
#endif
    }
    
    var environment: Environment {
#if DEBUG || targetEnvironment(simulator)
        return .debug
#else
        if let appTransactionEnvironment {
            return appTransactionEnvironment
        }

        // Note, if supporting mac catalyst, watch os, etc in the future consider looking at RevenueCat sdk for how they handle these special cases.

        let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        return isTestFlight ? .sandbox : .production
#endif
    }

    func getEnvironment() -> String {
        environment.rawValue
    }
    
    func getFirstInstallTime() -> Date? {
        // Return cached value if available (from AppTransaction)
        if let appFirstInstallTime {
            return appFirstInstallTime
        }
        // Check UserDefaults for persisted production value
        if let timestamp = UserDefaults.standard.string(forKey: firstInstallTimeKey) {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: timestamp) {
                return date
            }
        }
        // Backup: documents directory creation date
        return getDocumentsDirectoryCreationDate()
    }
    
    func getDocumentsDirectoryCreationDate() -> Date? {
        if let latestInstallTime {
            return latestInstallTime
        }
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: documentsURL.path)
        let creationDate = attributes?[.creationDate] as? Date
        latestInstallTime = creationDate
        return creationDate
    }

}
