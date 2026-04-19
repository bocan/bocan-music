import MetricKit
import os

// Subscribes to `MXMetricManager` and forwards metric / diagnostic payloads
// to `AppLogger(.app)` at `.notice` level for operational visibility.
//
// Instantiate once at app launch:
// ```swift
// MetricKitListener.shared.start()
// ```
#if os(macOS)
    @MainActor
    public final class MetricKitListener: NSObject, MXMetricManagerSubscriber {
        public static let shared = MetricKitListener()
        private let log = AppLogger.make(.app)

        override private init() {}

        /// Subscribe to MetricKit payloads.
        public func start() {
            MXMetricManager.shared.add(self)
            self.log.info("metrickit.subscribed")
        }

        /// Unsubscribe (call on shutdown if needed).
        public func stop() {
            MXMetricManager.shared.remove(self)
            self.log.info("metrickit.unsubscribed")
        }

        // MARK: - MXMetricManagerSubscriber

        /// MXMetricPayload is unavailable on macOS; only diagnostics are supported.
        public nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads {
                let data = payload.jsonRepresentation()
                let json = String(data: data, encoding: .utf8) ?? "<binary>"
                let log = AppLogger.make(.app)
                log.notice("metrickit.payload.diagnostics", ["json": json])
            }
        }
    }
#endif
