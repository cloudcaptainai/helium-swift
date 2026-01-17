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
        HeliumLog.log(.debug, category: .network, "Fetching products", metadata: ["skuCount": String(skus.count)])
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                HeliumLog.log(.debug, category: .network, "Retrying product localization lookup", metadata: [
                    "attempt": String(attempt),
                    "maxAttempts": String(maxAttempts)
                ])
            }
            do {
                var timeoutNanoseconds: UInt64 = 10_000_000_000
                if attempt == 1 {
                    timeoutNanoseconds = 3_000_000_000
                } else if attempt == 2 {
                    timeoutNanoseconds = 4_000_000_000
                }
                return try await withThrowingTaskGroup(of: [Product].self) { group in
                    group.addTask {
                        try await ProductsCache.shared.fetchProducts(for: skus)
                    }
                    
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        throw PriceFetcherProductsError.timeout
                    }
                    
                    // Return whichever completes first
                    if let result = try await group.next() {
                        group.cancelAll()
                        return result
                    }
                    return []
                }
            } catch {
                HeliumLog.log(.debug, category: .network, "Product fetch attempt failed", metadata: ["attempt": String(attempt)])
                // Don't delay after the last attempt
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        // If all attempts failed, return empty array (price localization will not work)
        HeliumLog.log(.warn, category: .network, "Product fetch failed after all retries", metadata: ["skuCount": String(skus.count)])
        return []
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

enum PriceFetcherProductsError: Error {
    case timeout
    
    var localizedDescription: String {
        switch self {
        case .timeout:
            return "StoreKit request timed out during price fetching."
        }
    }
}
