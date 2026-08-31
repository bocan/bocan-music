import AudioEngine
import Foundation
import Observability

// MARK: - TranscodeSettings

/// The transcode choice riding in the sync-profile blob (ADR-088).
public struct TranscodeSettings: Sendable, Codable, Equatable {
    /// The chosen quality rung; `nil` means Original (no transcoding).
    public var preset: TranscodePreset?
    /// Keep prepared artifacts after they are served (the fast re-sync
    /// toggle). Off by default: prepare-and-release.
    public var keepArtifacts: Bool

    public init(preset: TranscodePreset? = nil, keepArtifacts: Bool = false) {
        self.preset = preset
        self.keepArtifacts = keepArtifacts
    }

    /// No transcoding: today's behaviour, and the default.
    public static let original = TranscodeSettings()
}

// MARK: - SyncProfileDocument

/// The full content of the `sync_profile` blob: the selection (`SyncProfile`)
/// plus the transcode settings (ADR-088).
///
/// Decoding is backward compatible: a legacy blob is a bare `SyncProfile`
/// enum (`{"everything":{...}}` / `{"selected":{...}}`), which decodes with
/// `.original` transcode settings. New blobs are keyed
/// `{"profile":...,"transcode":...}`. All readers and writers of the blob go
/// through this type; nothing decodes a bare `SyncProfile` any more.
public struct SyncProfileDocument: Sendable, Codable, Equatable {
    public var profile: SyncProfile
    public var transcode: TranscodeSettings

    public init(profile: SyncProfile, transcode: TranscodeSettings = .original) {
        self.profile = profile
        self.transcode = transcode
    }

    public static let `default` = SyncProfileDocument(profile: .default)

    private enum CodingKeys: String, CodingKey {
        case profile
        case transcode
    }

    /// Swift.Decoder spelled out: AudioEngine exports an audio `Decoder`
    /// protocol that would otherwise win the name lookup here.
    public init(from decoder: any Swift.Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if keyed.contains(.profile) {
            self.profile = try keyed.decode(SyncProfile.self, forKey: .profile)
            self.transcode = try keyed.decodeIfPresent(TranscodeSettings.self, forKey: .transcode) ?? .original
        } else {
            // Legacy blob: the bare SyncProfile enum at the top level.
            let single = try decoder.singleValueContainer()
            self.profile = try single.decode(SyncProfile.self)
            self.transcode = .original
        }
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        var keyed = encoder.container(keyedBy: CodingKeys.self)
        try keyed.encode(self.profile, forKey: .profile)
        try keyed.encode(self.transcode, forKey: .transcode)
    }

    /// Decodes stored blob bytes, falling back to the default document for a
    /// missing or unreadable blob (the same fallback the profile always had).
    public static func decode(_ data: Data?) -> SyncProfileDocument {
        guard let data else { return .default }
        do {
            return try JSONDecoder().decode(SyncProfileDocument.self, from: data)
        } catch {
            AppLogger.make(.sync).warning("sync.profile.undecodable", [
                "error": String(reflecting: error),
            ])
            return .default
        }
    }

    /// Encoded blob bytes for `SyncProfileRepository.setProfileJSON`.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
