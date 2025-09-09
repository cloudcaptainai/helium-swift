import Foundation
import StoreKit

@available(iOS 15.0, *)
actor ProductsCache {
    static let shared = ProductsCache()
    
    private var cache: [String: Product] = [:]
    
    /// Fetches products and returns  a dictionary mapping IDs to Products
    func fetchProductsMap(for productIds: [String]) async throws -> [String: Product] {
        let productIdSet = Set(productIds)
        // Find which products we don't have cached
        let missingIds = productIdSet.filter { cache[$0] == nil }
        
        // Fetch only the missing products
        if !missingIds.isEmpty {
            let products = try await Product.products(for: missingIds)
            for product in products {
                cache[product.id] = product
            }
        }
        
        // Return requested products from cache
        var result: [String: Product] = [:]
        for id in productIdSet {
            if let product = cache[id] {
                result[id] = product
            }
        }
        return result
    }
    
    func fetchProducts(for productIds: [String]) async throws -> [Product] {
        let productMap = try await fetchProductsMap(for: productIds)
        return Array(productMap.values)
    }
    
    func getProduct(id: String) async throws -> Product? {
        let productMap = try await fetchProductsMap(for: [id])
        return productMap[id]
    }
    
    /// Prefetches products without returning results
    func prefetchProducts(_ productIds: [String]) async {
        guard !productIds.isEmpty else { return }
        _ = try? await fetchProductsMap(for: productIds)
    }
    
    func invalidateCache() {
        cache.removeAll()
    }
}
