import Foundation
import StoreKit

// Base price info shared across all product types
public struct BasePriceInfo: Codable {
    public let currency: String
    public let locale: String
    public let value: Decimal
    public let formattedPrice: String
    public let currencySymbol: String
    public let decimalSeparator: String
}

// Subscription specific info
public struct SubscriptionInfo: Codable {
    public let period: String
    public let introPrice: String?
    public let introPeriod: String?
    public let familyShareable: Bool
}

// IAP specific info (combines consumable and non-consumable)
public struct IAPInfo: Codable {
    public let quantity: Int
}

/// Represents a localized price with rich metadata
public struct LocalizedPrice: Codable {
    public let baseInfo: BasePriceInfo
    public let productType: String
    public let localizedTitle: String?
    public let localizedDescription: String?
    public let displayName: String?
    public let description: String?
    public let subscriptionInfo: SubscriptionInfo?
    public let iapInfo: IAPInfo?
    
    public var json: [String: Any] {
        var dict: [String: Any] = [
            "currency": baseInfo.currency,
            "locale": baseInfo.locale,
            "value": baseInfo.value,
            "formattedPrice": baseInfo.formattedPrice,
            "currencySymbol": baseInfo.currencySymbol,
            "decimalSeparator": baseInfo.decimalSeparator,
            "productType": productType
        ]
        
        if let title = localizedTitle {
            dict["localizedTitle"] = title
        }
        if let desc = localizedDescription {
            dict["localizedDescription"] = desc
        }
        if let name = displayName {
            dict["displayName"] = name
        }
        if let desc = description {
            dict["description"] = desc
        }
        
        // Add type-specific info
        if let subInfo = subscriptionInfo {
            var subDict: [String: Any] = [
                "period": subInfo.period,
                "familyShareable": subInfo.familyShareable
            ]
            if let intro = subInfo.introPrice {
                subDict["introPrice"] = intro
            }
            if let period = subInfo.introPeriod {
                subDict["introPeriod"] = period
            }
            dict["subscription"] = subDict
        }
        
        if let iapInfo = iapInfo {
            dict["iap"] = [
                "quantity": iapInfo.quantity
            ]
        }
        
        return dict
    }
}

/// A utility class for fetching localized pricing information for a given SKU
public class PriceFetcher {
    
    /// Fetches the localized price for multiple SKUs using async/await
    /// - Parameter skus: Array of product identifiers
    /// - Returns: Dictionary mapping SKUs to their localized price information
    @available(iOS 15.0, *) // StoreKit 2 is iOS 15+
    public static func localizedPricing(for skus: [String]) async -> [String: LocalizedPrice] {
        var priceMap: [String: LocalizedPrice] = [:]
        do {
            let products = try await Product.products(for: Set(skus))
            for product in products {
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.locale = product.priceFormatStyle.locale
                
                let baseInfo = BasePriceInfo(
                    currency: product.priceFormatStyle.currencyCode,
                    locale: product.priceFormatStyle.locale.identifier,
                    value: product.price,
                    formattedPrice: product.displayPrice,
                    currencySymbol: formatter.currencySymbol ?? "$",
                    decimalSeparator: formatter.currencyDecimalSeparator ?? "."
                )
                
                var subscriptionInfo: SubscriptionInfo?
                var iapInfo: IAPInfo?
                
                // Handle different product types
                if let sub = product.subscription {
                    let unitString: String
                    switch sub.subscriptionPeriod.unit {
                    case .day:
                        unitString = "day"
                    case .week:
                        unitString = "week"
                    case .month:
                        unitString = "month"
                    case .year:
                        unitString = "year"
                    @unknown default:
                        unitString = "unknown"
                    }
                    subscriptionInfo = SubscriptionInfo(
                        period: unitString,
                        introPrice: sub.introductoryOffer?.price.description,
                        introPeriod: sub.introductoryOffer != nil ? String(describing: sub.introductoryOffer!.period) : nil,
                        familyShareable: false
                    )
                } else {
                    // Any non-subscription product is an IAP
                    iapInfo = IAPInfo(quantity: 1)
                }
                
                let price = LocalizedPrice(
                    baseInfo: baseInfo,
                    productType: product.type.rawValue,
                    localizedTitle: product.id,
                    localizedDescription: nil,
                    displayName: nil,
                    description: nil,
                    subscriptionInfo: subscriptionInfo,
                    iapInfo: iapInfo
                )
                
                priceMap[product.id] = price
            }
        } catch {
            // Error handling without logging
        }
        
        // Fall back to StoreKit 1 for any SKUs that failed
        let failedSkus = Set(skus).subtracting(priceMap.keys)
        if !failedSkus.isEmpty {
            let fallbackPrices = await withCheckedContinuation { continuation in
                fallbackToStoreKit1(for: Array(failedSkus)) { prices in
                    continuation.resume(returning: prices)
                }
            }
            priceMap.merge(fallbackPrices) { current, _ in current }
        }
        
        return priceMap
    }
    
    /// Fetches the localized price for multiple SKUs using completion handler
    /// - Parameters:
    ///   - skus: Array of product identifiers
    ///   - completion: A closure that returns a dictionary mapping SKUs to their localized price information
    public static func localizedPricing(for skus: [String], completion: @escaping ([String: LocalizedPrice]) -> Void) {
        fallbackToStoreKit1(for: skus, completion: completion)
    }
    
    /// Fallback method using StoreKit 1
    private static func fallbackToStoreKit1(for skus: [String], completion: @escaping ([String: LocalizedPrice]) -> Void) {
        let request = SKProductsRequest(productIdentifiers: Set(skus))
        let delegate = StoreKit1Delegate(completion: completion)
        request.delegate = delegate
        
        // Keep a strong reference to the delegate until the request completes
        objc_setAssociatedObject(request, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        
        request.start()
    }
}

/// Helper class for StoreKit 1 requests
private class StoreKit1Delegate: NSObject, SKProductsRequestDelegate {
    private let completion: ([String: LocalizedPrice]) -> Void
    
    init(completion: @escaping ([String: LocalizedPrice]) -> Void) {
        self.completion = completion
        super.init()
    }
    
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        var priceMap: [String: LocalizedPrice] = [:]
        for product in response.products {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = product.priceLocale
            
            if let priceString = formatter.string(from: product.price) {
                let baseInfo = BasePriceInfo(
                    currency: product.priceLocale.currencyCode ?? "USD",
                    locale: product.priceLocale.identifier,
                    value: product.price as Decimal,
                    formattedPrice: priceString,
                    currencySymbol: formatter.currencySymbol ?? "$",
                    decimalSeparator: formatter.currencyDecimalSeparator ?? "."
                )
                
                // Determine product type
                let productTypeString: String
                var subscriptionInfo: SubscriptionInfo?
                var iapInfo: IAPInfo?
                
                if #available(iOS 11.2, *), product.subscriptionPeriod != nil {
                    productTypeString = "autoRenewable"
                    // Create subscription info if available
                    subscriptionInfo = SubscriptionInfo(
                        period: "unknown",
                        introPrice: nil,
                        introPeriod: nil,
                        familyShareable: false
                    )
                } else {
                    productTypeString = "iap"
                    iapInfo = IAPInfo(quantity: 1)
                }
                
                let price = LocalizedPrice(
                    baseInfo: baseInfo,
                    productType: productTypeString,
                    localizedTitle: product.localizedTitle,
                    localizedDescription: product.localizedDescription,
                    displayName: nil,
                    description: nil,
                    subscriptionInfo: subscriptionInfo,
                    iapInfo: iapInfo
                )
                priceMap[product.productIdentifier] = price
            }
        }
        
        DispatchQueue.main.async {
            self.completion(priceMap)
        }
    }
    
    func request(_ request: SKRequest, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.completion([:])
        }
    }
} 
