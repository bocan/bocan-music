import SwiftUI

// MARK: - HelpWindowView

/// In-app help reference shown from Help → Bòcan Music Help. The text is in
/// `HelpContent` and `HelpShortcuts`.
public struct HelpWindowView: View {
    @State private var selection: HelpSection? = .gettingStarted

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(HelpSection.allCases, id: \.self, selection: self.$selection) { section in
                Label(Self.text(section.title), systemImage: section.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            ScrollView {
                self.page(self.selection ?? .gettingStarted)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Resolves a `HelpContent` key against the module catalog.
    static func text(_ key: String) -> String {
        L10n.string(String.LocalizationValue(key))
    }

    // MARK: - Private

    private func page(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.text(section.title))
                .font(.largeTitle)
                .fontWeight(.semibold)
                .padding(.bottom, 20)

            if let intro = HelpContent.intro(for: section) {
                Text(Self.text(intro))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 20)
            }

            switch section {
            case .shortcuts:
                HelpShortcutsTable()

            case .formats:
                HelpFormatsList()

            default:
                HelpTopicList(topics: HelpContent.topics(for: section))
            }
        }
    }
}

// MARK: - HelpTopicList

private struct HelpTopicList: View {
    let topics: [HelpTopic]

    var body: some View {
        ForEach(self.topics, id: \.title) { topic in
            VStack(alignment: .leading, spacing: 4) {
                Text(HelpWindowView.text(topic.title))
                    .font(.headline)
                Text(HelpWindowView.text(topic.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 16)
        }
    }
}

// MARK: - HelpShortcutsTable

private struct HelpShortcutsTable: View {
    var body: some View {
        ForEach(HelpShortcuts.groups, id: \.title) { group in
            VStack(alignment: .leading, spacing: 0) {
                Text(HelpWindowView.text(group.title))
                    .font(.headline)
                    .padding(.bottom, 6)
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 0) {
                    ForEach(group.shortcuts, id: \.action) { shortcut in
                        GridRow {
                            Text(HelpWindowView.text(shortcut.action))
                                .gridColumnAlignment(.leading)
                                .frame(minWidth: 220, alignment: .leading)
                            Text(Self.display(shortcut.key))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    /// Shortcut symbols show as written; the one key spelled as a word is localized.
    private static func display(_ key: String) -> String {
        key == HelpShortcuts.spaceKey ? HelpWindowView.text(key) : key
    }
}

// MARK: - HelpFormatsList

private struct HelpFormatsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(HelpContent.formatRows, id: \.title) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(HelpWindowView.text(row.title))
                        .fontWeight(.semibold)
                    Text(HelpWindowView.text(row.body))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 20)

        Text(HelpWindowView.text(HelpContent.formatsTags))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
