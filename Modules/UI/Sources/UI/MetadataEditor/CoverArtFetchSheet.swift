import Library
import SwiftUI

// MARK: - CoverArtFetchSheet

/// Search + results picker for cover art from MusicBrainz / Cover Art Archive.
public struct CoverArtFetchSheet: View {
    @ObservedObject public var vm: CoverArtFetchViewModel
    @Binding public var isPresented: Bool
    public var onSelect: (Data) -> Void

    public init(
        vm: CoverArtFetchViewModel,
        isPresented: Binding<Bool>,
        onSelect: @escaping (Data) -> Void
    ) {
        self.vm = vm
        self._isPresented = isPresented
        self.onSelect = onSelect
    }

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12),
    ]

    public var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Artist", text: self.$vm.searchArtist)
                        .textFieldStyle(.roundedBorder)
                    TextField("Album", text: self.$vm.searchAlbum)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Search") { self.vm.search() }
                    .keyboardShortcut(.return)
                    .disabled(self.vm.searchArtist.isEmpty && self.vm.searchAlbum.isEmpty)
            }
            .padding()

            Divider()

            // Results grid
            if self.vm.isSearching {
                ProgressView("Searching…")
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = self.vm.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.candidates.isEmpty {
                Text("No results")
                    .foregroundStyle(Color.textTertiary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: self.columns, spacing: 12) {
                        ForEach(self.vm.candidates) { candidate in
                            CandidateCell(
                                candidate: candidate,
                                thumbnail: self.vm.thumbnails[candidate.id],
                                isSelected: self.vm.selectedCandidateID == candidate.id
                            )
                            .onTapGesture {
                                self.vm.selectedCandidateID = candidate.id
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Bottom actions
            HStack {
                Spacer()
                Button("Cancel") { self.isPresented = false }
                    .keyboardShortcut(.escape)
                Button("Apply") {
                    guard let id = self.vm.selectedCandidateID else { return }
                    Task {
                        if let data = try? await self.vm.fullImage(for: id) {
                            self.onSelect(data)
                            self.isPresented = false
                        }
                    }
                }
                .disabled(self.vm.selectedCandidateID == nil)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { self.vm.search() }
    }
}

// MARK: - CandidateCell

private struct CandidateCell: View {
    let candidate: CoverArtCandidate
    let thumbnail: Data?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let data = self.thumbnail, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(self.isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            Text(self.candidate.title)
                .font(.caption)
                .lineLimit(1)
            if let year = self.candidate.year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.candidate.title) by \(self.candidate.artist)")
    }
}

import AppKit
