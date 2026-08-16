import AudioEngine
import Persistence
import SwiftUI

// MARK: - RadioStationInfoSheet

/// Station metadata plus the stream facts (ADR-078 slice 5). While the station is
/// playing, `liveDetails` carries what the open decoder measured (container,
/// codec and profile, sample rate, channels, claimed bitrate, ICY headers);
/// otherwise the sheet falls back to the profile persisted on the last
/// successful connect. Stream URL is copyable; the homepage opens in the
/// default browser.
struct RadioStationInfoSheet: View {
    let station: RadioStation
    var liveDetails: StreamDetails?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(self.station.name)
                    .font(Typography.title)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
            }

            self.field(label: L10n.string("Stream URL"), value: self.station.streamURL, copyable: true)

            if let home = self.homePage, let url = URL(string: home) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized: "Homepage")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    Link(home, destination: url)
                        .font(Typography.subheadline)
                        .lineLimit(2)
                }
            }

            if let genre = self.genre {
                self.field(label: L10n.string("Genre"), value: genre, copyable: false)
            }
            if let description = self.stationDescription {
                self.field(label: L10n.string("Description"), value: description, copyable: false)
            }

            if !self.streamFacts.isEmpty {
                self.streamFactsSection
            }

            if let connectedAt = station.lastConnectedAt, self.liveDetails == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized: "Last Connected")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    Text(
                        Date(timeIntervalSince1970: TimeInterval(connectedAt)),
                        format: .dateTime.day().month().year().hour().minute()
                    )
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityIdentifier(A11y.Radio.infoValue("lastConnected"))
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("Close"), action: self.onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(A11y.Radio.infoCloseButton)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480)
    }

    // MARK: - Stream facts

    private var streamFactsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.liveDetails != nil ? L10n.string("Live Stream") : L10n.string("Last Connection"))
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            ForEach(self.streamFacts, id: \.key) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 120, alignment: .leading)
                    Text(row.value)
                        .font(Typography.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(A11y.Radio.infoValue(row.key))
                }
            }
        }
    }

    /// One stream-facts row. `key` is a stable, non-localized slug for
    /// `A11y.Radio.infoValue(_:)` — `label` is `L10n`-translated and must
    /// stay free to change.
    private struct StreamFact {
        let key: String
        let label: String
        let value: String
    }

    /// Live decoder facts when playing; the persisted profile otherwise.
    private var streamFacts: [StreamFact] {
        var rows: [StreamFact] = []
        if let live = self.liveDetails {
            if let container = live.container {
                rows.append(StreamFact(key: "container", label: L10n.string("Container"), value: container))
            }
            if let codec = live.codecDisplay {
                rows.append(StreamFact(key: "codec", label: L10n.string("Codec"), value: codec))
            }
            if live.sampleRateHz > 0 {
                rows.append(StreamFact(
                    key: "sampleRate",
                    label: L10n.string("Sample Rate"),
                    value: Self.sampleRateText(live.sampleRateHz)
                ))
            }
            if live.channelCount > 0 {
                rows.append(StreamFact(
                    key: "channels",
                    label: L10n.string("Channels"),
                    value: Self.channelsText(live.channelCount)
                ))
            }
            if let kbps = live.claimedBitrateKbps {
                rows.append(StreamFact(key: "bitrate", label: L10n.string("Bitrate"), value: L10n.string("\(kbps) kbps")))
            }
            rows.append(StreamFact(
                key: "nowPlayingTitles",
                label: L10n.string("Now-Playing Titles"),
                value: live.supportsIcyMetadata ? L10n.string("Supported") : L10n.string("Not supported")
            ))
        } else {
            if let container = self.station.lastContainer {
                rows.append(StreamFact(key: "container", label: L10n.string("Container"), value: container))
            }
            if let codec = self.station.lastCodec {
                rows.append(StreamFact(key: "codec", label: L10n.string("Codec"), value: codec))
            }
            if let hz = self.station.lastSampleRateHz {
                rows.append(StreamFact(key: "sampleRate", label: L10n.string("Sample Rate"), value: Self.sampleRateText(hz)))
            }
            if let channels = self.station.lastChannels {
                rows.append(StreamFact(
                    key: "channels",
                    label: L10n.string("Channels"),
                    value: Self.channelsText(channels)
                ))
            }
            if let kbps = self.station.lastBitrateKbps {
                rows.append(StreamFact(key: "bitrate", label: L10n.string("Bitrate"), value: L10n.string("\(kbps) kbps")))
            }
        }
        return rows
    }

    // MARK: - Merged station fields

    private var homePage: String? {
        let value = self.station.homePageURL ?? self.liveDetails?.icyURL
        return (value?.isEmpty ?? true) ? nil : value
    }

    private var genre: String? {
        let value = self.station.genre ?? self.liveDetails?.icyGenre
        return (value?.isEmpty ?? true) ? nil : value
    }

    private var stationDescription: String? {
        let value = self.station.stationDescription ?? self.liveDetails?.icyDescription
        return (value?.isEmpty ?? true) ? nil : value
    }

    // MARK: - Formatting

    /// "44.1 kHz" / "48 kHz": whole kilohertz drop the decimal.
    static func sampleRateText(_ hz: Int) -> String {
        let khz: String = hz.isMultiple(of: 1000)
            ? String(hz / 1000)
            : String(format: "%.1f", Double(hz) / 1000)
        return L10n.string("\(khz) kHz")
    }

    static func channelsText(_ count: Int) -> String {
        switch count {
        case 1:
            L10n.string("Mono")

        case 2:
            L10n.string("Stereo")

        default:
            L10n.string("\(count) channels")
        }
    }

    private func field(label: String, value: String, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                if copyable {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(value, forType: .string)
                    } label: {
                        Label(L10n.string("Copy"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Text(value)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}
