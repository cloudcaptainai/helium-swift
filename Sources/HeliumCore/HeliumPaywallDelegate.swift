//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/19/24.
//

import Foundation
import Segment
import StoreKit


public enum HeliumPaywallTransactionStatus {
    case purchased
    case cancelled
    case failed(Error)
    case restored
    case pending
}

public protocol HeliumPaywallDelegate: AnyObject {
    
    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus
    
    func onHeliumPaywallEvent(event: HeliumPaywallEvent)
}

// Extension to provide default implementation
public extension HeliumPaywallDelegate {
    func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        // Default implementation does nothing
    }
}

public class HeliumPaywallDelegateWrapper: ObservableObject {
    
    public static let shared = HeliumPaywallDelegateWrapper()
    
    private var delegate: HeliumPaywallDelegate?
    private var analytics: Analytics?
    private var isAnalyticsEnabled: Bool = true
    
    public func setDelegate(_ delegate: HeliumPaywallDelegate) {
        self.delegate = delegate
    }
    
    public func setAnalytics(_ analytics: Analytics) {
        self.analytics = analytics
    }
    
    public func getAnalytics() -> Analytics? {
        return analytics;
    }
    
    public func setIsAnalyticsEnabled(shouldEnable: Bool) {
        isAnalyticsEnabled = shouldEnable;
    }
    
    public func getIsAnalyticsEnabled() -> Bool {
        return isAnalyticsEnabled;
    }
    
    public func handlePurchase(productKey: String, triggerName: String, paywallTemplateName: String) async -> HeliumPaywallTransactionStatus? {
        let transactionStatus = await delegate?.makePurchase(productId: productKey);
        switch transactionStatus {
            case .cancelled:
                self.onHeliumPaywallEvent(event: .subscriptionCancelled(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            case .failed(let error):
                self.onHeliumPaywallEvent(event: .subscriptionFailed(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName, error: error.localizedDescription))
            case .restored:
                self.onHeliumPaywallEvent(event: .subscriptionRestored(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            case .purchased:
                self.onHeliumPaywallEvent(event: .subscriptionSucceeded(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            case .pending:
                self.onHeliumPaywallEvent(event: .subscriptionPending(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            default:
                break
        }
        return transactionStatus;
    }
    
    
    public func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        do {
            delegate?.onHeliumPaywallEvent(event: event);
            if (isAnalyticsEnabled && analytics != nil) {
                var experimentID: String? = nil;
                var paywallInfo: HeliumPaywallInfo? = nil;
                var isFallback = false;
                if let triggerName = event.getTriggerIfExists() {
                    experimentID = HeliumFetchedConfigManager.shared.getExperimentIDForTrigger(triggerName);
                    paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(triggerName);
                    if (paywallInfo == nil) {
                        isFallback = true;
                    } else {
                        isFallback = paywallInfo?.paywallTemplateName == "Fallback";
                    }
                }
                
                let fetchedConfigId = HeliumFetchedConfigManager.shared.getConfigId();
                let eventForLogging = HeliumPaywallLoggedEvent(
                    heliumEvent: event,
                    fetchedConfigId: fetchedConfigId,
                    timestamp: formatAsTimestamp(date: Date()),
                    experimentID: experimentID,
                    paywallID: paywallInfo?.paywallID,
                    heliumPersistentID: HeliumIdentityManager.shared.getHeliumPersistentId(),
                    heliumSessionID: HeliumIdentityManager.shared.getHeliumSessionId(),
                    isFallback: isFallback,
                    downloadStatus: HeliumFetchedConfigManager.shared.downloadStatus,
                    imageDownloadStatus: HeliumAssetManager.shared.imageStatus,
                    fontsDownloadStatus: HeliumAssetManager.shared.fontStatus
                );
                
                analytics?.track(name: "helium_" + event.caseString(), properties: eventForLogging);
            }
        } catch {
            print("Delegate action failed.");
        }
    }
}
