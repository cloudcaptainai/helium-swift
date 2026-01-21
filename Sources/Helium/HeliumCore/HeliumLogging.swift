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

/// Internal categories to help segment SDK logs.
///
/// This is intentionally internal-only for now; we can make this public later if we want
/// customers to filter on it.
enum HeliumLogCategory: String, Sendable {
    case core
    case network
    case ui
    case events
    case config
    case fallback
}

/// Internal logging facade for the Helium SDK.
///
/// - Note: This file sets up the logger + log level controls. It does not emit any logs
///   by itself. Call sites will be added separately.
enum HeliumLogger {

    /// Default level is conservative; integrators can turn this up.
    @HeliumAtomic private static var level: HeliumLogLevel = .error

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
        sink.emit(
            level: messageLevel,
            category: category,
            message: message(),
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
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

        // Build a lightweight, single-line message. (Structured metadata can be added later.)
        if metadata.isEmpty {
            logger.log(level: map(level), "\(message, privacy: .public)")
        } else {
            let meta = metadata
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: " ")
            logger.log(level: map(level), "\(message, privacy: .public) \(meta, privacy: .private)")
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
