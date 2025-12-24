//
//  DataStore.swift
//
//
//  Created by Brandon Sneed on 11/27/23.
//

import Foundation


struct DataResult {
    let data: Data?
    let dataFiles: [URL]?
    let removable: [DataStore.ItemID]?
    
    internal init(data: Data?, dataFiles: [URL]?, removable: [DataStore.ItemID]?) {
        self.data = data
        self.dataFiles = dataFiles
        self.removable = removable
    }
    
    init(data: Data?, removable: [DataStore.ItemID]?) {
        self.init(data: data, dataFiles: nil, removable: removable)
    }
    
    init(dataFiles: [URL]?, removable: [DataStore.ItemID]?) {
        self.init(data: nil, dataFiles: dataFiles, removable: removable)
    }
}

enum DataTransactionType {
    case data
    case file
}

protocol DataStore {
    typealias ItemID = any Equatable
    associatedtype StoreConfiguration
    var hasData: Bool { get }
    var count: Int { get }
    var transactionType: DataTransactionType { get }
    init(configuration: StoreConfiguration)
    func reset()
    func append(data: RawEvent)
    func fetch(count: Int?, maxBytes: Int?) -> DataResult?
    func remove(data: [ItemID])
}
