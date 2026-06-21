/// `configKey` is a server wire value: it must stay in sync with the strings the backend sends to
/// enable haptics for an event, so these keys are not safe to rename independently.
enum ProductHapticAction: CaseIterable {
    case select
    case press
    case success
    case cancel
    case fail

    var configKey: String {
        switch self {
        case .select: return "select"
        case .press: return "press"
        case .success: return "success"
        case .cancel: return "cancel"
        case .fail: return "fail"
        }
    }

    var haptic: HeliumHaptic {
        switch self {
        case .select: return .selection
        case .press: return .success
        case .success: return .success
        case .cancel: return .warning
        case .fail: return .error
        }
    }

    /// Unrecognized keys are ignored so the backend can introduce new ones without breaking
    /// older clients.
    static func from(_ configKeys: [String]) -> Set<ProductHapticAction> {
        Set(configKeys.compactMap { key in allCases.first { $0.configKey == key } })
    }
}
