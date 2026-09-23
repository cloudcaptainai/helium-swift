//
//  AlreadyPurchasedConfig.swift
//  helium-swift
//

public class AlreadyPurchasedConfig {
    init() {}

    private static let defaultShowHeliumDialog = true

    private(set) var showHeliumDialog: Bool = defaultShowHeliumDialog

    let title = "Already Purchased"
    let message = "You already own this product. Contact support if you have any issues."
    let closeButtonText = "OK"

    /// Disable the default dialog that Helium displays when a purchase attempt resolves as already owned.
    public func disableAlreadyPurchasedDialog() {
        showHeliumDialog = false
    }

    /// Resets configuration to defaults.
    public func reset() {
        showHeliumDialog = Self.defaultShowHeliumDialog
    }

}
