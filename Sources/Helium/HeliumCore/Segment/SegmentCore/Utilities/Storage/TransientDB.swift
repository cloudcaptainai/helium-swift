//
//  TransientDB.swift
//
//
//  Created by Brandon Sneed on 11/27/23.
//
import Foundation

class TransientDB {
    // our data store
    internal let store: any DataStore
    // keeps items added in the order given.
    internal let syncQueue = DispatchQueue(label: "transientDB.sync")
    private let asyncAppend: Bool
    
    var hasData: Bool {
        var result: Bool = false
        syncQueue.sync {
            result = store.hasData
        }
        return result
    }
    
    var count: Int {
        var result: Int = 0
        syncQueue.sync {
            result = store.count
        }
        return result
    }
    
    var transactionType: DataTransactionType {
        return store.transactionType
    }
    
    init(store: any DataStore, asyncAppend: Bool = true) {
        self.store = store
        self.asyncAppend = asyncAppend
    }
    
    func reset() {
        syncQueue.sync {
            store.reset()
        }
    }
    
    func append(data: RawEvent) {
        if asyncAppend {
            syncQueue.async { [weak self] in
                guard let self else { return }
                store.append(data: data)
            }
        } else {
            syncQueue.sync { [weak self] in
                guard let self else { return }
                store.append(data: data)
            }
        }
    }
    
    func fetch(count: Int? = nil, maxBytes: Int? = nil) -> DataResult? {
        var result: DataResult? = nil
        syncQueue.sync {
            result = store.fetch(count: count, maxBytes: maxBytes)
        }
        return result
    }
    
    func remove(data: [DataStore.ItemID]) {
        syncQueue.sync {
            store.remove(data: data)
        }
    }
}
