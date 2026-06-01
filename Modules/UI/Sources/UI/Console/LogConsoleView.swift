import AppKit
import Observability
import SwiftUI

// MARK: - LogConsoleView

/// In-app log console window content.
///
/// Shows all lines logged since process launch (backfill from `LogStore`) followed
/// by new lines tailed live. Binds toolbar controls to `LogConsoleViewModel`.
///
/// Add as the content of a `Window("Log Console", id: "log-console")` scene; the
/// view calls `vm.start()` on appear and `vm.stop()` on disappear via lifecycle
/// modifiers. Use a `.task {}` for the start call so it is cancelled automatically
/// when the view is removed from the hierarchy.
public struct LogConsoleView: View {
    @Bindable var vm: LogConsoleViewModel

    private static let bottomAnchor = "log-console-bottom"

    public init(vm: LogConsoleViewModel) {
        self.vm = vm
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            self.controlBar
            Divider()
            if self.vm.isAtCapacity {
                self.capacityBanner
            }
            self.contentArea
        }
        .task { self.vm.start() }
        .onDisappear { self.vm.stop() }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 8) {
            self.levelPicker
            self.categoriesMenu
            self.searchField
            Spacer()
            self.pauseButton
            self.clearMenu
            self.copyButton
            self.exportButton
            Divider().frame(height: 16)
            self.tailToggle
            self.lineCountLabel
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var levelPicker: some View {
        HStack(spacing: 4) {
            Text(localized: "Level:")
                .foregroundStyle(.secondary)
            Picker("Level", selection: self.$vm.minimumLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(verbatim: level.label.localizedCapitalized).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .help("Minimum log level to show")
    }

    private var categoriesMenu: some View {
        Menu {
            Button {
                self.vm.selectedCategories = []
            } label: {
                Label {
                    Text(localized: "All Categories")
                } icon: {
                    Image(systemName: "checkmark")
                        .opacity(self.vm.selectedCategories.isEmpty ? 1 : 0)
                }
            }
            Divider()
            ForEach(LogCategory.allCases, id: \.self) { category in
                Button {
                    if self.vm.selectedCategories.contains(category) {
                        self.vm.selectedCategories.remove(category)
                    } else {
                        self.vm.selectedCategories.insert(category)
                    }
                } label: {
                    Label {
                        Text(verbatim: category.rawValue)
                    } icon: {
                        Image(systemName: "checkmark")
                            .opacity(self.vm.selectedCategories.contains(category) ? 1 : 0)
                    }
                }
            }
        } label: {
            Label(self.categoriesMenuTitle, systemImage: "line.3.horizontal.decrease")
        }
        .help("Filter by log category")
    }

    private var searchField: some View {
        TextField("", text: self.$vm.searchText, prompt: Text(localized: "Search\u{2026}"))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, maxWidth: 200)
            .help("Filter entries by message text")
            .accessibilityLabel(L10n.string("Search log entries"))
    }

    private var pauseButton: some View {
        Button {
            self.vm.isPaused.toggle()
        } label: {
            Label {
                Text(localized: self.vm.isPaused ? "Resume" : "Pause")
            } icon: {
                Image(systemName: self.vm.isPaused ? "play.fill" : "pause.fill")
            }
        }
        .help(
            self.vm.isPaused
                ? "Resume ingesting new log entries"
                : "Pause new entries from flowing in"
        )
    }

    private var clearMenu: some View {
        Menu {
            Button {
                self.vm.clearView()
            } label: {
                Label(L10n.string("Clear View"), systemImage: "xmark")
            }
            .help("Remove all entries from the visible list without emptying the ring buffer")

            Divider()

            Button(role: .destructive) {
                self.vm.clearBuffer()
            } label: {
                Label(L10n.string("Clear Buffer"), systemImage: "trash.fill")
            }
            .help("Empty both the visible list and the underlying ring buffer")
        } label: {
            Label(L10n.string("Clear"), systemImage: "trash")
        }
        .help("Clear the log view; expand for option to also clear the ring buffer")
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.vm.copyText(), forType: .string)
        } label: {
            Label(L10n.string("Copy"), systemImage: "doc.on.doc")
        }
        .help("Copy visible log lines to the clipboard")
    }

    private var exportButton: some View {
        Button {
            Task { await self.exportLog() }
        } label: {
            Label(L10n.string("Export\u{2026}"), systemImage: "square.and.arrow.up")
        }
        .help("Save visible log lines to a .log file")
    }

    private var tailToggle: some View {
        Toggle(isOn: self.$vm.isTailing) {
            Label(L10n.string("Tail"), systemImage: "arrow.down.to.line")
        }
        .toggleStyle(.button)
        .help("Auto-scroll to the newest entry as lines arrive")
    }

    private var lineCountLabel: some View {
        Text(verbatim: self.lineCountText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(minWidth: 70, alignment: .trailing)
            .accessibilityLabel(Text(localized: "\(self.vm.visible.count) log entries visible"))
    }

    // MARK: - Content area

    private var contentArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(self.vm.visible) { entry in
                        LogConsoleRow(entry: entry)
                            .padding(.horizontal, 10)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            .onChange(of: self.vm.visible.count) { _, _ in
                if self.vm.isTailing {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !self.vm.isTailing {
                    self.jumpToLatestButton(proxy: proxy)
                }
            }
        }
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            self.vm.isTailing = true
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        } label: {
            Label(L10n.string("Jump to Latest"), systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .padding(12)
        .help("Scroll to the most recent entry and resume tailing")
    }

    // MARK: - Capacity banner

    private var capacityBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(localized: "Buffer full - oldest entries are being dropped")
                .font(.caption)
        }
        .foregroundStyle(Color.warningTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warningTint.opacity(0.08))
    }

    // MARK: - Export

    private func exportLog() async {
        let text = self.vm.exportText()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bocan-\(Self.exportFilename()).log"
        panel.allowedContentTypes = [.plainText]
        let outcome = await withCheckedContinuation { cont in
            panel.begin { cont.resume(returning: $0) }
        }
        guard outcome == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private var lineCountText: String {
        let n = self.vm.visible.count
        return n == 1 ? L10n.string("1 line") : L10n.string("\(n) lines")
    }

    private var categoriesMenuTitle: String {
        if self.vm.selectedCategories.isEmpty {
            return L10n.string("Categories: All")
        }
        if self.vm.selectedCategories.count == 1,
           let single = self.vm.selectedCategories.first {
            return L10n.string("Categories: \(single.rawValue)")
        }
        return L10n.string("Categories: \(self.vm.selectedCategories.count)")
    }

    private static let exportDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private static func exportFilename() -> String {
        self.exportDateFormatter.string(from: Date())
    }
}
