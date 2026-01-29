import Foundation
import os

/// Log levels supported by the Helium SDK.
///
/// Higher values are more verbose. When a level is set, logs at that level and all
/// *less verbose* levels will be emitted.
///
/// Example:
/// - `.warn` emits: warn + error
/// - `.debug` emits: debug + info + warn + error
public enum HeliumLogLevel: Int, Comparable, Sendable {
    case off = 0
    case error = 1
    case warn = 2
    case info = 3
    case debug = 4
    case trace = 5

    public static func < (lhs: HeliumLogLevel, rhs: HeliumLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Categories to help segment SDK logs.
public enum HeliumLogCategory: String, Sendable {
    case core
    case network
    case ui
    case events
    case config
    case fallback
    case entitlements
}

// MARK: - Log Event & Listener Types

/// A value type representing a single log event emitted by the Helium SDK.
///
/// Wrapper SDKs (e.g., Expo, Flutter) can subscribe to receive these events
/// and forward them to their own logging systems.
public struct HeliumLogEvent: Sendable {
    /// The timestamp when the log event was created.
    public let timestamp: Date

    /// The severity level of the log event.
    public let level: HeliumLogLevel

    /// The category/subsystem that generated this log.
    public let category: HeliumLogCategory

    /// The log message (already prefixed with "[Helium] ").
    public let message: String

    /// Optional key-value metadata associated with this log event.
    public let metadata: [String: String]
}

/// An opaque token returned when registering a log listener.
///
/// Use this token to remove the listener when it's no longer needed.
/// The listener is automatically removed if the token is deallocated.
public final class HeliumLogListenerToken: @unchecked Sendable {
    fileprivate let id: UUID
    fileprivate weak var manager: HeliumLogListenerManager?

    fileprivate init(id: UUID, manager: HeliumLogListenerManager) {
        self.id = id
        self.manager = manager
    }

    deinit {
        manager?.removeListener(id: id)
    }

    /// Explicitly removes the listener associated with this token.
    public func remove() {
        manager?.removeListener(id: id)
        manager = nil
    }
}

/// Internal manager for log listeners. Thread-safe.
final class HeliumLogListenerManager: @unchecked Sendable {
    static let shared = HeliumLogListenerManager()

    private let queue = DispatchQueue(label: "com.tryhelium.loglisteners", attributes: .concurrent)
    private var listeners: [UUID: @Sendable (HeliumLogEvent) -> Void] = [:]

    private init() {}

    func addListener(_ listener: @escaping @Sendable (HeliumLogEvent) -> Void) -> HeliumLogListenerToken {
        let id = UUID()
        queue.async(flags: .barrier) {
            self.listeners[id] = listener
        }
        return HeliumLogListenerToken(id: id, manager: self)
    }

    func removeListener(id: UUID) {
        queue.async(flags: .barrier) {
            self.listeners.removeValue(forKey: id)
        }
    }

    func removeAllListeners() {
        queue.async(flags: .barrier) {
            self.listeners.removeAll()
        }
    }

    func emit(_ event: HeliumLogEvent) {
        queue.async {
            let currentListeners = self.listeners
            guard !currentListeners.isEmpty else { return }

            // Dispatch to listeners on a background queue to protect the SDK
            // from slow or failing listeners
            DispatchQueue.global(qos: .utility).async {
                for (_, listener) in currentListeners {
                    // Each listener is called independently; failures don't affect others
                    listener(event)
                }
            }
        }
    }
}

/// Logging facade for the Helium SDK.
///
/// Provides log level controls and allows wrapper SDKs to subscribe to log events.
public enum HeliumLogger {
    
#if DEBUG
    private static let defaultLogLevel = HeliumLogLevel.info
#else
    private static let defaultLogLevel = HeliumLogLevel.error
#endif
    @HeliumAtomic private static var level: HeliumLogLevel = defaultLogLevel
    
    /// Underlying sink. Default is OSLog.
    @HeliumAtomic private static var sink: any HeliumLogSink = HeliumOSLogSink()

    static func setLogLevel(_ newLevel: HeliumLogLevel) {
        level = newLevel
    }

    static func getLogLevel() -> HeliumLogLevel {
        level
    }

    static func setSink(_ newSink: any HeliumLogSink) {
        sink = newSink
    }

    // MARK: - Log Listener API

    /// Registers a listener to receive log events from the Helium SDK.
    ///
    /// Wrapper SDKs (e.g., Expo, Flutter) can use this to forward Helium logs
    /// to their own logging systems. The listener receives events only after
    /// log-level filtering has been applied.
    ///
    /// - Parameter listener: A closure called for each log event. Called on a background queue.
    /// - Returns: A token that can be used to remove the listener. The listener is automatically
    ///   removed when the token is deallocated or when `remove()` is called on it.
    ///
    /// ## Example Usage
    /// ```swift
    /// let token = HeliumLogger.addLogListener { event in
    ///     print("[\(event.level)] \(event.message)")
    /// }
    ///
    /// // Later, to stop receiving events:
    /// token.remove()
    /// ```
    ///
    /// - Important: Listeners are called asynchronously on a background queue.
    ///   Do not perform blocking operations in the listener callback.
    public static func addLogListener(
        _ listener: @escaping @Sendable (HeliumLogEvent) -> Void
    ) -> HeliumLogListenerToken {
        HeliumLogListenerManager.shared.addListener(listener)
    }

    /// Removes all registered log listeners.
    ///
    /// This is useful for cleanup during SDK reset or testing.
    public static func removeAllLogListeners() {
        HeliumLogListenerManager.shared.removeAllListeners()
    }

    // MARK: - Internal Logging

    /// Emits a log message if `messageLevel` is enabled.
    ///
    /// - Important: Call sites should prefer passing an autoclosure to avoid expensive
    ///   message creation when logs are disabled.
    static func log(
        _ messageLevel: HeliumLogLevel,
        category: HeliumLogCategory,
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        file: StaticString = #file,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let current = level
        guard current != .off, messageLevel.rawValue <= current.rawValue else {
            return
        }

        // Evaluate the message once
        let evaluatedMessage = message()
        let prefixedMessage = "[Helium] \(evaluatedMessage)"

        // Emit to the primary sink (OSLog)
        sink.emit(
            level: messageLevel,
            category: category,
            message: evaluatedMessage,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )

        // Emit to registered listeners
        let event = HeliumLogEvent(
            timestamp: Date(),
            level: messageLevel,
            category: category,
            message: prefixedMessage,
            metadata: metadata
        )
        HeliumLogListenerManager.shared.emit(event)
    }
}

/// Internal protocol so we can swap out the destination (OSLog, print, custom callback, etc.).
protocol HeliumLogSink: Sendable {
    func emit(
        level: HeliumLogLevel,
        category: HeliumLogCategory,
        message: String,
        metadata: [String: String],
        file: StaticString,
        function: StaticString,
        line: UInt
    )
}

/// Default sink backed by Apple's unified logging system.
///
/// This keeps SDK logs performant and discoverable via Console.app.
struct HeliumOSLogSink: HeliumLogSink {

    private let subsystem: String

    init(subsystem: String = "com.tryhelium.sdk") {
        self.subsystem = subsystem
    }

    func emit(
        level: HeliumLogLevel,
        category: HeliumLogCategory,
        message: String,
        metadata: [String: String],
        file: StaticString,
        function: StaticString,
        line: UInt
    ) {
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        let prefixedMessage = "[Helium] \(message)"

        // Build a lightweight, single-line message. (Structured metadata can be added later.)
        if metadata.isEmpty {
            logger.log(level: map(level), "\(prefixedMessage, privacy: .public)")
        } else {
            let meta = metadata
                .map { "\($0.key) = \($0.value)" }
                .sorted()
                .joined(separator: "\n")
            logger.log(level: map(level), "\(prefixedMessage, privacy: .public)\n\(meta, privacy: .private)")
        }
    }

    private func map(_ level: HeliumLogLevel) -> OSLogType {
        switch level {
        case .off:
            return .default
        case .error:
            return .error
        case .warn:
            return .default
        case .info:
            return .info
        case .debug, .trace:
            return .debug
        }
    }
}
