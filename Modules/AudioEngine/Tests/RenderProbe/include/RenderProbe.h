#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

/// Calls the unit's `internalRenderBlock` `cycles` times on the calling thread,
/// the way Core Audio calls it, and returns the number of heap allocations that
/// thread made during those calls.
///
/// The caller is Objective-C on purpose: a Swift caller would add its own
/// bridging allocations to the count.
///
/// Returns -1 when the allocation hook does not report, so a test can tell
/// "no allocations" from "the probe is blind".
long BocanCountRenderAllocations(AUAudioUnit *unit, AUAudioFrameCount frames, int cycles);

/// Renders one cycle through the unit's `internalRenderBlock` in place:
/// `left` and `right` hold the input and receive the output.
AUAudioUnitStatus BocanRenderInPlace(AUAudioUnit *unit, float *left, float *right, AUAudioFrameCount frames);

NS_ASSUME_NONNULL_END
