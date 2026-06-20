import Persistence
import SwiftUI

// MARK: - PodcastShowSettingsView

/// Per-show overrides sheet (Phase 21-12-h): playback speed, episode order,
/// retention, and auto-download. Each control's "App Default" / "Use Default" /
/// "All" choice maps to nil (fall back to the app default). Changes persist
/// immediately through `PodcastsViewModel` setters. Show title/type is feed
/// content, rendered verbatim.
struct PodcastShowSettingsView: View {
    let podcast: Podcast
    @ObservedObject var vm: PodcastsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var speed: Double?
    @State private var sort: String?
    @State private var retention: Int?
    @State private var autoDownload: Bool

    private static let speeds: [Double] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]
    private static let retentions: [Int] = [10, 25, 50, 100]

    init(podcast: Podcast, vm: PodcastsViewModel) {
        self.podcast = podcast
        self._vm = ObservedObject(wrappedValue: vm)
        self._speed = State(initialValue: podcast.playbackSpeed)
        self._sort = State(initialValue: podcast.episodeSort)
        self._retention = State(initialValue: podcast.retentionLimit)
        self._autoDownload = State(initialValue: podcast.autoDownload)
    }

    private var podcastID: Int64 {
        self.podcast.id ?? -1
    }

    /// The default order label shown alongside "Use Default" (derived from show type).
    private var defaultSortLabel: String {
        self.podcast.showType == "serial" ? L10n.string("Oldest First") : L10n.string("Newest First")
    }

    private var showTypeLabel: String {
        switch self.podcast.showType {
        case "serial":
            L10n.string("Serial")

        case "episodic":
            L10n.string("Episodic")

        default:
            L10n.string("Not specified")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Feed content -- not localized.
            Text(verbatim: self.podcast.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 8)

            Form {
                self.speedSection
                self.sortSection
                self.retentionSection
                self.generalSection
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(L10n.string("Done")) { self.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Sections

    private var speedSection: some View {
        Section(L10n.string("Playback Speed")) {
            Picker(L10n.string("Speed"), selection: self.$speed) {
                Text(localized: "App Default").tag(Double?.none)
                ForEach(Self.speeds, id: \.self) { value in
                    Text(verbatim: "\(value.formatted())×").tag(Double?.some(value))
                }
            }
            .onChange(of: self.speed) { _, new in
                Task { await self.vm.setPlaybackSpeed(new, podcastID: self.podcastID) }
            }
        }
    }

    private var sortSection: some View {
        Section(L10n.string("Episode Order")) {
            Picker(L10n.string("Order"), selection: self.$sort) {
                Text(L10n.string("Use Default (\(self.defaultSortLabel))")).tag(String?.none)
                Text(localized: "Newest First").tag(String?.some("newest"))
                Text(localized: "Oldest First").tag(String?.some("oldest"))
            }
            .onChange(of: self.sort) { _, new in
                Task { await self.vm.setEpisodeSort(new, podcastID: self.podcastID) }
            }
        }
    }

    private var retentionSection: some View {
        Section {
            Picker(L10n.string("Keep Episodes"), selection: self.$retention) {
                Text(localized: "All").tag(Int?.none)
                ForEach(Self.retentions, id: \.self) { value in
                    Text(L10n.string("\(value) most recent")).tag(Int?.some(value))
                }
            }
            .onChange(of: self.retention) { _, new in
                Task { await self.vm.setRetentionLimit(new, podcastID: self.podcastID) }
            }
        } footer: {
            Text(localized: "In-progress, played, and downloaded episodes are always kept.")
        }
    }

    private var generalSection: some View {
        Section {
            Toggle(L10n.string("Auto-Download New Episodes"), isOn: self.$autoDownload)
                .onChange(of: self.autoDownload) { _, new in
                    Task { await self.vm.setAutoDownload(new, podcastID: self.podcastID) }
                }
            LabeledContent(L10n.string("Show Type"), value: self.showTypeLabel)
        }
    }
}
