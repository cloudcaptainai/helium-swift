//
//  RestorePurchaseConfig.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 10/6/25.
//

public class RestorePurchaseConfig {
    // Default values
    private static let defaultShowHeliumDialog = true
    private static let defaultRestoreFailedTitle = "Restore Failed"
    private static let defaultRestoreFailedMessage = "We couldn't find any previous purchases to restore."
    private static let defaultRestoreFailedCloseButtonText = "OK"

    private(set) var showHeliumDialog: Bool = defaultShowHeliumDialog

    var restoreFailedTitle: String = defaultRestoreFailedTitle
    var restoreFailedMessage: String = defaultRestoreFailedMessage
    var restoreFailedCloseButtonText: String = defaultRestoreFailedCloseButtonText
    
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

    /// Resets all configuration values to their defaults.
    public func reset() {
        showHeliumDialog = Self.defaultShowHeliumDialog
        restoreFailedTitle = Self.defaultRestoreFailedTitle
        restoreFailedMessage = Self.defaultRestoreFailedMessage
        restoreFailedCloseButtonText = Self.defaultRestoreFailedCloseButtonText
    }

}
