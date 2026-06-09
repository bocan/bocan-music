import Persistence
import SwiftUI

// MARK: - File Info & Advanced tabs

extension TagEditorSheet {
    // MARK: - File Info tab

    @ViewBuilder var fileInfoTab: some View {
        if let track = self.vm.singleTrack {
            Form {
                Section(L10n.string("Audio")) {
                    LabeledContent(L10n.string("Format")) {
                        Text(track.fileFormat.uppercased())
                    }
                    .help(L10n.string("Audio codec / container format"))

                    if let bitDepth = track.bitDepth {
                        LabeledContent(L10n.string("Bit Depth")) {
                            Text(localized: "\(bitDepth)-bit")
                        }
                    }

                    LabeledContent(L10n.string("Sample Rate")) {
                        Text(Self.formatSampleRate(track.sampleRate))
                    }

                    if let bitrate = track.bitrate {
                        LabeledContent(L10n.string("Bitrate")) {
                            Text(localized: "\(bitrate) kbps")
                        }
                    }

                    LabeledContent(L10n.string("Duration")) {
                        Text(Self.formatDuration(track.duration))
                    }

                    if let channels = track.channelCount {
                        LabeledContent(L10n.string("Channels")) {
                            Text(Self.formatChannels(channels))
                        }
                    }

                    if let lossless = track.isLossless {
                        LabeledContent(L10n.string("Lossless")) {
                            Text(lossless ? L10n.string("Yes") : L10n.string("No"))
                        }
                    }
                }

                if track.replaygainTrackGain != nil
                    || track.replaygainAlbumGain != nil
                    || track.replaygainTrackPeak != nil
                    || track.replaygainAlbumPeak != nil {
                    Section(L10n.string("ReplayGain")) {
                        if let tg = track.replaygainTrackGain {
                            LabeledContent(L10n.string("Track Gain")) {
                                Text(Self.formatGain(tg))
                            }
                            .help(L10n.string("EBU R128 / ReplayGain track-level loudness adjustment"))
                        }
                        if let tp = track.replaygainTrackPeak {
                            LabeledContent(L10n.string("Track Peak")) {
                                Text(Self.formatPeak(tp))
                            }
                            .help(L10n.string("Sample peak level for this track"))
                        }
                        if let ag = track.replaygainAlbumGain {
                            LabeledContent(L10n.string("Album Gain")) {
                                Text(Self.formatGain(ag))
                            }
                            .help(L10n.string("EBU R128 / ReplayGain album-level loudness adjustment"))
                        }
                        if let ap = track.replaygainAlbumPeak {
                            LabeledContent(L10n.string("Album Peak")) {
                                Text(Self.formatPeak(ap))
                            }
                            .help(L10n.string("Sample peak level for the album"))
                        }
                    }
                }

                Section(L10n.string("File")) {
                    LabeledContent(L10n.string("Size")) {
                        Text(Self.formatFileSize(track.fileSize))
                    }

                    LabeledContent(L10n.string("Location")) {
                        Text(track.filePathDisplay ?? track.fileURL)
                            .textSelection(.enabled)
                            .font(Typography.footnote)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .help(track.fileURL)

                    LabeledContent(L10n.string("Date Added")) {
                        Text(Self.formatDate(track.addedAt))
                    }

                    LabeledContent(L10n.string("Date Modified")) {
                        Text(Self.formatDate(track.fileMtime))
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        } else {
            ContentUnavailableView(
                L10n.string("Multiple Files Selected"),
                systemImage: "doc.on.doc",
                description: Text(localized: "Select a single track to view its file information.")
            )
            .padding()
        }
    }

    // MARK: - Advanced tab

    @ViewBuilder var advancedTab: some View {
        if let track = self.vm.singleTrack {
            Form {
                Section(L10n.string("Edit History")) {
                    LabeledContent(L10n.string("Manually Edited")) {
                        HStack(spacing: 6) {
                            Text(track.userEdited ? L10n.string("Yes") : L10n.string("No"))

                            if track.userEdited {
                                Image(systemName: "pencil.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .help(L10n.string("When Yes, library rescans will not overwrite your manual tag changes."))
                }

                Section(L10n.string("Play Statistics")) {
                    LabeledContent(L10n.string("Play Count")) {
                        Text(verbatim: String(track.playCount))
                    }

                    LabeledContent(L10n.string("Skip Count")) {
                        Text(verbatim: String(track.skipCount))
                    }

                    if let lastPlayed = track.lastPlayedAt {
                        LabeledContent(L10n.string("Last Played")) {
                            Text(Self.formatDate(lastPlayed))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        } else {
            ContentUnavailableView(
                L10n.string("Multiple Files Selected"),
                systemImage: "doc.on.doc",
                description: Text(localized: "Select a single track to view its information.")
            )
            .padding()
        }
    }

    // MARK: - Formatting helpers

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func formatSampleRate(_ hz: Int?) -> String {
        guard let hz else { return "—" }
        let khz = Double(hz) / 1000.0
        if khz == khz.rounded() {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }

    private static func formatChannels(_ count: Int) -> String {
        switch count {
        case 1:
            "1 (Mono)"

        case 2:
            "2 (Stereo)"

        default:
            "\(count)"
        }
    }

    private static func formatDate(_ epochSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(epochSeconds))
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func formatGain(_ dB: Double) -> String {
        String(format: "%+.2f dB", dB)
    }

    private static func formatPeak(_ peak: Double) -> String {
        String(format: "%.6f", peak)
    }
}
