#import "BocanTagLib.h"

// TagLib 2.x headers — included in a plain .mm so the ObjC++ compiler
// handles the C++ includes; no Swift translation unit ever sees these.
#include <taglib.h>
#include <fileref.h>
#include <tag.h>
#include <tpropertymap.h>
#include <tvariant.h>
#include <audioproperties.h>
#include <tstring.h>
#include <tstringlist.h>

#include <cmath>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static NSString *_Nullable tagStringToNS(const TagLib::String &s) {
    if (s.isEmpty()) return nil;
    return [NSString stringWithUTF8String:s.toCString(true)];
}

static NSString *_Nullable firstValue(const TagLib::PropertyMap &props,
                                      const char *key) {
    TagLib::String k(key);
    if (props.contains(k)) {
        const auto &list = props[k];
        if (!list.isEmpty()) {
            return tagStringToNS(list.front());
        }
    }
    return nil;
}

static double replayGainDB(const TagLib::PropertyMap &props, const char *key) {
    NSString *raw = firstValue(props, key);
    if (!raw) return NAN;
    // Format: "-3.21 dB" or "-3.21" (strip suffix)
    NSString *trimmed = [[raw stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]]
        componentsSeparatedByString:@" "].firstObject ?: raw;
    double v = trimmed.doubleValue;
    return v;
}

static double replayGainPeak(const TagLib::PropertyMap &props, const char *key) {
    NSString *raw = firstValue(props, key);
    if (!raw) return NAN;
    double v = raw.doubleValue;
    return (v == 0.0 && ![raw hasPrefix:@"0"]) ? NAN : v;
}

/// EBU R128 Q7.8 fixed-point → dB
static double r128Gain(const TagLib::PropertyMap &props, const char *key) {
    NSString *raw = firstValue(props, key);
    if (!raw) return NAN;
    long long q = raw.longLongValue;
    // 0x7FFF sentinel (TagLib default "not set") → NAN
    if (q == 0x7FFF) return NAN;
    return (double)q / 256.0;
}

// ---------------------------------------------------------------------------
// BOCCoverArt
// ---------------------------------------------------------------------------

@implementation BOCCoverArt
- (instancetype)initWithData:(NSData *)data
                    mimeType:(NSString *)mimeType
                 pictureType:(NSInteger)pictureType {
    self = [super init];
    if (self) {
        _data = data;
        _mimeType = [mimeType copy];
        _pictureType = pictureType;
    }
    return self;
}
@end

// ---------------------------------------------------------------------------
// BOCTags
// ---------------------------------------------------------------------------

@implementation BOCTags
- (instancetype)init {
    self = [super init];
    if (self) {
        _coverArt = @[];
        _replaygainTrackGain = NAN;
        _replaygainTrackPeak = NAN;
        _replaygainAlbumGain = NAN;
        _replaygainAlbumPeak = NAN;
        _r128TrackGain = NAN;
        _r128AlbumGain = NAN;
    }
    return self;
}
@end

// ---------------------------------------------------------------------------
// BOCTagLibBridge
// ---------------------------------------------------------------------------

@implementation BOCTagLibBridge

+ (nullable BOCTags *)readTagsFromPath:(NSString *)path
                                 error:(NSError *__autoreleasing _Nullable *)outError {
    TagLib::FileRef fileRef(
        [path fileSystemRepresentation],
        /* readAudioProperties */ true,
        TagLib::AudioProperties::Fast
    );

    if (fileRef.isNull() || !fileRef.tag()) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"io.cloudcauldron.bocan.metadata"
                                           code:1
                                       userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"TagLib could not open file: %@", path]
            }];
        }
        return nil;
    }

    BOCTags *tags = [[BOCTags alloc] init];

    // -----------------------------------------------------------------------
    // Basic tag fields
    // -----------------------------------------------------------------------
    auto *tag = fileRef.tag();
    tags.title  = tagStringToNS(tag->title());
    tags.artist = tagStringToNS(tag->artist());
    tags.album  = tagStringToNS(tag->album());
    tags.genre  = tagStringToNS(tag->genre());
    tags.comment = tagStringToNS(tag->comment());
    tags.year   = (NSInteger)tag->year();
    tags.trackNumber = (NSInteger)tag->track();

    // -----------------------------------------------------------------------
    // PropertyMap (extended tags)
    // -----------------------------------------------------------------------
    TagLib::PropertyMap props = fileRef.properties();

    tags.albumArtist    = firstValue(props, "ALBUMARTIST");
    tags.composer       = firstValue(props, "COMPOSER");
    tags.sortTitle      = firstValue(props, "TITLESORT");
    tags.sortArtist     = firstValue(props, "ARTISTSORT");
    tags.sortAlbumArtist = firstValue(props, "ALBUMARTISTSORT");
    tags.sortAlbum      = firstValue(props, "ALBUMSORT");
    tags.lyrics         = firstValue(props, "LYRICS");
    tags.key            = firstValue(props, "INITIALKEY");
    tags.isrc           = firstValue(props, "ISRC");

    // BPM
    NSString *bpmStr = firstValue(props, "BPM");
    tags.bpm = bpmStr ? bpmStr.doubleValue : 0.0;

    // Track / disc totals (may appear as "N/M" in trackNumber or as separate tags)
    NSString *trackTotalStr = firstValue(props, "TRACKTOTAL");
    if (!trackTotalStr) trackTotalStr = firstValue(props, "TOTALTRACKS");
    tags.trackTotal = trackTotalStr ? (NSInteger)trackTotalStr.integerValue : 0;

    NSString *discNumberStr = firstValue(props, "DISCNUMBER");
    tags.discNumber = discNumberStr ? (NSInteger)discNumberStr.integerValue : 0;
    NSString *discTotalStr  = firstValue(props, "DISCTOTAL");
    if (!discTotalStr) discTotalStr = firstValue(props, "TOTALDISCS");
    tags.discTotal  = discTotalStr  ? (NSInteger)discTotalStr.integerValue  : 0;

    // MusicBrainz
    tags.musicbrainzTrackID       = firstValue(props, "MUSICBRAINZ_TRACKID");
    tags.musicbrainzRecordingID   = firstValue(props, "MUSICBRAINZ_RELEASETRACKID");
    tags.musicbrainzAlbumArtistID = firstValue(props, "MUSICBRAINZ_ALBUMARTISTID");
    tags.musicbrainzReleaseID     = firstValue(props, "MUSICBRAINZ_ALBUMID");
    tags.musicbrainzReleaseGroupID = firstValue(props, "MUSICBRAINZ_RELEASEGROUPID");

    // ReplayGain
    tags.replaygainTrackGain = replayGainDB(props,   "REPLAYGAIN_TRACK_GAIN");
    tags.replaygainTrackPeak = replayGainPeak(props, "REPLAYGAIN_TRACK_PEAK");
    tags.replaygainAlbumGain = replayGainDB(props,   "REPLAYGAIN_ALBUM_GAIN");
    tags.replaygainAlbumPeak = replayGainPeak(props, "REPLAYGAIN_ALBUM_PEAK");

    // EBU R128 (stored as Q7.8 integer strings)
    tags.r128TrackGain = r128Gain(props, "R128_TRACK_GAIN");
    tags.r128AlbumGain = r128Gain(props, "R128_ALBUM_GAIN");

    // -----------------------------------------------------------------------
    // Cover art (TagLib 2.0 complexProperties API)
    // -----------------------------------------------------------------------
    auto pictureList = fileRef.complexProperties("PICTURE");
    NSMutableArray<BOCCoverArt *> *arts = [NSMutableArray array];
    for (const auto &pic : pictureList) {
        // data
        NSData *imgData = nil;
        if (pic.contains(TagLib::String("data"))) {
            const auto &v = pic[TagLib::String("data")];
            auto byteVec = v.value<TagLib::ByteVector>();
            imgData = [NSData dataWithBytes:byteVec.data() length:byteVec.size()];
        }
        if (!imgData || imgData.length == 0) continue;

        // mimeType
        NSString *mime = @"image/jpeg";
        if (pic.contains(TagLib::String("mimeType"))) {
            const auto &mv = pic[TagLib::String("mimeType")];
            NSString *ms = tagStringToNS(mv.value<TagLib::String>());
            if (ms.length > 0) mime = ms;
        }

        // pictureType (0 = Other, 3 = Front Cover)
        NSInteger picType = 0;
        if (pic.contains(TagLib::String("pictureType"))) {
            const auto &tv = pic[TagLib::String("pictureType")];
            picType = (NSInteger)tv.value<int>();
        }

        [arts addObject:[[BOCCoverArt alloc] initWithData:imgData
                                                 mimeType:mime
                                              pictureType:picType]];
    }
    tags.coverArt = [arts copy];

    // -----------------------------------------------------------------------
    // Audio properties
    // -----------------------------------------------------------------------
    if (auto *ap = fileRef.audioProperties()) {
        tags.duration   = ap->lengthInSeconds();
        tags.sampleRate = ap->sampleRate();
        tags.bitrate    = ap->bitrate();
        tags.channels   = ap->channels();
        // bitDepth: not on AudioProperties base, but many subclasses have it.
        // We attempt a cast to a type that might have it; fall back to 0.
        // (Doing it via properties() is safer and format-agnostic.)
        NSString *bdStr = firstValue(props, "BITSPERSAMPLE");
        tags.bitDepth = bdStr ? (NSInteger)bdStr.integerValue : 0;
    }

    return tags;
}

@end
