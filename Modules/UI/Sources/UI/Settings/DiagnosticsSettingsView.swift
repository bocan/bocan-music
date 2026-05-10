import AppKit
import Observability
import SwiftUI

// MARK: - DiagnosticsSettingsView

/// Settings tab for crash-reporting consent and local diagnostic report management.
///
/// Lets the user:
/// - Toggle crash report collection on or off.
/// - Browse locally stored MetricKit diagnostic reports.
/// - Open the reports folder in Finder or copy a report path for attaching to a GitHub issue.
/// - Preview a report inline.
public struct DiagnosticsSettingsView: View {
    @AppStorage(MetricKitListener.consentKey) private var consented = false
    @AppStorage(MetricKitListener.consentAskedKey) private var consentAsked = false
    @State private var reports: [URL] = []
    @State private var expandedReport: URL?
    @State private var expandedContent = ""

    public init() {}

    public var body: some View {
        Form {
            // MARK: Consent toggle

            Section {
                Toggle("Share crash reports with the developer", isOn: self.$consented)
                    .help(
                        "Diagnostic reports are stored locally on this Mac and only shared when you choose to. No personal data leaves your Mac without your permission."
                    )
                    .onChange(of: self.consented) { _, enabled in
                        self.consentAsked = true
                        if enabled {
                            MetricKitListener.shared.start()
                        } else {
                            MetricKitListener.shared.stop()
                        }
                    }
                Text("Reports from crashes are available the next day, after macOS processes them overnight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Crash Reporting")
            }

            // MARK: Report list

            Section {
                if self.reports.isEmpty {
                    Text("No diagnostic reports found.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(self.reports, id: \.path) { url in
                        self.reportRow(for: url)
                    }
                }

                Button("Open Reports Folder in Finder") {
                    let dir = MetricKitListener.reportsDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                .help("Opens ~/Library/Logs/Bocan/diagnostics/ in Finder.")
                .accessibilityLabel("Open diagnostic reports folder in Finder")
            } header: {
                Text("Diagnostic Reports")
            } footer: {
                Text(
                    "Reports are stored in ~/Library/Logs/Bocan/diagnostics/. Attach a report to a GitHub issue to help diagnose a problem."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
        .task { self.reports = MetricKitListener.listReports() }
    }

    // MARK: - Private helpers

    private func reportRow(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(self.displayDate(for: url))
                    .font(.subheadline)

                Spacer()

                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Copy the full path to this report to the clipboard for pasting into a GitHub issue.")
                .accessibilityLabel("Copy path of \(url.lastPathComponent)")

                let isExpanded = self.expandedReport == url
                Button(isExpanded ? "Hide" : "View") {
                    if isExpanded {
                        self.expandedReport = nil
                        self.expandedContent = ""
                    } else {
                        self.expandedReport = url
                        self.expandedContent = (try? String(contentsOf: url, encoding: .utf8))
                            ?? "(unreadable)"
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(isExpanded ? "Collapse this report." : "Preview the raw JSON report inline.")
                .accessibilityLabel(isExpanded ? "Collapse report" : "View report \(url.lastPathComponent)")
            }

            if self.expandedReport == url {
                ScrollView {
                    Text(self.expandedContent)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Report content")
            }
        }
    }

    /// Converts a filename like `2026-05-10T12-30-00Z.json` to a human-readable date string.
    private func displayDate(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        // The filename was produced by replacing ":" with "-" in an ISO8601 string.
        // Restore the original by turning dashes after "T" back into colons.
        guard let tRange = stem.range(of: "T") else { return stem }
        let datePart = String(stem[stem.startIndex ..< tRange.upperBound])
        let timePart = String(stem[tRange.upperBound...]).replacingOccurrences(of: "-", with: ":")
        let iso = datePart + timePart
        if let date = ISO8601DateFormatter().date(from: iso) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return stem
    }
}
