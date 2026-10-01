#import "AudioEngineKernels.h"

#import <math.h>
#import <stdlib.h>

/// Applies the parameter events of this cycle. Both units have one parameter,
/// at address 0. Returns the new value, or `current` when there is no event.
static inline float BocanLatestParameter(const AURenderEvent *_Nullable event, float current) {
    float value = current;
    while (event != NULL) {
        if ((event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp) &&
            event->parameter.parameterAddress == 0) {
            value = event->parameter.value;
        }
        event = event->head.next;
    }
    return value;
}

/// The two channels of a non-interleaved stereo buffer list. Returns false
/// when the list is not stereo, and the caller then passes the audio through.
static inline bool BocanStereoChannels(AudioBufferList *data, float *_Nullable *_Nonnull left,
                                       float *_Nullable *_Nonnull right) {
    if (data->mNumberBuffers < 2) {
        return false;
    }
    *left = (float *)data->mBuffers[0].mData;
    *right = (float *)data->mBuffers[1].mData;
    return *left != NULL && *right != NULL;
}

// MARK: - Stereo width

@implementation BocanStereoExpanderKernelUnit

- (nullable instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                              options:(AudioComponentInstantiationOptions)options
                                                error:(NSError **)outError {
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (self != nil) {
        _renderState = calloc(1, sizeof(BocanStereoExpanderState));
        _renderState->width = 1.0f;
    }
    return self;
}

- (void)dealloc {
    free(_renderState);
}

- (AUInternalRenderBlock)internalRenderBlock {
    // Capture only the raw pointer, never `self`.
    BocanStereoExpanderState *state = _renderState;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount, NSInteger outputBusNumber, AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead, AURenderPullInputBlock pullInputBlock) {
      state->width = BocanLatestParameter(realtimeEventListHead, state->width);

      if (pullInputBlock == nil) {
          return kAudioUnitErr_NoConnection;
      }
      AudioUnitRenderActionFlags pullFlags = 0;
      AUAudioUnitStatus status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
      if (status != noErr) {
          return status;
      }

      const float width = state->width;
      // At unity width the mid/side transform is an identity; skip the math.
      if (fabsf(width - 1.0f) <= 1e-4f) {
          return noErr;
      }
      float *left;
      float *right;
      if (!BocanStereoChannels(outputData, &left, &right)) {
          return noErr;
      }

      for (AUAudioFrameCount i = 0; i < frameCount; i++) {
          const float l = left[i];
          const float r = right[i];
          const float mid = 0.5f * (l + r);
          const float side = 0.5f * (l - r) * width;
          left[i] = mid + side;
          right[i] = mid - side;
      }
      return noErr;
    };
}

@end

// MARK: - Crossfeed

@implementation BocanCrossfeedKernelUnit

- (nullable instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                              options:(AudioComponentInstantiationOptions)options
                                                error:(NSError **)outError {
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (self != nil) {
        _renderState = calloc(1, sizeof(BocanCrossfeedState));
    }
    return self;
}

- (void)dealloc {
    free(_renderState);
}

- (AUInternalRenderBlock)internalRenderBlock {
    BocanCrossfeedState *state = _renderState;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount, NSInteger outputBusNumber, AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead, AURenderPullInputBlock pullInputBlock) {
      state->amount = BocanLatestParameter(realtimeEventListHead, state->amount);

      if (pullInputBlock == nil) {
          return kAudioUnitErr_NoConnection;
      }
      AudioUnitRenderActionFlags pullFlags = 0;
      AUAudioUnitStatus status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
      if (status != noErr) {
          return status;
      }

      const float amount = state->amount;
      // Transparent when off.
      if (amount <= 1e-4f) {
          return noErr;
      }
      float *left;
      float *right;
      if (!BocanStereoChannels(outputData, &left, &right)) {
          return noErr;
      }

      const float alpha = state->lpAlpha;
      float lowL = state->stateL;
      float lowR = state->stateR;
      // Cross-talk level is about -9.5 dB at amount = 1.
      const float level = amount * 0.333f;

      for (AUAudioFrameCount i = 0; i < frameCount; i++) {
          const float l = left[i];
          const float r = right[i];
          // First-order IIR low-pass on each channel.
          lowL = alpha * lowL + (1.0f - alpha) * l;
          lowR = alpha * lowR + (1.0f - alpha) * r;
          // Mix the filtered opposite channel in.
          left[i] = l + level * lowR;
          right[i] = r + level * lowL;
      }

      state->stateL = lowL;
      state->stateR = lowR;
      return noErr;
    };
}

@end
