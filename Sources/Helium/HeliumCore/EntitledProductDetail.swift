//
//  EntitledProductDetail.swift
//  Helium
//

import Foundation

enum EntitledProductSource: String {
    case appStore = "App Store"
    case paddle = "Paddle"
    case stripe = "Stripe"
    case thirdParty = "Third-party"
}

struct EntitledProductDetail: Equatable {
    let productId: String
    let source: EntitledProductSource
    let expirationDate: Date?
}
