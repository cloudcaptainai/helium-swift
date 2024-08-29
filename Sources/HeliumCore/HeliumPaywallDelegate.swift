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
    
    public func setDelegate(_ delegate: HeliumPaywallDelegate) {
        self.delegate = delegate
    }
    
    public func setAnalytics(_ analytics: Analytics) {
        self.analytics = analytics
    }
    
    public func handlePurchase(productKey: String, triggerName: String, paywallTemplateName: String, completion: @escaping (HeliumPaywallTransactionStatus?) -> Void) async {
        let transactionStatus = await delegate?.makePurchase(productId: productKey);
        switch transactionStatus {
            case .cancelled:
                self.onHeliumPaywallEvent(event: .subscriptionCancelled(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            case .failed(_):
                self.onHeliumPaywallEvent(event: .subscriptionFailed(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            case .restored:
                self.onHeliumPaywallEvent(event: .subscriptionRestored(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            case .purchased:
                self.onHeliumPaywallEvent(event: .subscriptionSucceeded(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            case .pending:
                self.onHeliumPaywallEvent(event: .subscriptionPending(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName))
            default:
                break
        }
        completion(transactionStatus);
    }
    
    
    public func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        delegate?.onHeliumPaywallEvent(event: event);
        let fetchedConfigId = HeliumFetchedConfigManager.shared.getConfigId();
        let eventForLogging = HeliumPaywallLoggedEvent(heliumEvent: event, fetchedConfigId: fetchedConfigId, timestamp: formatAsTimestamp(date: Date()))
        analytics?.track(name: event.caseString(), properties: eventForLogging)
    }
}
