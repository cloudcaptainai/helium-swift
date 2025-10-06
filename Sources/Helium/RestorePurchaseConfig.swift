//
//  RestorePurchaseConfig.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 10/6/25.
//

public class RestorePurchaseConfig {
    
    private(set) var showHeliumDialog: Bool = true
    
    var restoreFailedTitle: String = "Restore Failed"
    var restoreFailedMessage: String = "We couldn't find any previous purchases to restore."
    var restoreFailedCloseButtonText: String = "OK"
    
    /// Disable the default dialog that Helium will display if a "Restore Purchases" action is not successful.
    /// You can handle this yourself if desired by listening for the PurchaseRestoreFailedEvent.
    public func disableRestoreFailedDialog() {
        showHeliumDialog = false
    }
    
    /// Set custom strings to show in the dialog that Helium will display if a "Restore Purchases" action is not successful.
    /// Note that these strings will not be localized by Helium for you.
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
