import Persistence
import SwiftUI

// MARK: - File Info & Advanced tabs

extension TagEditorSheet {
    // MARK: - File Info tab

    @ViewBuilder var fileInfoTab: some View {
        if let track = self.vm.singleTrack {
            Form {
                Section("Audio") {
                    LabeledContent("Format") {
                        Text(track.fileFormat.uppercased())
                    }
                    .help("Audio codec / container format")

                    if let bitDepth = track.bitDepth {
                        LabeledContent("Bit Depth") {
                            Text("\(bitDepth)-bit")
                        }
                    }

                    LabeledContent("Sample Rate") {
                        Text(Self.formatSampleRate(track.sampleRate))
                    }

                    if let bitrate = track.bitrate {
                        LabeledContent("Bitrate") {
                            Text("\(bitrate) kbps")
                        }
                    }

                    LabeledContent("Duration") {
                        Text(Self.formatDuration(track.duration))
                    }

                    if let channels = track.channelCount {
                        LabeledContent("Channels") {
                            Text(Self.formatChannels(channels))
                        }
                    }

                    if let lossless = track.isLossless {
                        LabeledContent("Lossless") {
                            Text(lossless ? "Yes" : "No")
                        }
                    }
                }

                Section("File") {
                    LabeledContent("Size") {
                        Text(Self.formatFileSize(track.fileSize))
                    }

                    LabeledContent("Location") {
                        Text(track.filePathDisplay ?? track.fileURL)
                            .textSelection(.enabled)
                            .font(Typography.footnote)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .help(track.fileURL)

                    LabeledContent("Date Added") {
                        Text(Self.formatDate(track.addedAt))
                    }

                    LabeledContent("Date Modified") {
                        Text(Self.formatDate(track.fileMtime))
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        } else {
            ContentUnavailableView(
                "Multiple Files Selected",
                systemImage: "doc.on.doc",
                description: Text("Select a single track to view its file information.")
            )
            .padding()
        }
    }

    // MARK: - Advanced tab

    @ViewBuilder var advancedTab: some View {
        if let track = self.vm.singleTrack {
            Form {
                Section("Edit History") {
                    LabeledContent("Manually Edited") {
                        HStack(spacing: 6) {
                            Text(track.userEdited ? "Yes" : "No")

                            if track.userEdited {
                                Image(systemName: "pencil.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .help("When Yes, library rescans will not overwrite your manual tag changes.")
                }

                Section("Play Statistics") {
                    LabeledContent("Play Count") {
                        Text("\(track.playCount)")
                    }

                    LabeledContent("Skip Count") {
                        Text("\(track.skipCount)")
                    }

                    if let lastPlayed = track.lastPlayedAt {
                        LabeledContent("Last Played") {
                            Text(Self.formatDate(lastPlayed))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        } else {
            ContentUnavailableView(
                "Multiple Files Selected",
                systemImage: "doc.on.doc",
                description: Text("Select a single track to view its information.")
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
}
