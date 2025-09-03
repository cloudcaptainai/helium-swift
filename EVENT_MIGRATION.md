# Event Migration Guide: v1 to v2

This guide helps you migrate from the legacy enum-based event system to the new type-safe, protocol-based event system in Helium SDK.

## Overview

The v2 event system provides:
- **Type safety** with strongly-typed event structs
- **Better IDE support** with autocomplete for event properties
- **Cleaner code** without massive switch statements
- **Full backward compatibility** during migration

## Key Changes

### 1. Event Structure
- **v1**: Single enum with associated values
- **v2**: Individual structs conforming to `PaywallEvent` protocol

### 2. Property Names
- `paywallTemplateName` → `paywallName`
- `productKey` → `productId`
- All `subscription*` events → `purchase*` events
- Removed `ctaPressed` event
- Removed `configId` from download success events
- `error` is now `Error` type instead of `String`

### 3. Delegate Methods
- **v1**: `onHeliumPaywallEvent(event:)` (deprecated)
- **v2**: `onPaywallEvent(_:)` (recommended)

## Migration Steps

### Step 1: Update Your Delegate Implementation

#### Before (v1):
```swift
class MyPaywallDelegate: HeliumPaywallDelegate {
    func onHeliumPaywallEvent(event: HeliumPaywallEvent) {
        switch event {
        case .paywallOpen(let trigger, let template, let viewType):
            print("Paywall opened: \(template)")
            analytics.track("paywall_open", properties: [
                "trigger": trigger,
                "template": template,
                "viewType": viewType
            ])
            
        case .subscriptionSucceeded(let productKey, let trigger, let template):
            print("Subscription successful: \(productKey)")
            updateSubscription(productKey)
            
        case .subscriptionFailed(let productKey, let trigger, let template, let error):
            if let error = error {
                showError(error)
            }
            
        default:
            break
        }
    }
}
```

#### After (v2):
```swift
class MyPaywallDelegate: HeliumPaywallDelegate {
    func onPaywallEvent(_ event: PaywallEvent) {
        // Type-safe event handling
        switch event {
        case let openEvent as PaywallOpenEvent:
            print("Paywall opened: \(openEvent.paywallName)")
            analytics.track("paywall_open", properties: openEvent.toDictionary())
            
        case let successEvent as PurchaseSucceededEvent:
            print("Purchase successful: \(successEvent.productId)")
            updateSubscription(successEvent.productId)
            
        case let failedEvent as PurchaseFailedEvent:
            if let error = failedEvent.error {
                showError(error.localizedDescription)
            }
            
        default:
            break
        }
    }
    
    // Remove the old method once migration is complete
    // func onHeliumPaywallEvent(event: HeliumPaywallEvent) { }
}
```

### Step 2: Leverage Protocol Conformance

The v2 system uses protocols for common event patterns:

```swift
func onPaywallEvent(_ event: PaywallEvent) {
    // Handle all events with paywall context
    if let contextEvent = event as? PaywallContextEvent {
        trackPaywallMetrics(
            trigger: contextEvent.triggerName,
            paywall: contextEvent.paywallName
        )
    }
    
    // Handle all product-related events
    if let productEvent = event as? ProductEvent {
        validateProduct(productId: productEvent.productId)
    }
    
    // Direct property access (no switch needed)
    print("Event: \(event.eventName) at \(event.timestamp)")
}
```

### Step 3: Creating Events (SDK Internal Use)

If you're creating events directly:

#### Before (v1):
```swift
HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(
    event: .paywallOpen(
        triggerName: "premium",
        paywallTemplateName: "PremiumPaywall",
        viewType: "presented"
    )
)
```

#### After (v2):
```swift
let event = PaywallOpenEvent(
    triggerName: "premium",
    paywallName: "PremiumPaywall",
    viewType: .presented
)
HeliumPaywallDelegateWrapper.shared.fireEvent(event)
```

## Event Mapping Reference

| v1 Event | v2 Event | Changes |
|----------|----------|---------|
| `.paywallOpen(triggerName, paywallTemplateName, viewType)` | `PaywallOpenEvent` | `paywallTemplateName` → `paywallName` |
| `.paywallClose(triggerName, paywallTemplateName)` | `PaywallCloseEvent` | `paywallTemplateName` → `paywallName` |
| `.subscriptionPressed(productKey, triggerName, paywallTemplateName)` | `PurchasePressedEvent` | `productKey` → `productId`, `paywallTemplateName` → `paywallName`, event renamed |
| `.subscriptionSucceeded(productKey, triggerName, paywallTemplateName)` | `PurchaseSucceededEvent` | `productKey` → `productId`, `paywallTemplateName` → `paywallName`, event renamed |
| `.subscriptionFailed(productKey, triggerName, paywallTemplateName, error)` | `PurchaseFailedEvent` | `productKey` → `productId`, `paywallTemplateName` → `paywallName`, `error: String?` → `error: Error?`, event renamed |
| `.subscriptionCancelled(productKey, triggerName, paywallTemplateName)` | `PurchaseCancelledEvent` | `productKey` → `productId`, `paywallTemplateName` → `paywallName`, event renamed |
| `.subscriptionRestored(productKey, triggerName, paywallTemplateName)` | `PurchaseRestoredEvent` | `productKey` → `productId`, `paywallTemplateName` → `paywallName`, event renamed |
| `.subscriptionPending(productKey, triggerName, paywallTemplateName)` | `PurchasePendingEvent` | `productKey` → `productId`, `paywallTemplateName` → `paywallName`, event renamed |
| `.paywallDismissed(triggerName, paywallTemplateName, dismissAll)` | `PaywallDismissedEvent` | `paywallTemplateName` → `paywallName` |
| `.paywallOpenFailed(triggerName, paywallTemplateName)` | `PaywallOpenFailedEvent` | `paywallTemplateName` → `paywallName` |
| `.paywallSkipped(triggerName)` | `PaywallSkippedEvent` | No changes |
| `.paywallsDownloadSuccess(configId, ...)` | `PaywallsDownloadSuccessEvent` | Removed `configId` |
| `.paywallsDownloadError(error, numAttempts)` | `PaywallsDownloadErrorEvent` | No changes |
| `.paywallWebViewRendered(...)` | `PaywallWebViewRenderedEvent` | `paywallTemplateName` → `paywallName` |
| `.ctaPressed(...)` | **Removed** | No longer supported |
| `.initializeStart` | `InitializeStartEvent` | No changes |
| `.offerSelected(productKey, triggerName, paywallTemplateName)` | `ProductSelectedEvent` | `productKey` → `productId`, `paywallTemplateName` → `paywallName`, event renamed |
| `.subscriptionRestoreFailed(triggerName, paywallTemplateName)` | `PurchaseRestoreFailedEvent` | `paywallTemplateName` → `paywallName`, event renamed |

## Gradual Migration

The SDK supports both event systems simultaneously, allowing gradual migration:

1. **Phase 1**: Implement the new `onPaywallEvent(_:)` method alongside your existing `onHeliumPaywallEvent(event:)`
2. **Phase 2**: Test and verify the new implementation
3. **Phase 3**: Remove the old `onHeliumPaywallEvent(event:)` method

**Important**: During migration, both methods may be called. The new `onPaywallEvent(_:)` is called for v2 events, while `onHeliumPaywallEvent(event:)` is still called for legacy events fired from parts of the SDK not yet migrated. To avoid duplicate handling, you should implement your logic in only one method during the transition period.

## Benefits After Migration

- **Compile-time safety**: Catch event property typos at compile time
- **Better autocomplete**: IDE knows all available properties
- **Cleaner code**: No need for complex switch statements to extract values
- **Easier testing**: Create test events without dealing with enum syntax
- **Future-proof**: New events are just new structs, no enum modifications

## Example: Complete Migration

```swift
// Complete v2 implementation
class ModernPaywallDelegate: HeliumPaywallDelegate {
    
    func makePurchase(productId: String) async -> HeliumPaywallTransactionStatus {
        // Your implementation
        return .purchased
    }
    
    func restorePurchases() async -> Bool {
        return false
    }
    
    func onPaywallEvent(_ event: PaywallEvent) {
        // Log all events
        logger.log(event.eventName, metadata: event.toDictionary())
        
        // Handle specific events with type safety
        switch event {
        case let open as PaywallOpenEvent:
            handlePaywallOpen(open)
            
        case let success as PurchaseSucceededEvent:
            handlePurchaseSuccess(success)
            
        case let failed as PurchaseFailedEvent:
            handlePurchaseFailure(failed)
            
        default:
            // Handle other events or ignore
            break
        }
    }
    
    private func handlePaywallOpen(_ event: PaywallOpenEvent) {
        // Direct property access - no unwrapping needed
        analytics.track("paywall_open", [
            "trigger": event.triggerName,
            "paywall": event.paywallName,
            "viewType": event.viewType.rawValue,
            "timestamp": event.timestamp
        ])
    }
    
    private func handlePurchaseSuccess(_ event: PurchaseSucceededEvent) {
        // Type-safe access to all properties
        userDefaults.set(event.productId, forKey: "active_subscription")
        notificationCenter.post(
            name: .subscriptionActivated,
            object: nil,
            userInfo: ["productId": event.productId]
        )
    }
    
    private func handlePurchaseFailure(_ event: PurchaseFailedEvent) {
        // Error is now a proper Error object
        if let error = event.error {
            errorReporter.report(error, context: [
                "productId": event.productId,
                "trigger": event.triggerName
            ])
        }
    }
}
```

## Questions?

If you have questions about the migration, please:
1. Check the `PaywallEvents.swift` file for complete event definitions
2. Review the protocol hierarchy (`PaywallEvent`, `PaywallContextEvent`, `ProductEvent`)
3. Contact support at founders@tryhelium.com
