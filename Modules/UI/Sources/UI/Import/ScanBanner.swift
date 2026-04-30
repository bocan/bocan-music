import Library
import SwiftUI

// MARK: - ScanBanner

/// A non-blocking progress banner that slides in at the top of the content area
/// while `LibraryViewModel` is scanning, then auto-hides 3 seconds after
/// the scan finishes.
///
/// Mount it via `.safeAreaInset(edge: .top)` on the content pane:
///
/// ```swift
/// ContentPane(vm: vm)
///     .safeAreaInset(edge: .top, spacing: 0) {
///         ScanBanner(vm: vm)
///     }
/// ```
public struct ScanBanner: View {
    @ObservedObject public var vm: LibraryViewModel

    /// Timer token used to auto-dismiss the summary after a short delay.
    @State private var dismissTimer: Timer?

    public init(vm: LibraryViewModel) {
        self.vm = vm
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if self.vm.isScanning {
                self.scanningBanner
            } else if self.vm.scanSummary != nil {
                self.summaryBanner
            }
        }
        .animation(.easeInOut(duration: 0.25), value: self.vm.isScanning)
        .animation(.easeInOut(duration: 0.25), value: self.vm.scanSummary != nil)
        .onChange(of: self.vm.scanSummary != nil) { _, summaryVisible in
            if summaryVisible {
                self.scheduleDismiss()
            }
        }
    }

    // MARK: - Scanning banner

    private var scanningBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Scanning…")
                    .font(Typography.footnote.weight(.medium))
                    .foregroundStyle(Color.textPrimary)

                Text(self.scanSubtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Cancel") {
                self.vm.cancelScan()
            }
            .buttonStyle(.borderless)
            .font(Typography.footnote)
            .foregroundStyle(Color.textSecondary)
            .help("Cancel the running library scan")
            .accessibilityLabel("Cancel scan")
            .accessibilityHint("Stops the in-progress library scan. Files already imported are kept.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(self.bannerBackground)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Summary banner

    private var summaryBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(self.summaryText)
                .font(Typography.footnote)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Button {
                self.dismissTimer?.invalidate()
                self.vm.dismissScanSummary()
            } label: {
                Image(systemName: "xmark")
                    .font(Typography.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.textSecondary)
            .help("Dismiss the scan summary")
            .accessibilityLabel("Dismiss")
            .accessibilityHint("Hides the scan summary banner.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(self.bannerBackground)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Helpers

    private var bannerBackground: some View {
        Color(NSColor.windowBackgroundColor)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 2)
    }

    private var scanSubtitle: String {
        var parts: [String] = []
        if self.vm.scanWalked > 0 {
            parts.append("\(self.vm.scanWalked) files walked")
        }
        if self.vm.scanInserted > 0 {
            parts.append("\(self.vm.scanInserted) new")
        }
        if self.vm.scanUpdated > 0 {
            parts.append("\(self.vm.scanUpdated) updated")
        }
        if !self.vm.scanCurrentPath.isEmpty {
            parts.append(self.vm.scanCurrentPath)
        }
        return parts.isEmpty ? "Preparing…" : parts.joined(separator: " · ")
    }

    private var summaryText: String {
        guard let s = self.vm.scanSummary else { return "" }
        var parts: [String] = []
        parts.append("\(s.inserted + s.updated + s.skipped) files")
        if s.inserted > 0 { parts.append("\(s.inserted) new track\(s.inserted == 1 ? "" : "s")") }
        if s.updated > 0 { parts.append("\(s.updated) updated") }
        if s.errors > 0 { parts.append("\(s.errors) error\(s.errors == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func scheduleDismiss() {
        self.dismissTimer?.invalidate()
        self.dismissTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak vm] _ in
            Task { @MainActor [weak vm] in
                vm?.dismissScanSummary()
            }
        }
    }
}
