import Foundation

extension Bundle {
    /// Returns the resource bundle for Helium assets.
    /// - SPM: Uses the auto-generated `Bundle.module`.
    /// - CocoaPods: Looks for the `Helium.bundle` inside the framework bundle.
    static var heliumResources: Bundle? = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let frameworkBundle = Bundle(for: BundleToken.self)
        guard let url = frameworkBundle.url(forResource: "Helium", withExtension: "bundle"),
              let bundle = Bundle(url: url) else {
            return frameworkBundle
        }
        return bundle
        #endif
    }()
}

#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
