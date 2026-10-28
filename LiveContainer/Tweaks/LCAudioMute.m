//
//  LCAudioMute.m
//  LiveContainer
//
//  Per-window volume for multitask guests: a gain from silent to full, applied
//  to one window without touching the others.
//
//  iOS has no per-process volume, and hosting a scene gives the host no say
//  over what its guest sends to the mixer: each multitask guest is a separate
//  process holding its own AVAudioSession, feeding the system output directly.
//  The only place a single guest can be silenced is inside that guest, which is
//  where this runs — installed during bootstrap, before the app binary is
//  dlopened, so it sits in front of every audio path the app later builds.
//
//  Two things happen here. A *muted* guest is moved to mixWithOthers, and every
//  output path this process can reach is given a mute switch.
//
//  Mixing is scoped to the mute, not applied to every guest, and that is not a
//  detail: a session carrying mixWithOthers is secondary audio, and secondary
//  audio is not eligible to keep playing once its app leaves the foreground.
//  Pinning it on unconditionally silences every guest the moment you leave
//  LiveContainer — background playback, the thing multitask windows are most
//  useful for, gone. Scoped this way each side gets what it needs: the muted
//  window stops holding the primary audio role hostage, so the audible window
//  keeps it and keeps playing in the background, and the muted window has no
//  audio to lose by becoming secondary. Two *unmuted* guests still contend for
//  primary audio, exactly as they did before any of this existed — and that is
//  the case you would reach for mute to resolve anyway.
//
//  The output paths the gain is applied to:
//
//    - render callbacks installed on any AudioUnit are wrapped, and their
//      buffers scaled sample by sample on the way out. This is what catches
//      games: Unity, FMOD, OpenAL, SDL and the rest never touch an ObjC audio
//      class, they hand RemoteIO a C function pointer and fill buffers on a
//      realtime thread. Scaling needs the unit's sample format, which is read
//      off the unit itself; silence is a memset and needs nothing.
//    - AudioQueue volume, and the volume of every AVAudioPlayer, AVPlayer,
//      AVAudioEngine mixer or player node, and AVSampleBufferAudioRenderer the
//      app creates, are multiplied by the gain. AVPlayer especially cannot be
//      reached any other way — its audio is rendered by mediaserverd, out of
//      this process entirely, so there are no buffers here to touch.
//    - WKWebView is the one all-or-nothing path: WebKit's page-muted SPI is a
//      switch, so a web view is silent at zero and untouched anywhere above it.
//
//  Throughout, the app's own volume is remembered and the gain multiplies it, so
//  a window at 40% is at 40% of whatever the app set — and returning to full
//  gives back the app's level rather than a guess at 1.0.
//
//  The host sends the level over a Darwin notification named for the guest's
//  container, which is the only channel left between the two processes once the
//  extension request has been delivered.
//
@import Foundation;
@import ObjectiveC;

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <stdatomic.h>
#import <pthread.h>

#import "Tweaks.h"
#import "LCSharedUtils.h"
#import "../../litehook/src/litehook.h"

// Every selector here belongs to a framework this file deliberately does not
// import, so none of them are declared in this translation unit.
#pragma clang diagnostic ignored "-Wundeclared-selector"

#pragma mark - CoreAudio declarations

// Spelled out rather than imported: <AudioToolbox/AudioToolbox.h> is a module,
// and importing it autolinks AudioToolbox into LiveContainer itself, which would
// drag the whole audio stack into the address space of every guest — including
// the ones that never play a sound. Everything below is looked up by name at
// runtime instead, so a process without AudioToolbox simply gets no hooks.

typedef struct OpaqueAudioComponentInstance *LCAudioUnit;
typedef UInt32 LCAudioUnitPropertyID;
typedef UInt32 LCAudioUnitScope;
typedef UInt32 LCAudioUnitElement;
typedef UInt32 LCAudioUnitRenderActionFlags;

typedef struct LCAudioBuffer {
    UInt32 mNumberChannels;
    UInt32 mDataByteSize;
    void *mData;
} LCAudioBuffer;

typedef struct LCAudioBufferList {
    UInt32 mNumberBuffers;
    LCAudioBuffer mBuffers[1];
} LCAudioBufferList;

typedef OSStatus (*LCAURenderCallback)(void *inRefCon,
                                       LCAudioUnitRenderActionFlags *ioActionFlags,
                                       const void *inTimeStamp,
                                       UInt32 inBusNumber,
                                       UInt32 inNumberFrames,
                                       LCAudioBufferList *ioData);

typedef struct LCAURenderCallbackStruct {
    LCAURenderCallback inputProc;
    void *inputProcRefCon;
} LCAURenderCallbackStruct;

typedef struct OpaqueAudioQueue *LCAudioQueueRef;

typedef struct LCStreamBasicDescription {
    Float64 mSampleRate;
    UInt32 mFormatID;
    UInt32 mFormatFlags;
    UInt32 mBytesPerPacket;
    UInt32 mFramesPerPacket;
    UInt32 mBytesPerFrame;
    UInt32 mChannelsPerFrame;
    UInt32 mBitsPerChannel;
    UInt32 mReserved;
} LCStreamBasicDescription;

enum {
    kLCAudioUnitProperty_StreamFormat = 8,
    kLCAudioUnitProperty_SetRenderCallback = 23,
    kLCAudioUnitScope_Input = 1,
    kLCAudioUnitRenderAction_OutputIsSilence = (1 << 4),
    kLCAudioQueueParam_Volume = 1,
    kLCAudioFormatLinearPCM = 'lpcm',
    kLCAudioFormatFlagIsFloat = (1 << 0),
    kLCAudioFormatFlagIsSignedInteger = (1 << 2),
};

// A render buffer can only be scaled by a gain if its sample layout is known, so
// the layout is boiled down to these few bits and read as one atomic word from
// the realtime thread. Anything not listed is left alone rather than guessed at:
// scaling 32-bit integers as though they were floats produces noise, which is
// considerably worse than a volume slider that does nothing on that path.
enum {
    kLCSampleFormatValid  = (1 << 0),
    kLCSampleFormatFloat32 = (1 << 1),
    kLCSampleFormatInt16  = (1 << 2),
    kLCSampleFormatInt32  = (1 << 3),
};

// AVAudioSessionCategoryOptionMixWithOthers
static const NSUInteger kLCMixWithOthers = 1;
// _WKMediaMutedStateAudioIsMuted
static const NSUInteger kLCWebKitAudioIsMuted = 1;

#pragma mark - State

// The window's gain, 0 through 1. Read from realtime audio threads, where a lock
// or an ObjC message send would be a dropout waiting to happen. Relaxed ordering
// is all this needs: a render pass that straddles a change may go out at the old
// setting, and the next one — a few milliseconds later — will not.
static _Atomic float gGain = 1.0f;

static float lcGain(void) {
    return atomic_load_explicit(&gGain, memory_order_relaxed);
}

// Full silence, as opposed to merely quiet. Kept distinct because the two are
// not the same thing to the system: only a fully muted window gives up its
// primary-audio role, and a window at 10% still expects to play in the
// background.
static bool lcIsMuted(void) {
    return lcGain() <= 0.0f;
}

static NSLock *gRegistryLock;
static NSHashTable *gAudioPlayers;
static NSHashTable *gPlayers;
static NSHashTable *gMixerNodes;
static NSHashTable *gWebViews;
static NSHashTable *gSampleBufferRenderers;
static NSHashTable *gPlayerNodes;

static const void *kIntendedVolumeKey = &kIntendedVolumeKey;
static const void *kIntendedMutedKey = &kIntendedMutedKey;

static void lcRegisterObject(NSHashTable *table, id object) {
    if(!object || !table) return;
    [gRegistryLock lock];
    [table addObject:object];
    [gRegistryLock unlock];
}

static NSArray *lcRegisteredObjects(NSHashTable *table) {
    if(!table) return @[];
    [gRegistryLock lock];
    NSArray *objects = table.allObjects;
    [gRegistryLock unlock];
    return objects;
}

#pragma mark - AudioUnit render callbacks

// The app's callback and its refCon, kept together so the wrapper can find them
// with a single pointer dereference and no lookup — the wrapper runs on the
// realtime thread, where searching a table for the matching unit is not an
// option.
typedef struct {
    LCAURenderCallback proc;
    void *refCon;
    LCAudioUnit unit;
    LCAudioUnitElement element;
    _Atomic uint32_t sampleFormat;
} LCWrappedRenderCallback;

static OSStatus (*orig_AudioUnitSetProperty)(LCAudioUnit, LCAudioUnitPropertyID, LCAudioUnitScope, LCAudioUnitElement, const void *, UInt32);
static OSStatus (*orig_AudioUnitGetProperty)(LCAudioUnit, LCAudioUnitPropertyID, LCAudioUnitScope, LCAudioUnitElement, void *, UInt32 *);
static OSStatus (*orig_AUGraphSetNodeInputCallback)(void *, SInt32, UInt32, const LCAURenderCallbackStruct *);

// Wrappers are kept so a later stream-format change can be picked up: an app is
// free to install its callback first and settle the format afterwards, and the
// scaling code has to know which it ended up with.
#define LC_MAX_TRACKED_CALLBACKS 64
static pthread_mutex_t gWrapperLock = PTHREAD_MUTEX_INITIALIZER;
static LCWrappedRenderCallback *gWrappers[LC_MAX_TRACKED_CALLBACKS];
static int gWrapperCount = 0;

static uint32_t lcPackSampleFormat(const LCStreamBasicDescription *format) {
    if(format->mFormatID != kLCAudioFormatLinearPCM) return 0;
    if(format->mFormatFlags & kLCAudioFormatFlagIsFloat) {
        return format->mBitsPerChannel == 32 ? (kLCSampleFormatValid | kLCSampleFormatFloat32) : 0;
    }
    if(format->mFormatFlags & kLCAudioFormatFlagIsSignedInteger) {
        // 32-bit covers the old 8.24 fixed-point canonical format too: scaling a
        // fixed-point sample by a gain is the same multiply either way.
        if(format->mBitsPerChannel == 16) return kLCSampleFormatValid | kLCSampleFormatInt16;
        if(format->mBitsPerChannel == 32) return kLCSampleFormatValid | kLCSampleFormatInt32;
    }
    return 0;
}

static void lcRefreshSampleFormat(LCWrappedRenderCallback *wrapped) {
    if(!orig_AudioUnitGetProperty || !wrapped->unit) return;
    LCStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    OSStatus status = orig_AudioUnitGetProperty(wrapped->unit, kLCAudioUnitProperty_StreamFormat, kLCAudioUnitScope_Input, wrapped->element, &format, &size);
    atomic_store_explicit(&wrapped->sampleFormat, status == noErr ? lcPackSampleFormat(&format) : 0, memory_order_relaxed);
}

static void lcTrackWrapper(LCWrappedRenderCallback *wrapped) {
    pthread_mutex_lock(&gWrapperLock);
    if(gWrapperCount < LC_MAX_TRACKED_CALLBACKS) {
        gWrappers[gWrapperCount++] = wrapped;
    }
    pthread_mutex_unlock(&gWrapperLock);
}

static void lcRefreshWrappersForUnit(LCAudioUnit unit, LCAudioUnitElement element) {
    LCWrappedRenderCallback *matches[LC_MAX_TRACKED_CALLBACKS];
    int count = 0;
    pthread_mutex_lock(&gWrapperLock);
    for(int i = 0; i < gWrapperCount; i++) {
        if(gWrappers[i]->unit == unit && gWrappers[i]->element == element) {
            matches[count++] = gWrappers[i];
        }
    }
    pthread_mutex_unlock(&gWrapperLock);
    for(int i = 0; i < count; i++) {
        lcRefreshSampleFormat(matches[i]);
    }
}

static OSStatus lc_renderCallback(void *inRefCon,
                                  LCAudioUnitRenderActionFlags *ioActionFlags,
                                  const void *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  LCAudioBufferList *ioData) {
    LCWrappedRenderCallback *wrapped = inRefCon;
    OSStatus status = wrapped->proc(wrapped->refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);

    // Let the app render as it normally would and alter the result, rather than
    // skipping its callback: engines drive their own clocks off these calls, and
    // one that stopped being asked for audio would drift, stall its streaming,
    // or read the silence as a stall and rebuffer.
    float gain = lcGain();
    if(gain >= 1.0f || !ioData) {
        return status;
    }

    if(gain <= 0.0f) {
        for(UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            if(ioData->mBuffers[i].mData) {
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
            }
        }
        if(ioActionFlags) {
            *ioActionFlags |= kLCAudioUnitRenderAction_OutputIsSilence;
        }
        return status;
    }

    uint32_t format = atomic_load_explicit(&wrapped->sampleFormat, memory_order_relaxed);
    if(!(format & kLCSampleFormatValid)) {
        return status;
    }
    for(UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        void *data = ioData->mBuffers[i].mData;
        UInt32 bytes = ioData->mBuffers[i].mDataByteSize;
        if(!data) continue;
        if(format & kLCSampleFormatFloat32) {
            float *samples = data;
            for(UInt32 s = 0; s < bytes / sizeof(float); s++) samples[s] *= gain;
        } else if(format & kLCSampleFormatInt16) {
            int16_t *samples = data;
            for(UInt32 s = 0; s < bytes / sizeof(int16_t); s++) samples[s] = (int16_t)(samples[s] * gain);
        } else if(format & kLCSampleFormatInt32) {
            int32_t *samples = data;
            for(UInt32 s = 0; s < bytes / sizeof(int32_t); s++) samples[s] = (int32_t)(samples[s] * gain);
        }
    }
    return status;
}

static OSStatus lc_AudioUnitSetProperty(LCAudioUnit unit, LCAudioUnitPropertyID inID, LCAudioUnitScope inScope, LCAudioUnitElement inElement, const void *inData, UInt32 inDataSize) {
    if(inID == kLCAudioUnitProperty_SetRenderCallback && inData && inDataSize >= sizeof(LCAURenderCallbackStruct)) {
        const LCAURenderCallbackStruct *callback = inData;
        // Skip our own wrapper: an app that reads the property back and sets it
        // again would otherwise be wrapped twice, and each layer leaks.
        if(callback->inputProc && callback->inputProc != lc_renderCallback) {
            LCWrappedRenderCallback *wrapped = calloc(1, sizeof(LCWrappedRenderCallback));
            if(wrapped) {
                wrapped->proc = callback->inputProc;
                wrapped->refCon = callback->inputProcRefCon;
                wrapped->unit = unit;
                wrapped->element = inElement;
                lcRefreshSampleFormat(wrapped);
                lcTrackWrapper(wrapped);
                LCAURenderCallbackStruct replacement = { lc_renderCallback, wrapped };
                // Never freed. The unit outlives the callback in every sane
                // sequence, and a free here would race the realtime thread that
                // is reading it — a few dozen bytes per callback installation is
                // the cheaper end of that trade.
                return orig_AudioUnitSetProperty(unit, inID, inScope, inElement, &replacement, (UInt32)sizeof(replacement));
            }
        }
    }

    OSStatus status = orig_AudioUnitSetProperty(unit, inID, inScope, inElement, inData, inDataSize);
    // The other order: callback first, format settled afterwards. Read back what
    // the unit actually accepted rather than trusting what was asked for.
    if(inID == kLCAudioUnitProperty_StreamFormat && status == noErr && inScope == kLCAudioUnitScope_Input) {
        lcRefreshWrappersForUnit(unit, inElement);
    }
    return status;
}

// AUGraph reaches AudioUnitSetProperty by an internal call, and rebinding a
// symbol only patches what other images import — an app driving its graph
// through AUGraph would otherwise hand its callback straight past the hook
// above. Older engines still do.
// Mute-only, not attenuation: a graph node is not an AudioUnit, so there is no
// unit here to ask for a sample format, and zeroing a buffer is the one change
// that is correct without knowing one.
static OSStatus lc_AUGraphSetNodeInputCallback(void *graph, SInt32 node, UInt32 inputNumber, const LCAURenderCallbackStruct *callback) {
    if(callback && callback->inputProc && callback->inputProc != lc_renderCallback) {
        LCWrappedRenderCallback *wrapped = calloc(1, sizeof(LCWrappedRenderCallback));
        if(wrapped) {
            wrapped->proc = callback->inputProc;
            wrapped->refCon = callback->inputProcRefCon;
            LCAURenderCallbackStruct replacement = { lc_renderCallback, wrapped };
            return orig_AUGraphSetNodeInputCallback(graph, node, inputNumber, &replacement);
        }
    }
    return orig_AUGraphSetNodeInputCallback(graph, node, inputNumber, callback);
}

#pragma mark - AudioQueue

// AudioQueue has a volume parameter, so nothing needs zeroing by hand — the
// queues just have to be found again when the state changes. A fixed table
// keeps that off the allocator and off any ObjC machinery; an app holding more
// than this many output queues at once is not a real one.
#define LC_MAX_TRACKED_QUEUES 32

static pthread_mutex_t gQueueLock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    LCAudioQueueRef queue;
    Float32 intendedVolume;
} gQueues[LC_MAX_TRACKED_QUEUES];

static OSStatus (*orig_AudioQueueSetParameter)(LCAudioQueueRef, UInt32, Float32);
static OSStatus (*orig_AudioQueueNewOutput)(const void *, void *, void *, void *, void *, UInt32, LCAudioQueueRef *);
static OSStatus (*orig_AudioQueueNewOutputWithDispatchQueue)(LCAudioQueueRef *, const void *, UInt32, dispatch_queue_t, void *);
static OSStatus (*orig_AudioQueueDispose)(LCAudioQueueRef, Boolean);

static void lcTrackQueue(LCAudioQueueRef queue) {
    if(!queue) return;
    pthread_mutex_lock(&gQueueLock);
    for(int i = 0; i < LC_MAX_TRACKED_QUEUES; i++) {
        if(gQueues[i].queue == NULL || gQueues[i].queue == queue) {
            gQueues[i].queue = queue;
            gQueues[i].intendedVolume = 1.0f;
            break;
        }
    }
    pthread_mutex_unlock(&gQueueLock);
    if(lcGain() < 1.0f && orig_AudioQueueSetParameter) {
        orig_AudioQueueSetParameter(queue, kLCAudioQueueParam_Volume, lcGain());
    }
}

static void lcForgetQueue(LCAudioQueueRef queue) {
    pthread_mutex_lock(&gQueueLock);
    for(int i = 0; i < LC_MAX_TRACKED_QUEUES; i++) {
        if(gQueues[i].queue == queue) {
            gQueues[i].queue = NULL;
        }
    }
    pthread_mutex_unlock(&gQueueLock);
}

static void lcApplyGainToQueues(float gain) {
    if(!orig_AudioQueueSetParameter) return;
    pthread_mutex_lock(&gQueueLock);
    struct { LCAudioQueueRef queue; Float32 volume; } pending[LC_MAX_TRACKED_QUEUES];
    int count = 0;
    for(int i = 0; i < LC_MAX_TRACKED_QUEUES; i++) {
        if(gQueues[i].queue) {
            pending[count].queue = gQueues[i].queue;
            pending[count].volume = gQueues[i].intendedVolume * gain;
            count++;
        }
    }
    pthread_mutex_unlock(&gQueueLock);
    // Outside the lock: AudioQueueSetParameter can block on the queue's own
    // thread, and this lock is also taken from the app's audio setup path.
    for(int i = 0; i < count; i++) {
        orig_AudioQueueSetParameter(pending[i].queue, kLCAudioQueueParam_Volume, pending[i].volume);
    }
}

static OSStatus lc_AudioQueueSetParameter(LCAudioQueueRef queue, UInt32 paramID, Float32 value) {
    if(paramID != kLCAudioQueueParam_Volume) {
        return orig_AudioQueueSetParameter(queue, paramID, value);
    }
    // Remember what the app wanted even while muted, so unmuting restores the
    // level it thinks it is playing at rather than a flat 1.0.
    pthread_mutex_lock(&gQueueLock);
    bool tracked = false;
    for(int i = 0; i < LC_MAX_TRACKED_QUEUES; i++) {
        if(gQueues[i].queue == queue) {
            gQueues[i].intendedVolume = value;
            tracked = true;
            break;
        }
    }
    pthread_mutex_unlock(&gQueueLock);
    if(!tracked) {
        lcTrackQueue(queue);
        pthread_mutex_lock(&gQueueLock);
        for(int i = 0; i < LC_MAX_TRACKED_QUEUES; i++) {
            if(gQueues[i].queue == queue) {
                gQueues[i].intendedVolume = value;
                break;
            }
        }
        pthread_mutex_unlock(&gQueueLock);
    }
    return orig_AudioQueueSetParameter(queue, paramID, value * lcGain());
}

static OSStatus lc_AudioQueueNewOutput(const void *inFormat, void *inCallbackProc, void *inUserData, void *inCallbackRunLoop, void *inCallbackRunLoopMode, UInt32 inFlags, LCAudioQueueRef *outAQ) {
    OSStatus status = orig_AudioQueueNewOutput(inFormat, inCallbackProc, inUserData, inCallbackRunLoop, inCallbackRunLoopMode, inFlags, outAQ);
    if(status == noErr && outAQ) {
        lcTrackQueue(*outAQ);
    }
    return status;
}

static OSStatus lc_AudioQueueNewOutputWithDispatchQueue(LCAudioQueueRef *outAQ, const void *inFormat, UInt32 inFlags, dispatch_queue_t inCallbackDispatchQueue, void *inCallbackBlock) {
    OSStatus status = orig_AudioQueueNewOutputWithDispatchQueue(outAQ, inFormat, inFlags, inCallbackDispatchQueue, inCallbackBlock);
    if(status == noErr && outAQ) {
        lcTrackQueue(*outAQ);
    }
    return status;
}

static OSStatus lc_AudioQueueDispose(LCAudioQueueRef queue, Boolean immediate) {
    lcForgetQueue(queue);
    return orig_AudioQueueDispose(queue, immediate);
}

#pragma mark - AVAudioSession

static BOOL (*orig_setCategoryError)(id, SEL, NSString *, NSError **);
static BOOL (*orig_setCategoryOptionsError)(id, SEL, NSString *, NSUInteger, NSError **);
static BOOL (*orig_setCategoryModeOptionsError)(id, SEL, NSString *, NSString *, NSUInteger, NSError **);
static BOOL (*orig_setCategoryModePolicyOptionsError)(id, SEL, NSString *, NSString *, NSUInteger, NSUInteger, NSError **);

// Only these three take mixWithOthers. Handing the option to Record makes the
// setter fail outright, which would leave the app with no session at all —
// a far worse outcome than the interruption this is trying to avoid.
static BOOL lcCategoryAcceptsMixing(NSString *category) {
    return [category isEqualToString:@"AVAudioSessionCategoryPlayback"] ||
           [category isEqualToString:@"AVAudioSessionCategoryPlayAndRecord"] ||
           [category isEqualToString:@"AVAudioSessionCategoryMultiRoute"];
}

// SoloAmbient means "mix with nobody", so there is no option to add to it —
// Ambient is the same category with mixing already on.
static NSString *lcMixableCategory(NSString *category) {
    if([category isEqualToString:@"AVAudioSessionCategorySoloAmbient"]) {
        return @"AVAudioSessionCategoryAmbient";
    }
    return category;
}

static NSUInteger lcMixableOptions(NSString *category, NSUInteger options) {
    return lcCategoryAcceptsMixing(category) ? (options | kLCMixWithOthers) : options;
}

// What the app last asked for, kept so the session can be put back exactly as it
// wanted it the moment the window is unmuted — including the SoloAmbient it may
// have chosen, which mixing has to rewrite and unmuting has to restore.
static pthread_mutex_t gCategoryLock = PTHREAD_MUTEX_INITIALIZER;
typedef enum {
    LCCategoryVariantNone = 0,
    LCCategoryVariantPlain,
    LCCategoryVariantOptions,
    LCCategoryVariantModeOptions,
    LCCategoryVariantPolicyOptions,
} LCCategoryVariant;
static LCCategoryVariant gAppCategoryVariant = LCCategoryVariantNone;
static NSString *gAppCategory;
static NSString *gAppMode;
static NSUInteger gAppPolicy;
static NSUInteger gAppOptions;

static void lcRecordCategory(LCCategoryVariant variant, NSString *category, NSString *mode, NSUInteger policy, NSUInteger options) {
    pthread_mutex_lock(&gCategoryLock);
    gAppCategoryVariant = variant;
    gAppCategory = category;
    gAppMode = mode;
    gAppPolicy = policy;
    gAppOptions = options;
    pthread_mutex_unlock(&gCategoryLock);
}

// Re-runs the app's own most recent setCategory call, adding or dropping mixing
// to match the mute state. Called when that state changes; a no-op for an app
// that has never set a category, which is then still on the default and has had
// nothing done to it.
static void lcReapplyCategory(void) {
    pthread_mutex_lock(&gCategoryLock);
    LCCategoryVariant variant = gAppCategoryVariant;
    NSString *category = gAppCategory;
    NSString *mode = gAppMode;
    NSUInteger policy = gAppPolicy;
    NSUInteger options = gAppOptions;
    pthread_mutex_unlock(&gCategoryLock);

    if(variant == LCCategoryVariantNone || !category) return;
    Class sessionClass = NSClassFromString(@"AVAudioSession");
    if(!sessionClass) return;
    id session = ((id (*)(id, SEL))objc_msgSend)(sessionClass, @selector(sharedInstance));
    if(!session) return;

    if(lcIsMuted()) {
        category = lcMixableCategory(category);
        options = lcMixableOptions(category, options);
    }

    NSError *error = nil;
    switch(variant) {
        case LCCategoryVariantPlain:
            if(options && orig_setCategoryOptionsError) {
                orig_setCategoryOptionsError(session, @selector(setCategory:withOptions:error:), category, options, &error);
            } else if(orig_setCategoryError) {
                orig_setCategoryError(session, @selector(setCategory:error:), category, &error);
            }
            break;
        case LCCategoryVariantOptions:
            if(orig_setCategoryOptionsError) {
                orig_setCategoryOptionsError(session, @selector(setCategory:withOptions:error:), category, options, &error);
            }
            break;
        case LCCategoryVariantModeOptions:
            if(orig_setCategoryModeOptionsError) {
                orig_setCategoryModeOptionsError(session, @selector(setCategory:mode:options:error:), category, mode, options, &error);
            }
            break;
        case LCCategoryVariantPolicyOptions:
            if(orig_setCategoryModePolicyOptionsError) {
                orig_setCategoryModePolicyOptionsError(session, @selector(setCategory:mode:routeSharingPolicy:options:error:), category, mode, policy, options, &error);
            }
            break;
        case LCCategoryVariantNone:
            break;
    }
    if(error) {
        NSLog(@"[LCAudioMute] re-applying category %@ failed: %@", category, error);
    }
}

static BOOL lc_setCategoryError(id self, SEL sel, NSString *category, NSError **error) {
    lcRecordCategory(LCCategoryVariantPlain, category, nil, 0, 0);
    if(!lcIsMuted()) {
        return orig_setCategoryError(self, sel, category, error);
    }
    NSString *mixable = lcMixableCategory(category);
    NSUInteger options = lcMixableOptions(mixable, 0);
    if(options && orig_setCategoryOptionsError) {
        return orig_setCategoryOptionsError(self, @selector(setCategory:withOptions:error:), mixable, options, error);
    }
    return orig_setCategoryError(self, sel, mixable, error);
}

static BOOL lc_setCategoryOptionsError(id self, SEL sel, NSString *category, NSUInteger options, NSError **error) {
    lcRecordCategory(LCCategoryVariantOptions, category, nil, 0, options);
    if(!lcIsMuted()) {
        return orig_setCategoryOptionsError(self, sel, category, options, error);
    }
    NSString *mixable = lcMixableCategory(category);
    return orig_setCategoryOptionsError(self, sel, mixable, lcMixableOptions(mixable, options), error);
}

static BOOL lc_setCategoryModeOptionsError(id self, SEL sel, NSString *category, NSString *mode, NSUInteger options, NSError **error) {
    lcRecordCategory(LCCategoryVariantModeOptions, category, mode, 0, options);
    if(!lcIsMuted()) {
        return orig_setCategoryModeOptionsError(self, sel, category, mode, options, error);
    }
    NSString *mixable = lcMixableCategory(category);
    return orig_setCategoryModeOptionsError(self, sel, mixable, mode, lcMixableOptions(mixable, options), error);
}

static BOOL lc_setCategoryModePolicyOptionsError(id self, SEL sel, NSString *category, NSString *mode, NSUInteger policy, NSUInteger options, NSError **error) {
    lcRecordCategory(LCCategoryVariantPolicyOptions, category, mode, policy, options);
    if(!lcIsMuted()) {
        return orig_setCategoryModePolicyOptionsError(self, sel, category, mode, policy, options, error);
    }
    NSString *mixable = lcMixableCategory(category);
    return orig_setCategoryModePolicyOptionsError(self, sel, mixable, mode, policy, lcMixableOptions(mixable, options), error);
}

#pragma mark - AVAudioPlayer / AVPlayer / AVAudioEngine / WKWebView

static void (*orig_AVAudioPlayer_setVolume)(id, SEL, float);
static BOOL (*orig_AVAudioPlayer_play)(id, SEL);
static BOOL (*orig_AVAudioPlayer_prepareToPlay)(id, SEL);
static void (*orig_AVPlayer_setVolume)(id, SEL, float);
static void (*orig_AVPlayer_setMuted)(id, SEL, BOOL);
static void (*orig_AVPlayer_play)(id, SEL);
static void (*orig_AVPlayer_setRate)(id, SEL, float);
static void (*orig_AVPlayer_playImmediatelyAtRate)(id, SEL, float);
static void (*orig_AVPlayer_replaceCurrentItem)(id, SEL, id);
static id   (*orig_AVAudioEngine_mainMixerNode)(id, SEL);
static void (*orig_AVAudioMixerNode_setOutputVolume)(id, SEL, float);
static id   (*orig_WKWebView_initWithFrame)(id, SEL, CGRect, id);
static void (*orig_AVAudioPlayerNode_play)(id, SEL);
static void (*orig_AVAudioPlayerNode_setVolume)(id, SEL, float);
static void (*orig_AVSampleBufferAudioRenderer_setVolume)(id, SEL, float);
static void (*orig_AVSampleBufferAudioRenderer_setMuted)(id, SEL, BOOL);
static void (*orig_AVSampleBufferRenderSynchronizer_addRenderer)(id, SEL, id);

static float lcFloatProperty(id object, SEL selector) {
    return ((float (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL lcBoolProperty(id object, SEL selector) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

// The level the app believes is in effect, recorded the first time this window
// touches an object and never overwritten by our own scaling. It is what makes
// the slider mean "40% of what the app asked for" rather than "40% of full", and
// what lets a return to full hand back the exact level the app chose instead of
// a guess at 1.0.
static float lcIntendedVolume(id object, SEL getter) {
    NSNumber *stored = objc_getAssociatedObject(object, kIntendedVolumeKey);
    if(stored) return stored.floatValue;
    float current = lcFloatProperty(object, getter);
    objc_setAssociatedObject(object, kIntendedVolumeKey, @(current), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return current;
}

// The app's own mute switch, recorded the same way — and it has to be recorded
// before silence forces the switch on. Read for the first time afterwards, it
// takes our YES for the app's choice, and the object stays muted at every level
// from then on.
static BOOL lcIntendedMuted(id object) {
    NSNumber *stored = objc_getAssociatedObject(object, kIntendedMutedKey);
    if(stored) return stored.boolValue;
    BOOL current = lcBoolProperty(object, @selector(isMuted));
    objc_setAssociatedObject(object, kIntendedMutedKey, @(current), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return current;
}

static void lcApplyGainToAudioPlayer(id player, float gain) {
    if(!orig_AVAudioPlayer_setVolume) return;
    orig_AVAudioPlayer_setVolume(player, @selector(setVolume:), lcIntendedVolume(player, @selector(volume)) * gain);
}

static void lcApplyGainToPlayer(id player, float gain) {
    if(orig_AVPlayer_setVolume) {
        orig_AVPlayer_setVolume(player, @selector(setVolume:), lcIntendedVolume(player, @selector(volume)) * gain);
    }
    // AVPlayer carries a separate mute switch. Scaling the volume would be
    // enough, but at full silence both are set: it costs nothing, and it covers
    // a route that honours one and ignores the other.
    if(orig_AVPlayer_setMuted) {
        // Read even at silence, where it goes unused: the mute button jumps
        // straight to zero, so a tap is often the first time this player is
        // touched at all. A slider drag passes through some level on the way
        // down, which is the only reason that route never lost the sound.
        BOOL appMuted = lcIntendedMuted(player);
        orig_AVPlayer_setMuted(player, @selector(setMuted:), gain <= 0.0f ? YES : appMuted);
    }
}

static void lcApplyGainToMixerNode(id node, float gain) {
    if(!orig_AVAudioMixerNode_setOutputVolume) return;
    orig_AVAudioMixerNode_setOutputVolume(node, @selector(setOutputVolume:), lcIntendedVolume(node, @selector(outputVolume)) * gain);
}

// A player node feeding the engine's output directly, with no main mixer in
// between — the shape an app takes when it decodes audio itself and hands the
// engine finished PCM.
static void lcApplyGainToPlayerNode(id node, float gain) {
    if(!orig_AVAudioPlayerNode_setVolume) return;
    orig_AVAudioPlayerNode_setVolume(node, @selector(setVolume:), lcIntendedVolume(node, @selector(volume)) * gain);
}

// The other out-of-process renderer, alongside AVPlayer: apps that feed decoded
// samples to a renderer and drive it with a synchronizer never create an
// AVPlayer at all, and their audio is mixed by mediaserverd all the same.
static void lcApplyGainToSampleBufferRenderer(id renderer, float gain) {
    if(orig_AVSampleBufferAudioRenderer_setVolume) {
        orig_AVSampleBufferAudioRenderer_setVolume(renderer, @selector(setVolume:), lcIntendedVolume(renderer, @selector(volume)) * gain);
    }
    if(orig_AVSampleBufferAudioRenderer_setMuted) {
        // Read before forcing it on, as for AVPlayer above.
        BOOL appMuted = lcIntendedMuted(renderer);
        orig_AVSampleBufferAudioRenderer_setMuted(renderer, @selector(setMuted:), gain <= 0.0f ? YES : appMuted);
    }
}

// Silent or not, with nothing in between: WebKit's page-muted SPI is a switch,
// and there is no supported way to ask a web view for a fraction of its volume.
// Also the only one of these that has to run on the main thread.
static void lcApplyGainToWebView(id webView, float gain) {
    SEL setPageMuted = NSSelectorFromString(@"_setPageMuted:");
    if(![webView respondsToSelector:setPageMuted]) return;
    NSUInteger state = gain <= 0.0f ? kLCWebKitAudioIsMuted : 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(webView, setPageMuted, state);
    });
}

static void lcApplyGainToObjCObjects(float gain) {
    for(id player in lcRegisteredObjects(gAudioPlayers)) {
        lcApplyGainToAudioPlayer(player, gain);
    }
    for(id player in lcRegisteredObjects(gPlayers)) {
        lcApplyGainToPlayer(player, gain);
    }
    for(id node in lcRegisteredObjects(gMixerNodes)) {
        lcApplyGainToMixerNode(node, gain);
    }
    for(id node in lcRegisteredObjects(gPlayerNodes)) {
        lcApplyGainToPlayerNode(node, gain);
    }
    for(id renderer in lcRegisteredObjects(gSampleBufferRenderers)) {
        lcApplyGainToSampleBufferRenderer(renderer, gain);
    }
    for(id webView in lcRegisteredObjects(gWebViews)) {
        lcApplyGainToWebView(webView, gain);
    }
}

// Every entry point that means "this player is about to be heard" funnels here,
// because an object we have never seen is an object the current gain has never
// been applied to.
static void lcAdoptPlayer(id player) {
    lcRegisterObject(gPlayers, player);
    float gain = lcGain();
    if(gain < 1.0f) lcApplyGainToPlayer(player, gain);
}

static void lc_AVAudioPlayer_setVolume(id self, SEL sel, float volume) {
    objc_setAssociatedObject(self, kIntendedVolumeKey, @(volume), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_AVAudioPlayer_setVolume(self, sel, volume * lcGain());
}

static BOOL lc_AVAudioPlayer_play(id self, SEL sel) {
    lcRegisterObject(gAudioPlayers, self);
    if(lcGain() < 1.0f) lcApplyGainToAudioPlayer(self, lcGain());
    return orig_AVAudioPlayer_play(self, sel);
}

static BOOL lc_AVAudioPlayer_prepareToPlay(id self, SEL sel) {
    lcRegisterObject(gAudioPlayers, self);
    if(lcGain() < 1.0f) lcApplyGainToAudioPlayer(self, lcGain());
    return orig_AVAudioPlayer_prepareToPlay(self, sel);
}

static void lc_AVPlayer_setVolume(id self, SEL sel, float volume) {
    objc_setAssociatedObject(self, kIntendedVolumeKey, @(volume), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_AVPlayer_setVolume(self, sel, volume * lcGain());
}

static void lc_AVPlayer_setMuted(id self, SEL sel, BOOL muted) {
    objc_setAssociatedObject(self, kIntendedMutedKey, @(muted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_AVPlayer_setMuted(self, sel, lcIsMuted() ? YES : muted);
}

static void lc_AVPlayer_play(id self, SEL sel) {
    lcAdoptPlayer(self);
    orig_AVPlayer_play(self, sel);
}

// Registered here too: AVQueuePlayer and most video frameworks start playback
// by setting a rate, never going through -play.
static void lc_AVPlayer_setRate(id self, SEL sel, float rate) {
    if(rate != 0.0f) lcAdoptPlayer(self);
    orig_AVPlayer_setRate(self, sel, rate);
}

// Streaming apps commonly start this way rather than with -play, to skip the
// buffering -play would wait for.
static void lc_AVPlayer_playImmediatelyAtRate(id self, SEL sel, float rate) {
    lcAdoptPlayer(self);
    orig_AVPlayer_playImmediatelyAtRate(self, sel, rate);
}

// The catch-all. A player that reaches playback by some route none of the hooks
// above cover still has to be given something to play, and an app that swaps
// tracks passes through here for every one of them.
static void lc_AVPlayer_replaceCurrentItem(id self, SEL sel, id item) {
    lcAdoptPlayer(self);
    orig_AVPlayer_replaceCurrentItem(self, sel, item);
}

// Hooking the getter rather than -[AVAudioEngine start:] keeps this from
// materialising a main mixer the app never asked for — asking an engine for its
// main mixer builds and connects one as a side effect.
static id lc_AVAudioEngine_mainMixerNode(id self, SEL sel) {
    id node = orig_AVAudioEngine_mainMixerNode(self, sel);
    if(node) {
        lcRegisterObject(gMixerNodes, node);
        if(lcGain() < 1.0f) lcApplyGainToMixerNode(node, lcGain());
    }
    return node;
}

static void lc_AVAudioMixerNode_setOutputVolume(id self, SEL sel, float volume) {
    lcRegisterObject(gMixerNodes, self);
    objc_setAssociatedObject(self, kIntendedVolumeKey, @(volume), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_AVAudioMixerNode_setOutputVolume(self, sel, volume * lcGain());
}

static void lc_AVAudioPlayerNode_play(id self, SEL sel) {
    lcRegisterObject(gPlayerNodes, self);
    if(lcGain() < 1.0f) lcApplyGainToPlayerNode(self, lcGain());
    orig_AVAudioPlayerNode_play(self, sel);
}

static void lc_AVAudioPlayerNode_setVolume(id self, SEL sel, float volume) {
    lcRegisterObject(gPlayerNodes, self);
    objc_setAssociatedObject(self, kIntendedVolumeKey, @(volume), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_AVAudioPlayerNode_setVolume(self, sel, volume * lcGain());
}

static void lc_AVSampleBufferAudioRenderer_setVolume(id self, SEL sel, float volume) {
    objc_setAssociatedObject(self, kIntendedVolumeKey, @(volume), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_AVSampleBufferAudioRenderer_setVolume(self, sel, volume * lcGain());
}

static void lc_AVSampleBufferAudioRenderer_setMuted(id self, SEL sel, BOOL muted) {
    objc_setAssociatedObject(self, kIntendedMutedKey, @(muted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_AVSampleBufferAudioRenderer_setMuted(self, sel, lcIsMuted() ? YES : muted);
}

// Registering on -addRenderer: rather than on the renderer's own creation: it is
// the one call every such renderer must pass through to be heard, and it happens
// once per renderer instead of once per sample buffer.
static void lc_AVSampleBufferRenderSynchronizer_addRenderer(id self, SEL sel, id renderer) {
    if([renderer respondsToSelector:@selector(setMuted:)]) {
        lcRegisterObject(gSampleBufferRenderers, renderer);
        if(lcGain() < 1.0f) lcApplyGainToSampleBufferRenderer(renderer, lcGain());
    }
    orig_AVSampleBufferRenderSynchronizer_addRenderer(self, sel, renderer);
}

static id lc_WKWebView_initWithFrame(id self, SEL sel, CGRect frame, id configuration) {
    id webView = orig_WKWebView_initWithFrame(self, sel, frame, configuration);
    if(webView) {
        lcRegisterObject(gWebViews, webView);
        if(lcIsMuted()) lcApplyGainToWebView(webView, 0.0f);
    }
    return webView;
}

#pragma mark - Installation

static bool lcHookMethod(Class class, SEL selector, IMP replacement, void *originalOut) {
    if(!class) return false;
    Method method = class_getInstanceMethod(class, selector);
    if(!method) return false;
    *(IMP *)originalOut = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return true;
}

static bool gAudioUnitHooksInstalled = false;
static bool gAudioQueueHooksInstalled = false;
static bool gSessionHooksInstalled = false;
static bool gAudioPlayerHooksInstalled = false;
static bool gPlayerHooksInstalled = false;
static bool gEngineHooksInstalled = false;
static bool gWebViewHooksInstalled = false;
static bool gSampleBufferHooksInstalled = false;
static bool gPlayerNodeHooksInstalled = false;

static void lcInstallAudioUnitHooks(void) {
    if(gAudioUnitHooksInstalled) return;
    void *setProperty = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    if(!setProperty) return;
    gAudioUnitHooksInstalled = true;
    orig_AudioUnitSetProperty = setProperty;
    // Used, not hooked: the sample format has to be read back off the unit to
    // know how to scale its buffers.
    orig_AudioUnitGetProperty = dlsym(RTLD_DEFAULT, "AudioUnitGetProperty");
    // Rebound globally rather than in the guest binary alone: OpenAL, AVFAudio
    // and every middleware audio backend call this from their own images, and
    // a global rebind also covers images dyld has not loaded yet.
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, setProperty, (void *)lc_AudioUnitSetProperty, nil);

    void *setNodeInputCallback = dlsym(RTLD_DEFAULT, "AUGraphSetNodeInputCallback");
    if(setNodeInputCallback) {
        orig_AUGraphSetNodeInputCallback = setNodeInputCallback;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, setNodeInputCallback, (void *)lc_AUGraphSetNodeInputCallback, nil);
    }
}

static void lcInstallAudioQueueHooks(void) {
    if(gAudioQueueHooksInstalled) return;
    void *setParameter = dlsym(RTLD_DEFAULT, "AudioQueueSetParameter");
    if(!setParameter) return;
    gAudioQueueHooksInstalled = true;
    orig_AudioQueueSetParameter = setParameter;
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, setParameter, (void *)lc_AudioQueueSetParameter, nil);

    void *newOutput = dlsym(RTLD_DEFAULT, "AudioQueueNewOutput");
    if(newOutput) {
        orig_AudioQueueNewOutput = newOutput;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, newOutput, (void *)lc_AudioQueueNewOutput, nil);
    }
    void *newOutputWithQueue = dlsym(RTLD_DEFAULT, "AudioQueueNewOutputWithDispatchQueue");
    if(newOutputWithQueue) {
        orig_AudioQueueNewOutputWithDispatchQueue = newOutputWithQueue;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, newOutputWithQueue, (void *)lc_AudioQueueNewOutputWithDispatchQueue, nil);
    }
    void *dispose = dlsym(RTLD_DEFAULT, "AudioQueueDispose");
    if(dispose) {
        orig_AudioQueueDispose = dispose;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, dispose, (void *)lc_AudioQueueDispose, nil);
    }
}

static void lcInstallSessionHooks(void) {
    if(gSessionHooksInstalled) return;
    Class sessionClass = NSClassFromString(@"AVAudioSession");
    if(!sessionClass) return;
    gSessionHooksInstalled = true;
    // Installed in this order so that the two-argument setter, which forwards to
    // the options one, finds the original it needs already saved.
    lcHookMethod(sessionClass, @selector(setCategory:withOptions:error:), (IMP)lc_setCategoryOptionsError, &orig_setCategoryOptionsError);
    lcHookMethod(sessionClass, @selector(setCategory:error:), (IMP)lc_setCategoryError, &orig_setCategoryError);
    lcHookMethod(sessionClass, @selector(setCategory:mode:options:error:), (IMP)lc_setCategoryModeOptionsError, &orig_setCategoryModeOptionsError);
    lcHookMethod(sessionClass, @selector(setCategory:mode:routeSharingPolicy:options:error:), (IMP)lc_setCategoryModePolicyOptionsError, &orig_setCategoryModePolicyOptionsError);
}

static void lcInstallPlaybackHooks(void) {
    if(!gAudioPlayerHooksInstalled) {
        Class audioPlayerClass = NSClassFromString(@"AVAudioPlayer");
        if(audioPlayerClass) {
            gAudioPlayerHooksInstalled = true;
            lcHookMethod(audioPlayerClass, @selector(setVolume:), (IMP)lc_AVAudioPlayer_setVolume, &orig_AVAudioPlayer_setVolume);
            lcHookMethod(audioPlayerClass, @selector(play), (IMP)lc_AVAudioPlayer_play, &orig_AVAudioPlayer_play);
            lcHookMethod(audioPlayerClass, @selector(prepareToPlay), (IMP)lc_AVAudioPlayer_prepareToPlay, &orig_AVAudioPlayer_prepareToPlay);
        }
    }
    if(!gPlayerHooksInstalled) {
        Class playerClass = NSClassFromString(@"AVPlayer");
        if(playerClass) {
            gPlayerHooksInstalled = true;
            lcHookMethod(playerClass, @selector(setVolume:), (IMP)lc_AVPlayer_setVolume, &orig_AVPlayer_setVolume);
            lcHookMethod(playerClass, @selector(setMuted:), (IMP)lc_AVPlayer_setMuted, &orig_AVPlayer_setMuted);
            lcHookMethod(playerClass, @selector(play), (IMP)lc_AVPlayer_play, &orig_AVPlayer_play);
            lcHookMethod(playerClass, @selector(setRate:), (IMP)lc_AVPlayer_setRate, &orig_AVPlayer_setRate);
            lcHookMethod(playerClass, @selector(playImmediatelyAtRate:), (IMP)lc_AVPlayer_playImmediatelyAtRate, &orig_AVPlayer_playImmediatelyAtRate);
            lcHookMethod(playerClass, @selector(replaceCurrentItemWithPlayerItem:), (IMP)lc_AVPlayer_replaceCurrentItem, &orig_AVPlayer_replaceCurrentItem);
        }
    }
    if(!gEngineHooksInstalled) {
        Class engineClass = NSClassFromString(@"AVAudioEngine");
        Class mixerClass = NSClassFromString(@"AVAudioMixerNode");
        if(engineClass && mixerClass) {
            gEngineHooksInstalled = true;
            lcHookMethod(engineClass, @selector(mainMixerNode), (IMP)lc_AVAudioEngine_mainMixerNode, &orig_AVAudioEngine_mainMixerNode);
            lcHookMethod(mixerClass, @selector(setOutputVolume:), (IMP)lc_AVAudioMixerNode_setOutputVolume, &orig_AVAudioMixerNode_setOutputVolume);
        }
    }
    // Its own flag rather than sharing the engine's: a guard that is only set on
    // some other class arriving would let this class be hooked twice, and the
    // second pass would save our own implementation as the original.
    if(!gPlayerNodeHooksInstalled) {
        Class playerNodeClass = NSClassFromString(@"AVAudioPlayerNode");
        if(playerNodeClass) {
            gPlayerNodeHooksInstalled = true;
            lcHookMethod(playerNodeClass, @selector(play), (IMP)lc_AVAudioPlayerNode_play, &orig_AVAudioPlayerNode_play);
            lcHookMethod(playerNodeClass, @selector(setVolume:), (IMP)lc_AVAudioPlayerNode_setVolume, &orig_AVAudioPlayerNode_setVolume);
        }
    }
    if(!gSampleBufferHooksInstalled) {
        Class rendererClass = NSClassFromString(@"AVSampleBufferAudioRenderer");
        Class synchronizerClass = NSClassFromString(@"AVSampleBufferRenderSynchronizer");
        if(rendererClass && synchronizerClass) {
            gSampleBufferHooksInstalled = true;
            lcHookMethod(rendererClass, @selector(setVolume:), (IMP)lc_AVSampleBufferAudioRenderer_setVolume, &orig_AVSampleBufferAudioRenderer_setVolume);
            lcHookMethod(rendererClass, @selector(setMuted:), (IMP)lc_AVSampleBufferAudioRenderer_setMuted, &orig_AVSampleBufferAudioRenderer_setMuted);
            lcHookMethod(synchronizerClass, @selector(addRenderer:), (IMP)lc_AVSampleBufferRenderSynchronizer_addRenderer, &orig_AVSampleBufferRenderSynchronizer_addRenderer);
        }
    }
    if(!gWebViewHooksInstalled) {
        Class webViewClass = NSClassFromString(@"WKWebView");
        if(webViewClass) {
            gWebViewHooksInstalled = true;
            lcHookMethod(webViewClass, @selector(initWithFrame:configuration:), (IMP)lc_WKWebView_initWithFrame, &orig_WKWebView_initWithFrame);
        }
    }
}

static void lcInstallHooks(void) {
    lcInstallAudioUnitHooks();
    lcInstallAudioQueueHooks();
    lcInstallSessionHooks();
    lcInstallPlaybackHooks();
}

// A guest that links the audio frameworks the usual way has none of them loaded
// yet at bootstrap — this runs before the app binary is even dlopened. dyld
// replays this for every image already in the process, then calls it for each
// new one, so each hook goes in the moment its framework arrives and no later.
static void lcAudioImageAdded(const struct mach_header *header, intptr_t slide) {
    lcInstallHooks();
}

static NSString *gAckName;

static void lcSetGain(float gain) {
    if(gain < 0.0f) gain = 0.0f;
    if(gain > 1.0f) gain = 1.0f;
    bool wasMuted = lcIsMuted();
    atomic_store_explicit(&gGain, gain, memory_order_relaxed);
    lcApplyGainToQueues(gain);
    lcApplyGainToObjCObjects(gain);
    // Only when silence starts or ends, never on the way between: a slider drag
    // arrives as a hundred of these, and re-setting the audio session category a
    // hundred times over a couple of seconds is how you turn a volume change
    // into an audible stutter. Nothing in between changes what the category
    // should be anyway.
    if(wasMuted != lcIsMuted()) {
        lcReapplyCategory();
    }

    // A drag arrives as a hundred of these a second. Reporting each one means a
    // hundred log lines, a hundred registry snapshots to count them, and a
    // hundred acknowledgements for the host to log in turn — enough work to be
    // felt on the thing being dragged. Only movement worth reading is reported.
    static float lastReportedGain = -1.0f;
    if(lastReportedGain >= 0.0f && wasMuted == lcIsMuted() && fabsf(gain - lastReportedGain) < 0.1f) {
        return;
    }
    lastReportedGain = gain;

    NSLog(@"[LCAudioMute] gain=%.2f applied (hooks: audioUnit=%d audioQueue=%d session=%d avAudioPlayer=%d avPlayer=%d engine=%d playerNode=%d sampleBuffer=%d webView=%d; known: audioPlayers=%lu avPlayers=%lu mixers=%lu playerNodes=%lu renderers=%lu webViews=%lu)",
          gain, gAudioUnitHooksInstalled, gAudioQueueHooksInstalled, gSessionHooksInstalled,
          gAudioPlayerHooksInstalled, gPlayerHooksInstalled, gEngineHooksInstalled, gPlayerNodeHooksInstalled,
          gSampleBufferHooksInstalled, gWebViewHooksInstalled,
          (unsigned long)lcRegisteredObjects(gAudioPlayers).count, (unsigned long)lcRegisteredObjects(gPlayers).count,
          (unsigned long)lcRegisteredObjects(gMixerNodes).count, (unsigned long)lcRegisteredObjects(gPlayerNodes).count,
          (unsigned long)lcRegisteredObjects(gSampleBufferRenderers).count, (unsigned long)lcRegisteredObjects(gWebViews).count);

    // Tells the host the message landed. Without it a silent failure is
    // ambiguous — a dead channel and an audio path nothing here covers look
    // exactly the same from the other side.
    if(gAckName) notify_post(gAckName.UTF8String);
}

void LCAudioMuteInit(NSString *dataUUID) {
    if(dataUUID.length == 0) return;

    gRegistryLock = [NSLock new];
    gAudioPlayers = [NSHashTable weakObjectsHashTable];
    gPlayers = [NSHashTable weakObjectsHashTable];
    gMixerNodes = [NSHashTable weakObjectsHashTable];
    gWebViews = [NSHashTable weakObjectsHashTable];
    gSampleBufferRenderers = [NSHashTable weakObjectsHashTable];
    gPlayerNodes = [NSHashTable weakObjectsHashTable];

    lcInstallHooks();
    _dyld_register_func_for_add_image(lcAudioImageAdded);

    // A fixed literal prefix, not the app group id: the host and the guest are
    // separate processes each deriving that id for themselves, from entitlements
    // and container probing, and the two only have to disagree once for the names
    // to stop matching and every toggle to vanish.
    NSString *base = [NSString stringWithFormat:@"com.kdt.livecontainer.mute.%@", dataUUID];
    gAckName = [base stringByAppendingString:@".ack"];

    // Not the main queue. A guest that runs its own frame loop can leave the main
    // queue drained rarely or, mid-hang, never — and a mute that waits on the app
    // being responsive is a mute that fails exactly when it is wanted.
    dispatch_queue_t queue = dispatch_queue_create("com.kdt.livecontainer.audiomute", DISPATCH_QUEUE_SERIAL);
    static int muteToken, unmuteToken, volumeToken;

    // A level needs a payload, which a notification name cannot carry, so the
    // value rides in the name's 64-bit state as thousandths.
    uint32_t volumeStatus = notify_register_dispatch([base stringByAppendingString:@".volume"].UTF8String, &volumeToken, queue, ^(int token) {
        uint64_t state = 0;
        uint32_t status = notify_get_state(token, &state);
        if(status != NOTIFY_STATUS_OK) {
            NSLog(@"[LCAudioMute] volume state unreadable (%u)", status);
            return;
        }
        lcSetGain((float)state / 1000.0f);
    });

    // The two ends of the slider keep their own names, and the host posts them
    // alongside the level. They are what has been carrying mute since before
    // there was a level at all, so if reading the state ever fails, silence and
    // full volume still work and only the fractions in between are lost.
    uint32_t muteStatus = notify_register_dispatch([base stringByAppendingString:@".on"].UTF8String, &muteToken, queue, ^(int token) {
        lcSetGain(0.0f);
    });
    uint32_t unmuteStatus = notify_register_dispatch([base stringByAppendingString:@".off"].UTF8String, &unmuteToken, queue, ^(int token) {
        lcSetGain(1.0f);
    });
    NSLog(@"[LCAudioMute] armed on %@ (register status %u/%u/%u)", base, volumeStatus, muteStatus, unmuteStatus);
}
