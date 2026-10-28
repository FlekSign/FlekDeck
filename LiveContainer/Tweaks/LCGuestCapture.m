//
//  LCGuestCapture.m
//  LiveContainer
//
//  Tells the host when a multitask guest has been refused the microphone, so the
//  window can say so instead of the app simply going quiet.
//
//  A multitask guest is an app extension, and iOS does not let an app extension
//  record. Apple's QA1872 spells out which calls are turned away, and the list is
//  the whole of audio capture: -[AVAudioRecorder record], AudioQueueStart on a
//  queue made by AudioQueueNewInput, -[AVAudioEngine startAndReturnError:] when
//  the engine's input node is in use, and AudioOutputUnitStart on a Remote I/O or
//  Voice Processing unit whose input element has been enabled.
//
//  That last one is why a call in a multitask window is silent in both
//  directions rather than merely mute. A VoIP app drives one Voice Processing
//  unit for capture and playback together — that is where echo cancellation
//  lives — so the refusal does not take away the microphone and leave the rest
//  working. The unit never starts, and the remote party is not heard either.
//
//  A call is worse still, and for a separate reason: it never reaches the audio
//  stack at all, because CallKit turns the guest away first. See the CallKit
//  section below.
//
//  None of it is reported to the user. The call connects, the timer counts up,
//  and nobody can hear anything; a voice recorder shows a level meter stuck at
//  zero; a call button does nothing whatsoever. So this watches the entry points
//  above and, when one of them is turned away, hands the host a single
//  notification. The window then explains that the microphone needs Single Mode
//  and shows where to switch, which is true and is the only thing the user can
//  actually act on.
//
//  Only the refusals are reported, never the intent. Asking for the
//  playAndRecord category is not evidence of anything — apps set it to get
//  speaker routing, or set it once at launch and never record — and a window
//  that announced a broken microphone every time one of those started would be
//  crying wolf at apps that work perfectly. A start that returned an error is
//  not ambiguous.
//
//  Installed during bootstrap, before the app binary is dlopened, and only for a
//  LiveProcess guest: an app in single mode is a real app process, records
//  normally, and has nothing to report.
//
@import Foundation;
@import ObjectiveC;

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <pthread.h>
#import <stdatomic.h>
#import <time.h>

#import "Tweaks.h"
#import "../../litehook/src/litehook.h"

// Every selector here belongs to a framework this file deliberately does not
// import, so none of them are declared in this translation unit.
#pragma clang diagnostic ignored "-Wundeclared-selector"

#pragma mark - CoreAudio declarations

// Spelled out rather than imported, for the same reason LCAudioMute spells them
// out: importing <AudioToolbox/AudioToolbox.h> autolinks AudioToolbox into
// LiveContainer, which would drag the audio stack into the address space of
// every guest including the ones that never make a sound. Everything below is
// looked up by name at runtime, so a process without AudioToolbox gets no hooks.

typedef struct OpaqueAudioComponentInstance *LCAudioUnit;
typedef struct OpaqueAudioQueue *LCAudioQueueRef;
typedef UInt32 LCAudioUnitPropertyID;
typedef UInt32 LCAudioUnitScope;
typedef UInt32 LCAudioUnitElement;

enum {
    kLCAudioOutputUnitProperty_EnableIO = 2003,
    kLCAudioUnitScope_Input = 1,
    // The input side of a Remote I/O or Voice Processing unit is always bus 1.
    // Bus 0 is the output, and asking it about input answers for the wrong half.
    kLCAudioUnitInputElement = 1,
};

#pragma mark - Reporting

static NSString *gUnavailableName;
static int gUnavailableToken = -1;

// Whether a report stands for something the user just did, or for a failure that
// can keep announcing itself on its own. The difference matters at the other end:
// a window must answer every attempt the user makes, and must never let a
// self-repeating failure fight the button that puts the answer away.
//
// Almost everything here is the first kind. Placing a call, answering one,
// tapping record — each is one tap producing one refusal. Only an output unit's
// start is the second kind: an engine that cannot bring its unit up can ask again
// on every render cycle for as long as it is running.
enum {
    kLCSourceUserAction = 0,
    kLCSourceRepeating = 1,
};

// Applied to the repeating kind alone. A user action is already rate-limited by
// the user, and throttling those is what made a second tap on the call button do
// nothing at all.
static const uint64_t kLCRepeatIntervalNanos = 2ull * NSEC_PER_SEC;
static _Atomic uint64_t gLastRepeatingReport = 0;

static void lcReportCaptureUnavailable(const char *what, uint64_t source) {
    if(!gUnavailableName) return;

    if(source == kLCSourceRepeating) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        uint64_t last = atomic_load_explicit(&gLastRepeatingReport, memory_order_relaxed);
        if(last != 0 && now - last < kLCRepeatIntervalNanos) return;
        // Whoever wins the exchange reports; the losers are inside the interval by
        // definition. Two threads failing at the same instant is ordinary — an
        // engine and a unit often come up together — and one report is enough.
        if(!atomic_compare_exchange_strong_explicit(&gLastRepeatingReport, &last, now,
                                                    memory_order_relaxed, memory_order_relaxed)) {
            return;
        }
    }

    NSLog(@"[LCGuestCapture] %s was refused — telling the host (%s)", what,
          source == kLCSourceRepeating ? "repeating" : "user action");
    // A notification name carries no payload, so which kind this is rides in the
    // name's 64-bit state, the same way LCAudioMute's level does.
    if(gUnavailableToken != -1) notify_set_state(gUnavailableToken, source);
    notify_post(gUnavailableName.UTF8String);
}

#pragma mark - AudioUnit

static OSStatus (*orig_AudioOutputUnitStart)(LCAudioUnit);
static OSStatus (*orig_AudioUnitGetProperty)(LCAudioUnit, LCAudioUnitPropertyID, LCAudioUnitScope, LCAudioUnitElement, void *, UInt32 *);

// Whether this unit was asked to capture. A unit that only plays can fail to
// start for a dozen unrelated reasons — a route change mid-start, a hardware
// format it cannot have — and none of them are this.
static bool lcUnitCaptures(LCAudioUnit unit) {
    if(!orig_AudioUnitGetProperty || !unit) return false;
    UInt32 enabled = 0;
    UInt32 size = sizeof(enabled);
    OSStatus status = orig_AudioUnitGetProperty(unit, kLCAudioOutputUnitProperty_EnableIO,
                                                kLCAudioUnitScope_Input, kLCAudioUnitInputElement,
                                                &enabled, &size);
    return status == noErr && enabled != 0;
}

static OSStatus lc_AudioOutputUnitStart(LCAudioUnit unit) {
    OSStatus status = orig_AudioOutputUnitStart(unit);
    if(status != noErr && lcUnitCaptures(unit)) {
        lcReportCaptureUnavailable("AudioOutputUnitStart", kLCSourceRepeating);
    }
    return status;
}

#pragma mark - AudioQueue

static OSStatus (*orig_AudioQueueNewInput)(const void *, void *, void *, void *, void *, UInt32, LCAudioQueueRef *);
static OSStatus (*orig_AudioQueueNewInputWithDispatchQueue)(LCAudioQueueRef *, const void *, UInt32, dispatch_queue_t, void *);
static OSStatus (*orig_AudioQueueStart)(LCAudioQueueRef, const void *);

// A queue carries no flag saying which direction it runs in, and there is no
// property to ask, so the ones made by the input constructors are remembered as
// they are made. A handful is all any app has; the cap is there so a leak in the
// app cannot become a leak here.
//
// Deliberately never pruned. The obvious place to drop a queue is AudioQueueDispose,
// and that symbol is already rebound by LCAudioMute — two global rebinds of one
// symbol do not compose. The second one looks for call sites still pointing at the
// original function, finds the first hook in their place, and installs nothing; and
// if the two ever loaded in the other order, it would be LCAudioMute's hook that
// silently vanished, leaving it to set the volume on queues that had been freed.
// What is given up instead is small: a disposed input queue's address could be
// handed back out for a later output queue, and a failure to start *that* would be
// reported as a microphone refusal. It takes a false sheet at worst.
#define LC_MAX_TRACKED_INPUT_QUEUES 16
static pthread_mutex_t gInputQueueLock = PTHREAD_MUTEX_INITIALIZER;
static LCAudioQueueRef gInputQueues[LC_MAX_TRACKED_INPUT_QUEUES];

static void lcTrackInputQueue(LCAudioQueueRef queue) {
    if(!queue) return;
    pthread_mutex_lock(&gInputQueueLock);
    for(int i = 0; i < LC_MAX_TRACKED_INPUT_QUEUES; i++) {
        if(gInputQueues[i] == NULL || gInputQueues[i] == queue) {
            gInputQueues[i] = queue;
            break;
        }
    }
    pthread_mutex_unlock(&gInputQueueLock);
}

static bool lcIsInputQueue(LCAudioQueueRef queue) {
    if(!queue) return false;
    bool found = false;
    pthread_mutex_lock(&gInputQueueLock);
    for(int i = 0; i < LC_MAX_TRACKED_INPUT_QUEUES; i++) {
        if(gInputQueues[i] == queue) { found = true; break; }
    }
    pthread_mutex_unlock(&gInputQueueLock);
    return found;
}

static OSStatus lc_AudioQueueNewInput(const void *format, void *callback, void *userData, void *runLoop, void *runLoopMode, UInt32 flags, LCAudioQueueRef *outAQ) {
    OSStatus status = orig_AudioQueueNewInput(format, callback, userData, runLoop, runLoopMode, flags, outAQ);
    if(status == noErr && outAQ) lcTrackInputQueue(*outAQ);
    return status;
}

static OSStatus lc_AudioQueueNewInputWithDispatchQueue(LCAudioQueueRef *outAQ, const void *format, UInt32 flags, dispatch_queue_t queue, void *callbackBlock) {
    OSStatus status = orig_AudioQueueNewInputWithDispatchQueue(outAQ, format, flags, queue, callbackBlock);
    if(status == noErr && outAQ) lcTrackInputQueue(*outAQ);
    return status;
}

static OSStatus lc_AudioQueueStart(LCAudioQueueRef queue, const void *startTime) {
    OSStatus status = orig_AudioQueueStart(queue, startTime);
    if(status != noErr && lcIsInputQueue(queue)) {
        lcReportCaptureUnavailable("AudioQueueStart", kLCSourceUserAction);
    }
    return status;
}

#pragma mark - AVAudioRecorder

static BOOL (*orig_AVAudioRecorder_record)(id, SEL);
static BOOL (*orig_AVAudioRecorder_recordForDuration)(id, SEL, NSTimeInterval);
static BOOL (*orig_AVAudioRecorder_recordAtTime)(id, SEL, NSTimeInterval);
static BOOL (*orig_AVAudioRecorder_recordAtTimeForDuration)(id, SEL, NSTimeInterval, NSTimeInterval);

static BOOL lc_AVAudioRecorder_record(id self, SEL sel) {
    BOOL started = orig_AVAudioRecorder_record(self, sel);
    if(!started) lcReportCaptureUnavailable("-[AVAudioRecorder record]", kLCSourceUserAction);
    return started;
}

static BOOL lc_AVAudioRecorder_recordForDuration(id self, SEL sel, NSTimeInterval duration) {
    BOOL started = orig_AVAudioRecorder_recordForDuration(self, sel, duration);
    if(!started) lcReportCaptureUnavailable("-[AVAudioRecorder recordForDuration:]", kLCSourceUserAction);
    return started;
}

static BOOL lc_AVAudioRecorder_recordAtTime(id self, SEL sel, NSTimeInterval time) {
    BOOL started = orig_AVAudioRecorder_recordAtTime(self, sel, time);
    if(!started) lcReportCaptureUnavailable("-[AVAudioRecorder recordAtTime:]", kLCSourceUserAction);
    return started;
}

static BOOL lc_AVAudioRecorder_recordAtTimeForDuration(id self, SEL sel, NSTimeInterval time, NSTimeInterval duration) {
    BOOL started = orig_AVAudioRecorder_recordAtTimeForDuration(self, sel, time, duration);
    if(!started) lcReportCaptureUnavailable("-[AVAudioRecorder recordAtTime:forDuration:]", kLCSourceUserAction);
    return started;
}

#pragma mark - AVAudioEngine

static id (*orig_AVAudioEngine_inputNode)(id, SEL);
static BOOL (*orig_AVAudioEngine_startAndReturnError)(id, SEL, NSError **);

static const void *kUsesInputKey = &kUsesInputKey;

// QA1872 only lists -startAndReturnError: as failing "in cases where the
// inputNode object is used", and an engine that merely plays is perfectly
// capable of failing to start for its own reasons. Which engine is which is
// answered by watching for the app reaching for the input node — observed, never
// asked for, because asking would build the input node on an engine that never
// wanted one.
static id lc_AVAudioEngine_inputNode(id self, SEL sel) {
    objc_setAssociatedObject(self, kUsesInputKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return orig_AVAudioEngine_inputNode(self, sel);
}

static BOOL lc_AVAudioEngine_startAndReturnError(id self, SEL sel, NSError **error) {
    BOOL started = orig_AVAudioEngine_startAndReturnError(self, sel, error);
    if(!started && objc_getAssociatedObject(self, kUsesInputKey)) {
        lcReportCaptureUnavailable("-[AVAudioEngine startAndReturnError:]", kLCSourceUserAction);
    }
    return started;
}

#pragma mark - CallKit

// A call never reaches the audio stack at all. CallKit refuses the guest's
// provider the moment it registers — callservicesd asks LaunchServices for an
// *application* record to go with the connection, a multitask guest has none,
// and the connection is dropped before a call is ever placed:
//
//     callservicesd  Attempt to retrieve application record for bundle identifier
//                    <private> failed with error: NSOSStatusErrorDomain Code=-10814
//     callservicesd  Denying creation of CXXPCCallSource with identifier: <private>
//                    bundleIdentifier: (null) bundleURL: (null) hasVoIPBackgroundMode: 0
//     callservicesd  [WARN] Not accepting connection — a CXXPCCallSource couldn't be created
//
//  (-10814 is kLSApplicationNotFoundErr. hasVoIPBackgroundMode: 0 is a symptom of
//  the same failed lookup, not a second problem — the appex does declare voip.)
//
// So by the time the user taps call, the provider has been dead for as long as
// the app has been running. The transaction they trigger comes straight back
// with CXErrorCodeRequestTransactionErrorUnentitled, the app has nothing to show
// for it, and the button appears to do nothing at all. That silence is the worst
// of the failures this file exists to break, and it is the only one that never
// touches an audio API — hence catching it here rather than on the way to the
// microphone.
//
// Only transactions that would start or answer a call are reported. Ending a
// call that has already ended fails too, with UnknownCallUUID, and routinely —
// a window that explained Single Mode every time a call hung up would be noise.

static void (*orig_requestTransaction)(id, SEL, id, void (^)(NSError *));
static void (*orig_requestTransactionWithActions)(id, SEL, NSArray *, void (^)(NSError *));
static void (*orig_requestTransactionWithAction)(id, SEL, id, void (^)(NSError *));

static BOOL lcActionsPlaceACall(NSArray *actions) {
    Class startClass = NSClassFromString(@"CXStartCallAction");
    Class answerClass = NSClassFromString(@"CXAnswerCallAction");
    for(id action in actions) {
        if(startClass && [action isKindOfClass:startClass]) return YES;
        if(answerClass && [action isKindOfClass:answerClass]) return YES;
    }
    return NO;
}

// Wraps the app's completion so the error can be read on the way past. The app's
// own block is always called, with the error untouched — nothing here changes
// what the app is told, only what the window knows.
static void (^lcWatchingCompletion(NSArray *actions, const char *what, void (^completion)(NSError *)))(NSError *) {
    BOOL placesACall = lcActionsPlaceACall(actions);
    return ^(NSError *error) {
        if(error && placesACall) {
            NSLog(@"[LCGuestCapture] CallKit refused a call transaction: %@", error);
            lcReportCaptureUnavailable(what, kLCSourceUserAction);
        }
        if(completion) completion(error);
    };
}

static NSArray *lcTransactionActions(id transaction) {
    if(![transaction respondsToSelector:@selector(actions)]) return nil;
    return ((NSArray *(*)(id, SEL))objc_msgSend)(transaction, @selector(actions));
}

static void lc_requestTransaction(id self, SEL sel, id transaction, void (^completion)(NSError *)) {
    orig_requestTransaction(self, sel, transaction,
        lcWatchingCompletion(lcTransactionActions(transaction), "-[CXCallController requestTransaction:completion:]", completion));
}

static void lc_requestTransactionWithActions(id self, SEL sel, NSArray *actions, void (^completion)(NSError *)) {
    orig_requestTransactionWithActions(self, sel, actions,
        lcWatchingCompletion(actions, "-[CXCallController requestTransactionWithActions:completion:]", completion));
}

static void lc_requestTransactionWithAction(id self, SEL sel, id action, void (^completion)(NSError *)) {
    orig_requestTransactionWithAction(self, sel, action,
        lcWatchingCompletion(action ? @[action] : nil, "-[CXCallController requestTransactionWithAction:completion:]", completion));
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
static bool gRecorderHooksInstalled = false;
static bool gEngineHooksInstalled = false;
static bool gCallKitHooksInstalled = false;

static void lcInstallAudioUnitHooks(void) {
    if(gAudioUnitHooksInstalled) return;
    void *start = dlsym(RTLD_DEFAULT, "AudioOutputUnitStart");
    if(!start) return;
    gAudioUnitHooksInstalled = true;
    orig_AudioOutputUnitStart = start;
    // Used, not hooked: the unit has to be asked whether it was capturing.
    orig_AudioUnitGetProperty = dlsym(RTLD_DEFAULT, "AudioUnitGetProperty");
    // Rebound globally rather than in the guest binary alone: WebRTC, the
    // middleware audio backends and AVFAudio itself all call this from their own
    // images, and a global rebind also covers images dyld has not loaded yet.
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, start, (void *)lc_AudioOutputUnitStart, nil);
}

static void lcInstallAudioQueueHooks(void) {
    if(gAudioQueueHooksInstalled) return;
    void *start = dlsym(RTLD_DEFAULT, "AudioQueueStart");
    if(!start) return;
    gAudioQueueHooksInstalled = true;
    orig_AudioQueueStart = start;
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, start, (void *)lc_AudioQueueStart, nil);

    void *newInput = dlsym(RTLD_DEFAULT, "AudioQueueNewInput");
    if(newInput) {
        orig_AudioQueueNewInput = newInput;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, newInput, (void *)lc_AudioQueueNewInput, nil);
    }
    void *newInputWithQueue = dlsym(RTLD_DEFAULT, "AudioQueueNewInputWithDispatchQueue");
    if(newInputWithQueue) {
        orig_AudioQueueNewInputWithDispatchQueue = newInputWithQueue;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, newInputWithQueue, (void *)lc_AudioQueueNewInputWithDispatchQueue, nil);
    }
}

static void lcInstallObjCHooks(void) {
    if(!gRecorderHooksInstalled) {
        Class recorderClass = NSClassFromString(@"AVAudioRecorder");
        if(recorderClass) {
            gRecorderHooksInstalled = true;
            lcHookMethod(recorderClass, @selector(record), (IMP)lc_AVAudioRecorder_record, &orig_AVAudioRecorder_record);
            lcHookMethod(recorderClass, @selector(recordForDuration:), (IMP)lc_AVAudioRecorder_recordForDuration, &orig_AVAudioRecorder_recordForDuration);
            lcHookMethod(recorderClass, @selector(recordAtTime:), (IMP)lc_AVAudioRecorder_recordAtTime, &orig_AVAudioRecorder_recordAtTime);
            lcHookMethod(recorderClass, @selector(recordAtTime:forDuration:), (IMP)lc_AVAudioRecorder_recordAtTimeForDuration, &orig_AVAudioRecorder_recordAtTimeForDuration);
        }
    }
    if(!gEngineHooksInstalled) {
        Class engineClass = NSClassFromString(@"AVAudioEngine");
        if(engineClass) {
            gEngineHooksInstalled = true;
            lcHookMethod(engineClass, @selector(inputNode), (IMP)lc_AVAudioEngine_inputNode, &orig_AVAudioEngine_inputNode);
            lcHookMethod(engineClass, @selector(startAndReturnError:), (IMP)lc_AVAudioEngine_startAndReturnError, &orig_AVAudioEngine_startAndReturnError);
        }
    }
    // The convenience variants are hooked as well as the designated one. They very
    // likely funnel into it, in which case a refusal is seen twice and reported
    // once — the interval above collapses the pair — but "very likely" is not a
    // thing to hang a silent failure on.
    if(!gCallKitHooksInstalled) {
        Class controllerClass = NSClassFromString(@"CXCallController");
        if(controllerClass) {
            gCallKitHooksInstalled = true;
            lcHookMethod(controllerClass, @selector(requestTransaction:completion:), (IMP)lc_requestTransaction, &orig_requestTransaction);
            lcHookMethod(controllerClass, @selector(requestTransactionWithActions:completion:), (IMP)lc_requestTransactionWithActions, &orig_requestTransactionWithActions);
            lcHookMethod(controllerClass, @selector(requestTransactionWithAction:completion:), (IMP)lc_requestTransactionWithAction, &orig_requestTransactionWithAction);
        }
    }
}

static void lcInstallHooks(void) {
    lcInstallAudioUnitHooks();
    lcInstallAudioQueueHooks();
    lcInstallObjCHooks();
}

// A guest that links the audio frameworks the usual way has none of them loaded
// yet at bootstrap — this runs before the app binary is even dlopened. dyld
// replays this for every image already in the process, then calls it for each new
// one, so each hook goes in the moment its framework arrives and no later.
static void lcCaptureImageAdded(const struct mach_header *header, intptr_t slide) {
    lcInstallHooks();
}

void LCGuestCaptureInit(NSString *dataUUID) {
    if(dataUUID.length == 0) return;

    // A fixed literal prefix keyed by container, the same shape LCAudioMute and
    // LCGuestPiP use and for the same reason: the host and the guest each work
    // the app group id out for themselves, and they only have to disagree once
    // for every message to vanish.
    gUnavailableName = [NSString stringWithFormat:@"com.kdt.livecontainer.capture.%@.unavailable", dataUUID];
    // Registered once and kept: the state belongs to the name for as long as
    // someone holds a registration on it, and without one the host cannot tell
    // the two kinds of report apart.
    if(notify_register_check(gUnavailableName.UTF8String, &gUnavailableToken) != NOTIFY_STATUS_OK) {
        gUnavailableToken = -1;
    }

    lcInstallHooks();
    _dyld_register_func_for_add_image(lcCaptureImageAdded);

    NSLog(@"[LCGuestCapture] armed on %@", gUnavailableName);
}
