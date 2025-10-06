//
//  RestorePurchaseConfig.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 10/6/25.
//

public class RestorePurchaseConfig {
    
    var showHeliumDialog: Bool = true
    
    var restoreFailedTitle: String = "Restore Failed"
    var restoreFailedMessage: String = "We couldn't find any previous purchases to restore."
    var restoreFailedCloseButtonText: String = "OK"
    
    
    public func disableDefaultRestoreFailedDialog() {
        showHeliumDialog = false
    }
    
    public func setCustomRestoreFailedStrings(
        customTitle: String? = nil,
        customMessage: String? = nil,
        customCloseButtonText: String? = nil
    ) {
        if let customTitle {
            restoreFailedTitle = customTitle
        }
        if let customMessage {
            restoreFailedMessage = customMessage
        }
        if let customCloseButtonText {
            restoreFailedCloseButtonText = customCloseButtonText
        }
    }
    
}
