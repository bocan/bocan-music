#import "RenderProbe.h"

#import <malloc/malloc.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdlib.h>

// The allocator calls this hook, when set, for every allocation and free. It is
// what MallocStackLogging uses. Bit 1 of `type` marks an allocation.
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
                              uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;

static const uint32_t kAllocateFlag = 2;

static pthread_t gProbeThread;
static atomic_long gAllocations;

static void BocanProbeLogger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
                             uint32_t num_hot_frames_to_skip) {
    if ((type & kAllocateFlag) != 0 && pthread_equal(pthread_self(), gProbeThread)) {
        atomic_fetch_add(&gAllocations, 1);
    }
}

/// A two-channel, non-interleaved buffer list over the given channel memory.
static AudioBufferList *BocanMakeStereoList(float *left, float *right, AUAudioFrameCount frames) {
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    list->mNumberBuffers = 2;
    list->mBuffers[0].mNumberChannels = 1;
    list->mBuffers[0].mDataByteSize = frames * sizeof(float);
    list->mBuffers[0].mData = left;
    list->mBuffers[1].mNumberChannels = 1;
    list->mBuffers[1].mDataByteSize = frames * sizeof(float);
    list->mBuffers[1].mData = right;
    return list;
}

/// The input is already in the output buffers, so the pull has nothing to do.
static const AURenderPullInputBlock kPullInPlace =
    ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, AUAudioFrameCount frameCount,
                       NSInteger bus, AudioBufferList *data) {
      return noErr;
    };

AUAudioUnitStatus BocanRenderInPlace(AUAudioUnit *unit, float *left, float *right, AUAudioFrameCount frames) {
    AUInternalRenderBlock render = unit.internalRenderBlock;
    AudioBufferList *list = BocanMakeStereoList(left, right, frames);
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp = {0};
    AUAudioUnitStatus status = render(&flags, &timestamp, frames, 0, list, NULL, kPullInPlace);
    free(list);
    return status;
}

long BocanCountRenderAllocations(AUAudioUnit *unit, AUAudioFrameCount frames, int cycles) {
    AUInternalRenderBlock render = unit.internalRenderBlock;
    float *left = calloc(frames, sizeof(float));
    float *right = calloc(frames, sizeof(float));
    AudioBufferList *list = BocanMakeStereoList(left, right, frames);
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp = {0};

    // The hook and its counters are process-wide, and tests run in parallel.
    static pthread_mutex_t probeLock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&probeLock);
    gProbeThread = pthread_self();
    malloc_logger_t *previous = malloc_logger;
    malloc_logger = BocanProbeLogger;

    // Self-check: the hook must see a plain allocation on this thread. The
    // pointer is volatile so that an optimized build keeps the allocation.
    atomic_store(&gAllocations, 0);
    void *volatile canary = malloc(32);
    long seen = atomic_load(&gAllocations);
    atomic_store(&gAllocations, 0);

    for (int cycle = 0; cycle < cycles; cycle++) {
        render(&flags, &timestamp, frames, 0, list, NULL, kPullInPlace);
    }
    long allocations = atomic_load(&gAllocations);

    malloc_logger = previous;
    pthread_mutex_unlock(&probeLock);
    free(canary);
    free(list);
    free(left);
    free(right);
    return seen == 1 ? allocations : -1;
}
