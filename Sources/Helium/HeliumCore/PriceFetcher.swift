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
    public let periodUnit: String
    public let periodValue: Int
    public let introOfferEligible: Bool
    public let introOffer: SubscriptionOffer?
}

public struct SubscriptionOffer: Codable {
    public let type: String
    public let price: Decimal
    public let displayPrice: String
    public let periodUnit: String
    public let periodValue: Int
    public let periodCount: Int
    public let paymentMode: String
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
    public let familyShareable: Bool
    
    public var json: [String: Any] {
        var dict: [String: Any] = [
            "currency": baseInfo.currency,
            "locale": baseInfo.locale,
            "value": baseInfo.value,
            "formattedPrice": baseInfo.formattedPrice,
            "currencySymbol": baseInfo.currencySymbol,
            "decimalSeparator": baseInfo.decimalSeparator,
            "productType": productType,
            "familyShareable": familyShareable,
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
                "periodUnit": subInfo.periodUnit,
                "periodValue": subInfo.periodValue,
                "introOfferEligible": subInfo.introOfferEligible,
            ]
            if let introOffer = subInfo.introOffer {
                subDict["introOffer"] = [
                    "type": introOffer.type,
                    "price": introOffer.price,
                    "displayPrice": introOffer.displayPrice,
                    "periodUnit": introOffer.periodUnit,
                    "periodValue": introOffer.periodValue,
                    "periodCount": introOffer.periodCount,
                    "paymentMode": introOffer.paymentMode,
                ]
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
        
            let products = await fetchProductsWithRetry(for: skus)
            
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
                    var introOfferData: SubscriptionOffer? = nil
                    if let introOffer = sub.introductoryOffer {
                        introOfferData = SubscriptionOffer(
                            type: introOffer.type.rawValue,
                            price: introOffer.price,
                            displayPrice: introOffer.displayPrice,
                            periodUnit: formatSubscriptionPeriod(introOffer.period.unit),
                            periodValue: introOffer.period.value,
                            periodCount: introOffer.periodCount,
                            paymentMode: introOffer.paymentMode.rawValue
                        )
                    }
                    
                    subscriptionInfo = SubscriptionInfo(
                        periodUnit: formatSubscriptionPeriod(sub.subscriptionPeriod.unit),
                        periodValue: sub.subscriptionPeriod.value,
                        introOfferEligible: await checkIntroOfferEligibility(for: product),
                        introOffer: introOfferData
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
                    iapInfo: iapInfo,
                    familyShareable: product.isFamilyShareable
                )
                
                priceMap[product.id] = price
            }
        
        return priceMap
    }

    private static func fetchProductsWithRetry(
        for skus: [String],
        maxAttempts: Int = 3
    ) async -> [Product] {
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                print("[Helium] Retrying product localization lookup... (attempt \(attempt) of \(maxAttempts))")
            }
            do {
                // Only apply timeout if not on the last attempt
                if attempt < maxAttempts {
                    return try await withThrowingTaskGroup(of: [Product].self) { group in
                        group.addTask {
                            try await ProductsCache.shared.fetchProducts(for: skus)
                        }
                        
                        group.addTask {
                            // 5 second timeout
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                            throw PriceFetcherProductsError.timeout
                        }
                        
                        // Return whichever completes first
                        if let result = try await group.next() {
                            group.cancelAll()
                            return result
                        }
                        return []
                    }
                } else {
                    // Last attempt - no timeout
                    return try await ProductsCache.shared.fetchProducts(for: skus)
                }
            } catch {
                // Don't delay after the last attempt
                if attempt < maxAttempts {
                    // Random delay between 2-5 seconds for jitter
                    let delay = Double.random(in: 2.0...5.0)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        // If all attempts failed, return empty array (price localization will not work)
        return []
    }
    
    /// Fetches the localized price for multiple SKUs using completion handler
    /// - Parameters:
    ///   - skus: Array of product identifiers
    ///   - completion: A closure that returns a dictionary mapping SKUs to their localized price information
    public static func localizedPricing(for skus: [String], completion: @escaping ([String: LocalizedPrice]) -> Void) {
        fallbackToStoreKit1(for: Array(Set(skus)), completion: completion)
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
    
    @available(iOS 15.0, *)
    static func checkIntroOfferEligibility(for product: Product) async -> Bool {
        guard let subscription = product.subscription else {
            return false
        }
        
        // Check if product has an intro offer
        guard subscription.introductoryOffer != nil else {
            return false
        }
        
        // Check if user is eligible
        let isEligible = await subscription.isEligibleForIntroOffer
        return isEligible
    }
    
    @available(iOS 15.0, *)
    private static func formatSubscriptionPeriod(_ periodUnit: Product.SubscriptionPeriod.Unit) -> String {
        let unitString: String
        switch periodUnit {
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
        return unitString
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
                        periodUnit: "unknown",
                        periodValue: 1,
                        introOfferEligible: false,
                        introOffer: nil
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
                    iapInfo: iapInfo,
                    familyShareable: product.isFamilyShareable
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

enum PriceFetcherProductsError: Error {
    case timeout
    
    var localizedDescription: String {
        switch self {
        case .timeout:
            return "StoreKit request timed out during price fetching."
        }
    }
}
