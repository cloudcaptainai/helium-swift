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
    /// Nil unless a promotional offer is paired with this product. Independent of
    /// `introOfferEligible` — each is read from its own check, never derived.
    public let promoOfferEligible: Bool?
    public let promoOffer: PromotionalOfferInfo?

    public init(
        periodUnit: String,
        periodValue: Int,
        introOfferEligible: Bool,
        introOffer: SubscriptionOffer?,
        promoOfferEligible: Bool? = nil,
        promoOffer: PromotionalOfferInfo? = nil
    ) {
        self.periodUnit = periodUnit
        self.periodValue = periodValue
        self.introOfferEligible = introOfferEligible
        self.introOffer = introOffer
        self.promoOfferEligible = promoOfferEligible
        self.promoOffer = promoOffer
    }
}

public struct PromotionalOfferInfo: Codable {
    public let offerId: String
    public let type: String
    public let price: Decimal
    public let displayPrice: String
    public let periodUnit: String
    public let periodValue: Int
    public let periodCount: Int
    public let paymentMode: String
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
            if let promoOfferEligible = subInfo.promoOfferEligible {
                subDict["promoOfferEligible"] = promoOfferEligible
            }
            if let promoOffer = subInfo.promoOffer {
                subDict["promoOffer"] = [
                    "offerId": promoOffer.offerId,
                    "type": promoOffer.type,
                    "price": promoOffer.price,
                    "displayPrice": promoOffer.displayPrice,
                    "periodUnit": promoOffer.periodUnit,
                    "periodValue": promoOffer.periodValue,
                    "periodCount": promoOffer.periodCount,
                    "paymentMode": promoOffer.paymentMode,
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

/// Subscription detail from server
public struct ServerSubscriptionDetail: Codable {
    public let period: String?
    public let periodUnit: String?
    public let periodValue: Int?
    public let introOfferEligible: Bool?
    public let introOffers: [ServerIntroOffer]?
}

/// Intro offer from server
public struct ServerIntroOffer: Codable {
    public let type: String?
    public let price: Decimal?
    public let displayPrice: String?
    public let periodUnit: String?
    public let periodValue: Int?
    public let periodCount: Int?
    public let paymentMode: String?
}

/// Server-provided price info for a single product
public struct ServerProductPrice: Codable {
    public let id: String?
    public let priceId: String?
    public let formattedPrice: String?
    public let localizedTitle: String?
    public let localizedDescription: String?
    public let currency: String?
    public let value: Decimal?
    public let currencySymbol: String?
    public let duration: String?
    public let productType: String?
    public let subscriptionPeriod: String?
    public let subscription: ServerSubscriptionDetail?
    /// Bucket-level Paddle discount id (dsc_xxx) configured by the creator.
    /// Forwarded to the create-transaction endpoint, which decides whether to
    /// apply it based on the customer's eligibility. Nil when no discount is
    /// configured. Paddle-only.
    public let defaultDiscountId: String?

    public func toLocalizedPrice() -> LocalizedPrice {
        let baseInfo = BasePriceInfo(
            currency: currency ?? "",
            locale: "",
            value: value ?? 0,
            formattedPrice: formattedPrice ?? "",
            currencySymbol: currencySymbol ?? "",
            decimalSeparator: "."
        )

        var subscriptionInfo: SubscriptionInfo?
        var iapInfo: IAPInfo?

        if let sub = subscription {
            let introOffer: SubscriptionOffer? = sub.introOffers?.first.map { offer in
                SubscriptionOffer(
                    type: offer.type ?? "",
                    price: offer.price ?? 0,
                    displayPrice: offer.displayPrice ?? "",
                    periodUnit: offer.periodUnit ?? "",
                    periodValue: offer.periodValue ?? 0,
                    periodCount: offer.periodCount ?? 0,
                    paymentMode: offer.paymentMode ?? ""
                )
            }
            subscriptionInfo = SubscriptionInfo(
                periodUnit: sub.periodUnit ?? "",
                periodValue: sub.periodValue ?? 0,
                introOfferEligible: sub.introOfferEligible ?? false,
                introOffer: introOffer
            )
        } else if productType == "one_time" {
            iapInfo = IAPInfo(quantity: 1)
        }

        return LocalizedPrice(
            baseInfo: baseInfo,
            productType: productType ?? "",
            localizedTitle: localizedTitle,
            localizedDescription: localizedDescription,
            displayName: nil,
            description: nil,
            subscriptionInfo: subscriptionInfo,
            iapInfo: iapInfo,
            familyShareable: false
        )
    }
}

/// A utility class for fetching localized pricing information for a given SKU
class PriceFetcher {
    
    /// Fetches the localized price for multiple SKUs using async/await
    /// - Parameter skus: Array of product identifiers
    /// - Returns: Dictionary mapping SKUs to their localized price information
    static func localizedPricing(for skus: [String]) async -> [String: LocalizedPrice] {
        var priceMap: [String: LocalizedPrice] = [:]

            // iOS keys may arrive as `<productId>:<promoOfferId>` composites; StoreKit
            // only knows the bare id. The map keeps a bare entry per product (no promo
            // fields) plus one entry per composite sku carrying that offer's promo data,
            // so the same product can pair different offers across triggers.
            var compositesByProduct: [String: [(sku: String, offerId: String)]] = [:]
            var bareSkus: [String] = []
            var seenBareSkus = Set<String>()
            for sku in skus {
                let parts = HeliumIosProductKey.split(sku)
                if seenBareSkus.insert(parts.productId).inserted {
                    bareSkus.append(parts.productId)
                }
                if let offerId = parts.promoOfferId {
                    compositesByProduct[parts.productId, default: []].append((sku, offerId))
                }
            }

            let products = await fetchProductsWithRetry(for: bareSkus)
            var promoEligibilityByProduct: [String: Bool] = [:]
            
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
                var subscriptionPeriodUnit = ""
                var subscriptionPeriodValue = 0
                var introOfferEligible = false
                var introOfferData: SubscriptionOffer? = nil
                if let sub = product.subscription {
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
                    subscriptionPeriodUnit = formatSubscriptionPeriod(sub.subscriptionPeriod.unit)
                    subscriptionPeriodValue = sub.subscriptionPeriod.value
                    introOfferEligible = await checkIntroOfferEligibility(for: product)

                    subscriptionInfo = SubscriptionInfo(
                        periodUnit: subscriptionPeriodUnit,
                        periodValue: subscriptionPeriodValue,
                        introOfferEligible: introOfferEligible,
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

                guard let sub = product.subscription,
                      let composites = compositesByProduct[product.id] else {
                    continue
                }
                for composite in composites {
                    var promoOfferEligible = false
                    var promoOfferData: PromotionalOfferInfo? = nil
                    if let offer = sub.promotionalOffers.first(where: { $0.id == composite.offerId }) {
                        if let eligible = promoEligibilityByProduct[product.id] {
                            promoOfferEligible = eligible
                        } else {
                            // Eligibility is subscription-group level, so it is shared
                            // across every offer paired with this product.
                            promoOfferEligible = await checkPromoOfferEligibility(for: product)
                            promoEligibilityByProduct[product.id] = promoOfferEligible
                        }
                        promoOfferData = PromotionalOfferInfo(
                            offerId: composite.offerId,
                            type: "promotional",
                            price: offer.price,
                            displayPrice: offer.displayPrice,
                            periodUnit: formatSubscriptionPeriod(offer.period.unit),
                            periodValue: offer.period.value,
                            periodCount: offer.periodCount,
                            paymentMode: offer.paymentMode.rawValue
                        )
                    } else {
                        HeliumLogger.log(.debug, category: .core, "Paired promo offer not present on product", metadata: ["productId": product.id, "offerId": composite.offerId])
                    }

                    priceMap[composite.sku] = LocalizedPrice(
                        baseInfo: baseInfo,
                        productType: product.type.rawValue,
                        localizedTitle: product.id,
                        localizedDescription: nil,
                        displayName: nil,
                        description: nil,
                        subscriptionInfo: SubscriptionInfo(
                            periodUnit: subscriptionPeriodUnit,
                            periodValue: subscriptionPeriodValue,
                            introOfferEligible: introOfferEligible,
                            introOffer: introOfferData,
                            promoOfferEligible: promoOfferEligible,
                            promoOffer: promoOfferData
                        ),
                        iapInfo: iapInfo,
                        familyShareable: product.isFamilyShareable
                    )
                }
            }
        
        return priceMap
    }

    private static func fetchProductsWithRetry(
        for skus: [String],
        maxAttempts: Int = 3
    ) async -> [Product] {
        HeliumLogger.log(.debug, category: .network, "Fetching products", metadata: ["skuCount": String(skus.count)])
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                HeliumLogger.log(.debug, category: .network, "Retrying product localization lookup", metadata: [
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
                HeliumLogger.log(.debug, category: .network, "Product fetch attempt failed", metadata: ["attempt": String(attempt)])
                // Don't delay after the last attempt
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        // If all attempts failed, return empty array (price localization will not work)
        HeliumLogger.log(.warn, category: .network, "Product fetch failed after all retries", metadata: ["skuCount": String(skus.count)])
        return []
    }
    
    @available(iOS 15.0, *)
    static func checkIntroOfferEligibility(for product: Product) async -> Bool {
        if let simulated = await Helium.testing.simulatedIntroOfferEligibilityIfActive(productId: product.id) {
            return simulated
        }

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

    /// Eligible iff the user holds or ever held an auto-renewable transaction in the
    /// product's subscription group — Apple's rule for promotional offer eligibility.
    @available(iOS 15.0, *)
    static func checkPromoOfferEligibility(for product: Product) async -> Bool {
        if let simulated = await Helium.testing.simulatedPromoOfferEligibilityIfActive(productId: product.id) {
            return simulated
        }

        guard let groupID = product.subscription?.subscriptionGroupID else {
            return false
        }

        for await verificationResult in Transaction.all {
            guard case .verified(let transaction) = verificationResult else {
                continue
            }
            if transaction.productType == .autoRenewable && transaction.subscriptionGroupID == groupID {
                return true
            }
        }
        return false
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
