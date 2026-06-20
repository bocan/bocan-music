import SwiftUI

/// A chapter list shown in a Now Playing popover. Tapping a chapter seeks via the
/// supplied closure (which routes through the player's transport, never the engine).
/// Chapter titles are feed content, rendered verbatim.
struct ChapterListView: View {
    let chapters: [UIChapter]
    let currentID: Int?
    let onSeek: (TimeInterval) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localized: "Chapters")
                .font(.headline)
                .padding([.horizontal, .top])
            Divider().padding(.top, 8)
            if self.chapters.isEmpty {
                ContentUnavailableView(L10n.string("No chapters"), systemImage: "list.bullet")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(self.chapters) { chapter in
                            self.row(chapter)
                        }
                    }
                }
            }
        }
        .frame(width: 320, height: 380)
    }

    private func row(_ chapter: UIChapter) -> some View {
        Button {
            Task { await self.onSeek(chapter.startTime) }
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: chapter.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: TranscriptView.timestamp(chapter.startTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .fontWeight(chapter.id == self.currentID ? .bold : .regular)
            .contentShape(Rectangle())
            .padding(.horizontal)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            L10n.string("Chapter: \(chapter.title) at \(TranscriptView.timestamp(chapter.startTime))")
        )
    }
}
