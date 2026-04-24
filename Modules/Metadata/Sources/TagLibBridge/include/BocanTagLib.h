#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Raw cover art extracted from a file.
@interface BOCCoverArt : NSObject

/// Image bytes (JPEG, PNG, etc.).
@property (nonatomic, strong, readonly) NSData *data;
/// MIME type string, e.g. @"image/jpeg".
@property (nonatomic, copy, readonly) NSString *mimeType;
/// APIC / PIC picture type (0 = Other, 3 = Front Cover).
@property (nonatomic, assign, readonly) NSInteger pictureType;

- (instancetype)initWithData:(NSData *)data
                    mimeType:(NSString *)mimeType
                 pictureType:(NSInteger)pictureType;

@end

// ---------------------------------------------------------------------------

/// Flat bag of tag fields extracted from a file.
@interface BOCTags : NSObject

// Core
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic, copy, nullable) NSString *albumArtist;
@property (nonatomic, copy, nullable) NSString *album;
@property (nonatomic, copy, nullable) NSString *genre;
@property (nonatomic, copy, nullable) NSString *composer;
@property (nonatomic, copy, nullable) NSString *comment;
@property (nonatomic, assign) NSInteger year;
@property (nonatomic, copy, nullable) NSString *dateText;
@property (nonatomic, assign) NSInteger trackNumber;
@property (nonatomic, assign) NSInteger trackTotal;
@property (nonatomic, assign) NSInteger discNumber;
@property (nonatomic, assign) NSInteger discTotal;

// Extended
@property (nonatomic, copy, nullable) NSString *sortTitle;
@property (nonatomic, copy, nullable) NSString *sortArtist;
@property (nonatomic, copy, nullable) NSString *sortAlbumArtist;
@property (nonatomic, copy, nullable) NSString *sortAlbum;
@property (nonatomic, copy, nullable) NSString *lyrics;
@property (nonatomic, assign) double bpm;
@property (nonatomic, copy, nullable) NSString *key;
@property (nonatomic, copy, nullable) NSString *isrc;

// MusicBrainz
@property (nonatomic, copy, nullable) NSString *musicbrainzTrackID;
@property (nonatomic, copy, nullable) NSString *musicbrainzRecordingID;
@property (nonatomic, copy, nullable) NSString *musicbrainzAlbumArtistID;
@property (nonatomic, copy, nullable) NSString *musicbrainzReleaseID;
@property (nonatomic, copy, nullable) NSString *musicbrainzReleaseGroupID;

// ReplayGain
@property (nonatomic, assign) double replaygainTrackGain;   // dB; NAN = absent
@property (nonatomic, assign) double replaygainTrackPeak;   // 0..1; NAN = absent
@property (nonatomic, assign) double replaygainAlbumGain;   // dB; NAN = absent
@property (nonatomic, assign) double replaygainAlbumPeak;   // 0..1; NAN = absent
// EBU R128 (stored as Q7.8 fixed-point integer ÷ 256)
@property (nonatomic, assign) double r128TrackGain;         // NAN = absent
@property (nonatomic, assign) double r128AlbumGain;         // NAN = absent

// Cover art
@property (nonatomic, strong) NSArray<BOCCoverArt *> *coverArt;

// Audio properties
@property (nonatomic, assign) double duration;      // seconds
@property (nonatomic, assign) NSInteger sampleRate; // Hz
@property (nonatomic, assign) NSInteger bitrate;    // kbps
@property (nonatomic, assign) NSInteger channels;
@property (nonatomic, assign) NSInteger bitDepth;   // 0 = unknown

@end

// ---------------------------------------------------------------------------

/// Entry point: reads metadata from a local file via TagLib.
@interface BOCTagLibBridge : NSObject

/// Returns `BOCTags` for the file at `path`, or `nil` + sets `error` on failure.
+ (nullable BOCTags *)readTagsFromPath:(NSString *)path
                                 error:(NSError *__autoreleasing _Nullable *)error;

@end

// ---------------------------------------------------------------------------

/// Writes metadata to an audio file via TagLib.
///
/// The caller is responsible for atomic-file safety (copy → write to copy →
/// fsync → rename). This class only performs the TagLib write itself.
@interface BOCTagWriter : NSObject

/// Writes `tags` to the audio file at `path`.
///
/// Only non-nil / non-zero fields in `tags` are written; existing values for
/// fields that map to nil / zero are left unchanged.
///
/// Returns YES on success, NO + sets `error` on failure.
+ (BOOL)writeTagsToPath:(NSString *)path
                   tags:(BOCTags *)tags
                  error:(NSError *__autoreleasing _Nullable *)outError;

@end

NS_ASSUME_NONNULL_END
