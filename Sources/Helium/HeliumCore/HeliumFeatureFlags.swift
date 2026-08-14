import Foundation

/// Declaration of every server-driven feature flag the SDK understands.
///
/// The server delivers flags in the on-launch response's `featureFlags` map. Every
/// flag is off unless the server sends `true`.
enum HeliumFeatureFlag: String, CaseIterable {
    /// Gates JS-crash detection at its root: the error hook is only injected into
    /// paywall bundles when enabled, so probes and fallback recovery can never fire
    /// without it. WebContent-process-death handling is deliberately not gated —
    /// that is a definitive OS signal, not a heuristic.
    case jsCrashFallback
}

/// Immutable resolved view of the server's `featureFlags` map.
///
/// Coercion is strict: only JSON booleans count. Any other value (the string
/// `"true"`, numbers, null, structures) is logged and the flag stays off. Keys
/// the SDK doesn't declare are ignored.
struct HeliumFeatureFlags {
    private let resolved: [HeliumFeatureFlag: Bool]

    static let empty = HeliumFeatureFlags(resolved: [:])

    func isEnabled(_ flag: HeliumFeatureFlag) -> Bool {
        resolved[flag] ?? false
    }

    static func from(_ raw: JSON?) -> HeliumFeatureFlags {
        guard let dict = raw?.dictionary, !dict.isEmpty else { return .empty }
        var resolved: [HeliumFeatureFlag: Bool] = [:]
        for flag in HeliumFeatureFlag.allCases {
            guard let element = dict[flag.rawValue] else { continue }
            if element.type == .bool {
                resolved[flag] = element.boolValue
            } else {
                HeliumLogger.log(
                    .warn,
                    category: .config,
                    "Helium feature flag '\(flag.rawValue)' has non-boolean value (\(element)); treating it as off."
                )
            }
        }
        return HeliumFeatureFlags(resolved: resolved)
    }
}
