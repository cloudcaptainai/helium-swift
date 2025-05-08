public struct BuildConstants {
    /// Current SDK version
    /// This is automatically updated by GitHub Actions on release
    public static let version = "1.7.2"
    
    /// Get the current SDK version
    public static func current() -> String {
        return version
    }
    
    /// Get the version as components
    public static func components() -> (major: Int, minor: Int, patch: Int)? {
        let parts = version.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }
        return (major, minor, patch)
    }
}
