//
//  AppReceiptsHelper.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 7/30/25.
//

import StoreKit

class AppReceiptsHelper {
    
    static let shared = AppReceiptsHelper()
    
    private var appTransactionEnvironment: String? = nil
    private var setupCompleted: Bool = false
    
    func setUp() {
        if setupCompleted {
            return
        }
        setupCompleted = true
        if #available(iOS 16.0, *) {
            Task {
                let verificationResult = try? await AppTransaction.shared
                switch verificationResult {
                case .verified(let appTransaction):
                    // StoreKit verified that the user purchased this app and
                    // the properties in the AppTransaction instance.
                    switch appTransaction.environment {
                    case .xcode:
                        appTransactionEnvironment = "debug"
                    case .sandbox:
                        appTransactionEnvironment = "sandbox"
                    case .production:
                        appTransactionEnvironment = "production"
                    default:
                        break
                    }
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
    }
    
    func getEnvironment() -> String {
        #if DEBUG
        return "debug"
        #else
        if let appTransactionEnvironment {
            return appTransactionEnvironment
        }
        
        // Note, if supporting mac catalyst, watch os, etc in the future consider looking at RevenueCat sdk for how they handle these special cases.
        
        let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        if isTestFlight {
            return "sandbox"
        } else {
            #if targetEnvironment(simulator)
            return "sandbox"
            #else
            return "production"
            #endif
        }
        #endif
    }
    
}
