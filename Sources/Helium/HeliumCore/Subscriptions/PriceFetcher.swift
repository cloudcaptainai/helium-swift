////
////  File.swift
////  
////
////  Created by Anish Doshi on 1/11/25.
////
//
//import Foundation
//import StoreKit
//
//@available(iOS 13.0, *)
//public class PriceFetcher {
//    public static let shared = PriceFetcher()
//    private init() {}
//    
//    // MARK: - Public API
//    
//    public func getPrice(for productId: String) async throws -> String {
//        if #available(iOS 15.0, *) {
//            return try await getStoreKit2Price(for: productId)
//        } else {
//            return try await getStoreKit1Price(for: productId)
//        }
//    }
//    
//    // MARK: - StoreKit 2 Implementation (iOS 15+)
//    @available(iOS 15.0, *)
//    private func getStoreKit2Price(for productId: String) async throws -> String {
//        let product = try await Product.products(for: [productId]).first
//        guard let product = product else {
//            throw StoreError.productNotFound
//        }
//        return product.displayPrice
//    }
//    
//    // MARK: - StoreKit 1 Implementation (iOS 13-14)
//    private func getStoreKit1Price(for productId: String) async throws -> String {
//        return try await withCheckedThrowingContinuation { continuation in
//            let request = SKProductsRequest(productIdentifiers: Set([productId]))
//            let delegate = SK1RequestDelegate(completion: continuation)
//            request.delegate = delegate
//            
//            // Hold delegate in memory until request completes
//            self.sk1Delegate = delegate
//            request.start()
//        }
//    }
//    
//    // MARK: - Private
//    
//    private var sk1Delegate: SK1RequestDelegate?
//    
//    private enum StoreError: Error {
//        case productNotFound
//        case invalidPrice
//    }
//}
//
//// MARK: - StoreKit 1 Delegate Handler
//
//@available(iOS 13.0, *)
//private class SK1RequestDelegate: NSObject, SKProductsRequestDelegate {
//    private let completion: CheckedContinuation<String, Error>
//    
//    init(completion: CheckedContinuation<String, Error>) {
//        self.completion = completion
//    }
//    
//    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
//        guard let product = response.products.first else {
//            completion.resume(throwing: StoreError.productNotFound)
//            return
//        }
//        
//        let formatter = NumberFormatter()
//        formatter.numberStyle = .currency
//        formatter.locale = product.priceLocale
//        
//        guard let formattedPrice = formatter.string(from: product.price) else {
//            completion.resume(throwing: StoreError.invalidPrice)
//            return
//        }
//        
//        completion.resume(returning: formattedPrice)
//    }
//    
//    func request(_ request: SKRequest, didFailWithError error: Error) {
//        completion.resume(throwing: error)
//    }
//}
