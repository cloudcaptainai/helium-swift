//
//  File.swift
//  
//
//  Created by Anish Doshi on 9/18/24.
//

import Foundation

public enum HeliumAssetLoadStatus {
    case notDownloadedYet
    case fontDownloaded(postScriptName: CFString)
    case downloadFailed
}
