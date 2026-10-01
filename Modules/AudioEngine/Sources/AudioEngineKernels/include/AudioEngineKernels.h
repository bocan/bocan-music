#import <AudioToolbox/AudioToolbox.h>

// The render blocks of the custom audio units, in Objective-C.
//
// A render block runs on the real-time audio thread on every cycle. A Swift
// closure there allocates: the bridge from the block Core Audio passes to a
// Swift closure boxes the pull-input block once per cycle in every build, and
// an unoptimized build adds an allocation per sample and runtime metadata
// lookups. A block written here does none of that in any build configuration.
//
// Each class owns its render state and overrides `internalRenderBlock`. The
// override must stay in Objective-C: a Swift override that returned one of
// these blocks would wrap it in a Swift closure and put the bridge back.
// The Swift subclasses in `AudioEngine/DSP` add the buses, the parameter tree
// and the registration, and write parameters through `renderState`.

NS_ASSUME_NONNULL_BEGIN

/// Render-thread state of the stereo-width unit.
typedef struct {
    /// Side-signal multiplier: 1 leaves the signal unchanged.
    float width;
} BocanStereoExpanderState;

/// Render-thread state of the crossfeed unit.
typedef struct {
    /// Crossfeed amount, 0 (off) to 1.
    float amount;
    /// First-order low-pass coefficient; depends on the sample rate.
    float lpAlpha;
    /// Low-pass state of the left channel, which feeds the right output.
    float stateL;
    /// Low-pass state of the right channel, which feeds the left output.
    float stateR;
} BocanCrossfeedState;

/// Mid/side stereo width: `M = (L + R) / 2`, `S = (L - R) / 2 * width`.
@interface BocanStereoExpanderKernelUnit : AUAudioUnit
/// Written from the parameter thread, read on the render thread. An aligned
/// 4-byte float is in effect atomic on arm64.
@property(nonatomic, readonly) BocanStereoExpanderState *renderState;
@end

/// Bauer crossfeed: each output gets the low-passed opposite input at
/// `amount * 0.333`.
@interface BocanCrossfeedKernelUnit : AUAudioUnit
@property(nonatomic, readonly) BocanCrossfeedState *renderState;
@end

NS_ASSUME_NONNULL_END
