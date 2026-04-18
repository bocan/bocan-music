import Foundation
import os

/// Thin, `Sendable` logging facade backed by `os.Logger`.
///
/// Usage:
/// ```swift
/// let log = AppLogger.make(.audio)
/// log.debug("decoder.start", ["format": "FLAC", "sampleRate": 44100])
/// ```
///
/// Field values whose keys match `Redaction.sensitiveKeys` are automatically
/// replaced with `"<redacted>"` before the message reaches the log.
public struct AppLogger: Sendable {
    // MARK: - Properties

    private let logger: os.Logger

    // MARK: - Init

    public init(category: LogCategory, subsystem: String = "io.cloudcauldron.bocan") {
        self.logger = os.Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Convenience factory mirroring the spec API.
    public static func make(_ category: LogCategory) -> Self {
        Self(category: category)
    }

    // MARK: - Logging

    public func trace(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:]) {
        let msg = self.format(message(), fields)
        self.logger.trace("\(msg, privacy: .public)")
    }

    public func debug(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:]) {
        let msg = self.format(message(), fields)
        self.logger.debug("\(msg, privacy: .public)")
    }

    public func info(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:]) {
        let msg = self.format(message(), fields)
        self.logger.info("\(msg, privacy: .public)")
    }

    public func notice(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:]) {
        let msg = self.format(message(), fields)
        self.logger.notice("\(msg, privacy: .public)")
    }

    public func warning(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:]) {
        let msg = self.format(message(), fields)
        self.logger.warning("\(msg, privacy: .public)")
    }

    public func error(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:]) {
        let msg = self.format(message(), fields)
        self.logger.error("\(msg, privacy: .public)")
    }

    public func fault(_ message: @autoclosure @Sendable () -> String, _ fields: [String: Any] = [:]) {
        let msg = self.format(message(), fields)
        self.logger.fault("\(msg, privacy: .public)")
    }

    // MARK: - Helpers

    /// Renders `message` with a stable, key-sorted `k=v` suffix.
    /// Sensitive values are redacted before rendering.
    func format(_ message: String, _ fields: [String: Any]) -> String {
        guard !fields.isEmpty else { return message }
        let sanitized = Redaction.sanitize(fields)
        let suffix = sanitized.keys.sorted().map { key in "\(key)=\(sanitized[key] ?? "")" }.joined(separator: " ")
        return "\(message) [\(suffix)]"
    }
}
