//
//  PiPManager.m
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
#include "PiPManager.h"
#include "AppSceneViewController.h"
#include "DecoratedAppSceneViewController.h"
#include "../LiveContainer/utils.h"
#import <notify.h>

static void *kPiPBoundsObservationContext = &kPiPBoundsObservationContext;

/// Private CoreAnimation. A layer that shows the contents of a CAContext
/// published by any process that cares to tell you its id.
@interface CALayerHost : CALayer
@property(nonatomic) uint32_t contextId;
/// Makes the hosted context render at this layer's size instead of at its own.
/// Without it a layer host draws what it hosts at whatever size the publishing
/// process's layer happened to be, anchored top left and never scaled — which is
/// how the picture kept arriving small in a corner no matter what was measured.
@property(nonatomic) BOOL resizesHostedContext;
@end

/// Puts one black frame into a sample buffer layer.
///
/// The layer AVKit is given as the PiP source is never fed anything — the video
/// arrives by the layer host planted inside it — but a layer that has never had a
/// frame is not a layer AVKit will start PiP for. This is the frame, and it is
/// the only one: it sits behind the hosted video and is never seen.
static void LCEnqueueBlackFrame(AVSampleBufferDisplayLayer *layer, CGSize size) {
    size_t width = MAX((size_t)size.width, (size_t)16);
    size_t height = MAX((size_t)size.height, (size_t)16);

    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    if(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                           (__bridge CFDictionaryRef)attributes, &pixelBuffer) != kCVReturnSuccess) {
        return;
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0,
           CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer));
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    if(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) == noErr) {
        CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid };
        if(CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL,
                                              format, &timing, &sample) == noErr && sample) {
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
            if(attachments && CFArrayGetCount(attachments) > 0) {
                CFMutableDictionaryRef first = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
                CFDictionarySetValue(first, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            }
            [layer enqueueSampleBuffer:sample];
            CFRelease(sample);
        }
        CFRelease(format);
    }
    CVPixelBufferRelease(pixelBuffer);
}

#pragma mark - Playback, proxied

/// Answers the PiP window's transport controls on the guest's behalf.
///
/// AVKit asks these questions synchronously and expects an answer immediately, so
/// nothing here waits on the guest: the guest keeps its playback state published
/// in a notification's 64 bits and this reads it on the spot. Commands go the
/// other way by the same means, and the guest hands them to the app's own
/// playback delegate — so the app drives its own player and nothing on this side
/// has to understand playback at all.
API_AVAILABLE(ios(16.0))
@interface LCGuestPlaybackProxy : NSObject <AVPictureInPictureSampleBufferPlaybackDelegate>
- (instancetype)initWithDataUUID:(NSString *)dataUUID;
/// Kept in step with what the guest reports, because the scrubber's position
/// comes from the layer's timebase rather than from anything asked of us.
@property(nonatomic, weak) AVSampleBufferDisplayLayer *shimLayer;
/// Told when the guest's playback state changes, so AVKit can be made to re-read
/// it. Weak: the controller owns the content source, which owns this.
@property(nonatomic, weak) AVPictureInPictureController *controller;
- (void)startDrivingTimebase;
- (void)stopDrivingTimebase;
@end

@implementation LCGuestPlaybackProxy {
    NSString *_stateName;
    NSString *_playName;
    NSString *_skipName;
    int _stateToken;
    int _playToken;
    int _skipToken;
    int _announceToken;
    NSTimer *_timebaseTimer;
    BOOL _locallyPaused;
}

- (instancetype)initWithDataUUID:(NSString *)dataUUID {
    self = [super init];
    if(self) {
        _stateName = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@.state", dataUUID];
        // A name apiece. Both used to share one, with the command in the name's
        // 64-bit state — and AVKit sends a skip and a play in the same
        // millisecond, so the second overwrote the first before the guest could
        // read it and the skip was simply lost. Two names cannot clobber each
        // other.
        _playName = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@.command.play", dataUUID];
        _skipName = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@.command.skip", dataUUID];
        _stateToken = NOTIFY_TOKEN_INVALID;
        _playToken = NOTIFY_TOKEN_INVALID;
        _skipToken = NOTIFY_TOKEN_INVALID;
        _announceToken = NOTIFY_TOKEN_INVALID;

        // The guest posts this whenever its playback state actually changes.
        // Without the invalidate, AVKit goes on showing whatever it read the
        // first time: the play button never changes, and pressing it sends the
        // same command over again.
        __weak typeof(self) weakSelf = self;
        int token = 0;
        if(notify_register_dispatch(_stateName.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
            [weakSelf.controller invalidatePlaybackState];
        }) == NOTIFY_STATUS_OK) {
            _announceToken = token;
        }
    }
    return self;
}

- (void)dealloc {
    [_timebaseTimer invalidate];
    if(_announceToken != NOTIFY_TOKEN_INVALID) notify_cancel(_announceToken);
    if(_stateToken != NOTIFY_TOKEN_INVALID) notify_cancel(_stateToken);
    if(_playToken != NOTIFY_TOKEN_INVALID) notify_cancel(_playToken);
    if(_skipToken != NOTIFY_TOKEN_INVALID) notify_cancel(_skipToken);
}

- (uint64_t)guestState {
    if(_stateToken == NOTIFY_TOKEN_INVALID) {
        int token = 0;
        if(notify_register_check(_stateName.UTF8String, &token) != NOTIFY_STATUS_OK) return 0;
        _stateToken = token;
    }
    uint64_t state = 0;
    notify_get_state(_stateToken, &state);
    return state;
}

- (void)send:(NSString *)name token:(int *)token state:(uint64_t)state {
    if(*token == NOTIFY_TOKEN_INVALID) {
        int fresh = 0;
        if(notify_register_check(name.UTF8String, &fresh) != NOTIFY_STATUS_OK) return;
        *token = fresh;
    }
    notify_set_state(*token, state);
    notify_post(name.UTF8String);
}

- (void)sendPlaying:(BOOL)playing {
    [self send:_playName token:&_playToken state:(playing ? 1 : 0)];
    NSLog(@"[LC] PiP play=%d sent to the guest", playing);
}

- (void)sendSkip:(int64_t)deciseconds {
    // A counter in the top bits so two skips of the same size in a row are two
    // different states, and the guest cannot mistake the second for a repeat.
    static uint64_t sequence = 0;
    sequence = (sequence + 1) & 0xFFFF;
    [self send:_skipName token:&_skipToken
         state:((uint64_t)deciseconds & 0xFFFFFFFFFFFF) | (sequence << 48)];
    NSLog(@"[LC] PiP skip %lldds sent to the guest", (long long)deciseconds);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing {
    // Remembered before it is sent. The guest is the authority on what its player
    // is doing, but its answer takes a round trip, and AVKit asks again
    // immediately — so until the guest speaks, what we just commanded is a better
    // answer than the state from before the command.
    _locallyPaused = !playing;
    [self sendPlaying:playing];
    // Deliberately no invalidate here. Telling AVKit to re-read the state it has
    // just commanded invites it to disagree with the answer and command again,
    // and it does: play and pause alternating every couple of hundred
    // milliseconds for as long as the window is open. The guest announces its own
    // state when it actually changes, and that is the one thing that invalidates.
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller {
    uint64_t state = self.guestState;
    if(state & (1ULL << 63)) return (state & 1) != 0;
    return _locallyPaused;
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller {
    uint64_t state = self.guestState;
    double duration = (double)((state >> 25) & 0xFFFFFF) / 10.0;
    if(duration <= 0) {
        // Nothing to scrub: a live stream, or a guest that has not answered yet.
        return CMTimeRangeMake(kCMTimeNegativeInfinity, kCMTimePositiveInfinity);
    }
    return CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(duration, 600));
}

/// Moves the scrubber, which reads the layer's timebase rather than anything
/// asked of this object.
///
/// On a timer of its own, on the main thread. This used to ride along inside
/// -pictureInPictureControllerTimeRangeForPlayback:, which AVKit calls whenever
/// it likes and not necessarily from the main thread — driving a display layer's
/// timebase from an arbitrary thread inside a getter is not something to do.
- (void)startDrivingTimebase {
    if(_timebaseTimer) return;
    __weak typeof(self) weakSelf = self;
    _timebaseTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        LCGuestPlaybackProxy *proxy = weakSelf;
        AVSampleBufferDisplayLayer *layer = proxy.shimLayer;
        if(!layer) return;
        uint64_t state = proxy.guestState;
        if(!(state & (1ULL << 63))) return;   // the guest has not answered yet

        CMTime position = CMTimeMakeWithSeconds((double)((state >> 1) & 0xFFFFFF) / 10.0, 600);
        float rate = (state & 1) ? 0.0f : 1.0f;

        // Both of them. AVKit reads the position from the renderer's timebase —
        // -[AVSampleBufferDisplayLayerPlayerController _startObservation] goes
        // sampleBufferDisplayLayer -> sampleBufferRenderer -> timebase — while
        // controlTimebase is the older spelling and the one we can create. Which
        // of the two is live depends on the OS, so whichever exists is driven.
        CMTimebaseRef control = layer.controlTimebase;
        if(control) {
            CMTimebaseSetTime(control, position);
            CMTimebaseSetRate(control, rate);
        }
        if(@available(iOS 17.0, *)) {
            CMTimebaseRef rendered = layer.sampleBufferRenderer.timebase;
            if(rendered && rendered != control) {
                CMTimebaseSetTime(rendered, position);
                CMTimebaseSetRate(rendered, rate);
            }
        }
    }];
}

- (void)stopDrivingTimebase {
    [_timebaseTimer invalidate];
    _timebaseTimer = nil;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler {
    [self sendSkip:(int64_t)(CMTimeGetSeconds(skipInterval) * 10.0)];
    // Answered at once rather than when the guest has finished seeking: AVKit
    // holds the controls disabled until this returns, and the guest's own player
    // is what the user is watching for the result anyway.
    completionHandler();
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
         didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
}

@end

API_AVAILABLE(ios(16.0))
@interface PiPManager()
@property(nonatomic, strong) UIView *pipVideoCallContentView;
@property(nonatomic, strong) AVPictureInPictureVideoCallViewController *pipVideoCallViewController;
@property(nonatomic, strong) AVPictureInPictureController *pipController;
@property(nonatomic) AppSceneViewController* displayingVC;
/// The PiP window's layer, for as long as its bounds are being watched. Held
/// strongly on purpose: an observed object must not go away while the
/// observation stands, and the view controller that owns this layer is let go
/// of in more than one place.
@property(nonatomic, strong) CALayer *observedLayer;
/// Set from the moment PiP has been asked to start until it has finished
/// stopping, which is a window `isPictureInPictureActive` does not cover: it is
/// still NO throughout the start, including inside -willStart.
///
/// That gap matters because -willStart minimizes the window, which tells the dock
/// a window has left the stage, which changes what is frontmost — and arming
/// listens to exactly that. Without this the disarm that follows would release
/// the controller AVKit is in the middle of starting, and PiP would go Active and
/// stop again a few milliseconds later.
@property(nonatomic) BOOL isStartingPiP;
/// The guest video context the current controller was built around, or 0 if it
/// was built to show the guest's whole window. Compared against what the window
/// is offering now, so a controller armed before the guest published its video is
/// rebuilt rather than reused.
@property(nonatomic) uint32_t preparedVideoContextId;
/// The empty sample buffer layer AVKit is given as the PiP source, the view
/// holding it in the window, and the proxy answering the window's controls. All
/// three live exactly as long as one video-context PiP.
@property(nonatomic, strong) UIView *videoShimView;
@property(nonatomic, strong) AVSampleBufferDisplayLayer *videoShimLayer;
/// The layer host showing the guest's context. Kept so its id can be filled in
/// once the guest publishes, which is at the last moment before the float — the
/// controller itself has to be armed long before that.
@property(nonatomic, strong) CALayerHost *videoHostLayer;
@property(nonatomic, strong) LCGuestPlaybackProxy *playbackProxy;
/// Notification observers holding the guest's scene foreground while its video
/// floats. Nil when nothing is floating.
@property(nonatomic, strong) NSArray *guestOnStageObserver;
@end


@implementation PiPManager
API_AVAILABLE(ios(16.0))
static PiPManager* sharedInstance = nil;

+ (instancetype)shared {
    if(!sharedInstance)
        sharedInstance = [[self alloc] init];
    return sharedInstance;
}

+ (BOOL)hasShared {
    return sharedInstance != nil;
}

- (DecoratedAppSceneViewController *)displayingDecoratedVC {
    return (id)self.displayingVC.delegate;
}

- (BOOL)isPiP {
    return self.pipController.isPictureInPictureActive;
}

- (BOOL)isPiPWithVC:(AppSceneViewController*)vc {
    return self.pipController.isPictureInPictureActive && self.displayingVC == vc;
}

- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc {
    return self.pipController.isPictureInPictureActive && self.displayingDecoratedVC == vc;
}

/// Puts the audio session in a category that permits Picture in Picture, without
/// ever making it active.
///
/// AVKit reads PiP availability for a sample buffer source straight off the audio
/// session:
///
///     -[AVSampleBufferDisplayLayerPlayerController _startObservation]
///       [AVAudioSession sharedInstance] -> isPiPAvailable
///                                       -> setPictureInPictureAvailable:
///
/// and with the default category that answer is no, which is why PiP reported
/// `isPictureInPicturePossible: NO` with every other gate passing.
///
/// Setting the category and activating the session are different acts, and only
/// the second one interrupts anybody. LiveContainer used to do both, which is
/// what stopped the guest's playback the moment its window floated. This does
/// only the first: nothing else on the device is touched, the host still never
/// plays a sound, and what keeps the window alive in the background remains the
/// PIPVisible assertion rather than anything to do with audio.
- (void)ensurePiPAudioCategory {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *error = nil;
        if(![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&error]) {
            NSLog(@"[LC] could not set a PiP-capable audio category: %@", error);
        }
    });
}

/// Takes down everything a video-context PiP put up. Safe to call when there was
/// none.
- (void)tearDownVideoShim {
    [self endKeepingGuestOnStage];
    [self.playbackProxy stopDrivingTimebase];
    [self.videoShimView removeFromSuperview];
    self.videoShimView = nil;
    self.videoShimLayer = nil;
    self.videoHostLayer = nil;
    self.playbackProxy = nil;
}

/// Builds a controller bound to `vc`, ready to start but not started.
- (void)prepareControllerForVC:(AppSceneViewController*)vc {
    self.displayingVC = vc;
    self.preparedVideoContextId = vc.guestVideoContextId;
    self.pipVideoCallViewController = [AVPictureInPictureVideoCallViewController new];

    // The guest has published its video as a context of its own, so the window
    // can show the video by itself instead of a shrunken copy of the whole app.
    // Nothing is copied to do it: the context is rendered where it always was and
    // this only says where else to show it.
    if(vc.guestHasVideo || self.preparedVideoContextId != 0) {
        CGSize videoSize = vc.guestVideoSize;
        if(videoSize.width < 1 || videoSize.height < 1) videoSize = vc.view.bounds.size;
        self.pipVideoCallViewController = nil;

        // A sample buffer source rather than a video call one, which is what
        // decides the window's shape as much as its controls: SpringBoard sizes a
        // video call by pegasusVideoCallMetrics, which is the big near-square
        // window, and video content by the video's own dimensions. It is also the
        // only source that publishes playback state, so it is the only one that
        // gets play, pause, skip and a scrubber.
        //
        // The layer is never fed anything. AVKit builds the PiP window's content
        // from the source layer itself, and the way it carries video across is to
        // search that layer for a CALayerHost and hand its context to the window
        // — so one planted here, on the context the guest published, is the whole
        // of the video. Confirmed in AVKit:
        //
        //     -[AVPictureInPictureSampleBufferDisplayLayerView _updateSourceLayerHost]
        //       sourceLayer -> avkit_sbdlpip_findFirstCALayerHost -> contextId
        //
        // Before the content source exists: AVKit reads PiP availability off the
        // audio session as it builds the player controller, and never asks again.
        [self ensurePiPAudioCategory];

        // The shim is the size of the *picture*, not of the whole context. What
        // AVKit handed the guest as its PiP source is a container with the video
        // somewhere inside it, so hosting the context whole put a thumbnail in
        // the corner of a large empty window — and made the window the
        // container's shape, which is why it came out square. The layer host is
        // offset so the picture lands at the shim's origin, and everything around
        // it is clipped away.
        CGRect videoRect = vc.guestVideoRect;
        if(videoRect.size.width < 1 || videoRect.size.height < 1) {
            videoRect = CGRectMake(0, 0, videoSize.width, videoSize.height);
        }

        AVSampleBufferDisplayLayer *shim = [AVSampleBufferDisplayLayer new];
        shim.frame = CGRectMake(0, 0, videoRect.size.width, videoRect.size.height);
        shim.backgroundColor = UIColor.blackColor.CGColor;
        shim.masksToBounds = YES;

        LCEnqueueBlackFrame(shim, videoRect.size);

        CALayerHost *videoHost = [NSClassFromString(@"CALayerHost") new];
        videoHost.contextId = self.preparedVideoContextId;
        // Sized to the whole context and shifted so the picture's rect lands on
        // the shim's origin; the shim clips the rest away. With the context made
        // to render at this layer's size, the two measurements finally agree —
        // the guest's rect is in the context's own coordinates and this is the
        // context at exactly that size.
        videoHost.resizesHostedContext = YES;
        videoHost.frame = CGRectMake(-videoRect.origin.x, -videoRect.origin.y,
                                     videoSize.width, videoSize.height);
        [shim addSublayer:videoHost];

        // The scrubber reads the layer's timebase, so there has to be one.
        CMTimebaseRef timebase = NULL;
        CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase);
        if(timebase) {
            shim.controlTimebase = timebase;
            CMTimebaseSetTime(timebase, kCMTimeZero);
            CMTimebaseSetRate(timebase, 0.0);
            CFRelease(timebase);
        }

        // In the window, behind the guest's own content. AVKit refuses to start
        // for a source it cannot see — `sourceIsVisible` is one of the things it
        // checks — and being covered is not the same as being hidden.
        UIView *shimView = [[UIView alloc] initWithFrame:shim.frame];
        [shimView.layer addSublayer:shim];
        [vc.view insertSubview:shimView atIndex:0];
        self.videoShimView = shimView;
        self.videoShimLayer = shim;
        self.videoHostLayer = videoHost;

        LCGuestPlaybackProxy *proxy = [[LCGuestPlaybackProxy alloc] initWithDataUUID:vc.dataUUID];
        proxy.shimLayer = shim;
        self.playbackProxy = proxy;

        AVPictureInPictureControllerContentSource *videoSource = [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:shim playbackDelegate:proxy];
        self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:videoSource];
        self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        self.pipController.delegate = self;
        proxy.controller = self.pipController;
        return;
    }

    self.pipVideoCallViewController.preferredContentSize = vc.view.bounds.size;
    if(vc.usesHostingControllerAPI) {
        self.pipVideoCallContentView = [[UIView alloc] initWithFrame:self.pipVideoCallViewController.view.bounds];
        self.pipVideoCallContentView.layer.anchorPoint = CGPointMake(0, 0);
        self.pipVideoCallContentView.layer.position = CGPointMake(0, 0);
        [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
    } else {
        self.pipVideoCallContentView = vc.contentView;
    }
    AVPictureInPictureControllerContentSource* contentSource = [[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:vc.view contentViewController:self.pipVideoCallViewController];
    self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
    self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
    self.pipController.delegate = self;
    [self.pipController setValue:@1 forKey:@"controlsStyle"];
}

/// Readies `vc` to float without floating it.
///
/// `canStartPictureInPictureAutomaticallyFromInline` is what makes a window float
/// when LiveContainer is backgrounded, and AVKit can only act on it through a
/// controller that already exists. Building one only when PiP is chosen from a
/// menu meant that by the time there was anything to act on, the user was already
/// looking at the home screen. So the window in front keeps a controller ready at
/// all times, and leaving LiveContainer is enough.
///
/// Only ever one: the system allows a single PiP window, and a controller armed
/// on a window the user is not looking at would race the one they are.
- (void)armForVC:(AppSceneViewController*)vc {
    if(!vc) return;
    // A live PiP window — or one on its way to being live — outranks whatever is
    // now in front behind it. It was put there deliberately and re-arming would
    // tear it down.
    if(self.isPiP || self.isStartingPiP) return;
    if(self.pipController && self.displayingVC == vc) return;
    // Only a window with a video to float is armed. Arming was once unconditional,
    // which meant leaving LiveContainer floated whatever happened to be in front —
    // Settings, a messaging app, anything — as a shrunken copy of its whole window,
    // which nobody asked for. A guest says it has a video by reporting its shape,
    // and only then is there something worth floating without being asked.
    //
    // Floating a window on purpose is untouched: the switcher card's own PiP
    // builds its controller at the moment it is chosen.
    if(!vc.guestHasVideo) return;
    // On stage, but its guest has not presented a scene yet — a window is brought
    // to the front the moment it is created, which is well before there is
    // anything in it to float. Binding a controller to that would capture a
    // content view that does not exist. `appSceneVCDidPresentScene:` asks again
    // once it does.
    if(!vc.contentView) return;
    [self prepareControllerForVC:vc];
}

/// Drops the armed controller, unless PiP is running on it or starting.
- (void)disarmIfInactive {
    if(self.isPiP || self.isStartingPiP) return;
    [self tearDownVideoShim];
    self.preparedVideoContextId = 0;
    self.pipController = nil;
    self.pipVideoCallViewController = nil;
    self.pipVideoCallContentView = nil;
    self.displayingVC = nil;
}

- (void)rearmForVC:(AppSceneViewController*)vc {
    if(self.isPiP || self.isStartingPiP) return;
    if(self.displayingVC && self.displayingVC != vc) return;

    // Resized in place when there is already a video controller armed for this
    // window, rather than torn down and built again. Rebuilding is what made
    // floating unreliable: a fresh controller has to tell SpringBoard it may
    // start on backgrounding, that goes over XPC, and one built moments before
    // the user leaves has not finished saying so — hence a float that sometimes
    // simply never appeared. The video's measurement changes while the player
    // settles, so this happens more than once per window.
    if(self.videoShimLayer && self.videoHostLayer && self.displayingVC == vc) {
        CGSize size = vc.guestVideoSize;
        if(size.width < 1 || size.height < 1) return;
        if(CGSizeEqualToSize(self.videoShimLayer.bounds.size, size)) return;
        NSLog(@"[LC] armed video resized to %dx%d", (int)size.width, (int)size.height);
        self.videoShimLayer.frame = CGRectMake(0, 0, size.width, size.height);
        self.videoHostLayer.frame = self.videoShimLayer.bounds;
        self.videoShimView.frame = self.videoShimLayer.frame;
        // The window's shape comes from the layer's video dimensions, which come
        // from what was last enqueued into it — so the new shape has to be
        // enqueued, not just assigned.
        LCEnqueueBlackFrame(self.videoShimLayer, size);
        return;
    }

    [self disarmIfInactive];
    [self armForVC:vc];
}

- (void)disarmIfInactiveForVC:(AppSceneViewController*)vc {
    // Someone else's turn to be armed; leaving it alone is the point of asking.
    if(self.displayingVC != vc) return;
    [self disarmIfInactive];
}

- (void)startPiPWithVC:(AppSceneViewController*)vc {
    // Already armed for this window, which is now the ordinary case: the window
    // in front keeps a controller ready. Nothing to tear down and nothing to wait
    // for, so it starts at once rather than after the two delays below.
    // Rebuilt rather than reused when the window is now offering a video context
    // it was not offering when it was armed, which is the ordinary case: a window
    // is armed as soon as it comes to the front, and its guest only publishes
    // video when it asks to float.
    // Armed around this window's video already, with only the context id left to
    // fill in — the ordinary case now, since the controller is built as soon as
    // the guest reports it has a video and the guest publishes only at the last
    // moment, publishing being what takes the video out of the app's own window.
    if(self.pipController && self.displayingVC == vc && !self.isPiP
       && self.videoHostLayer && vc.guestVideoContextId != 0) {
        self.preparedVideoContextId = vc.guestVideoContextId;
        self.videoHostLayer.contextId = vc.guestVideoContextId;

        // Started by hand only while LiveContainer is still foreground active,
        // which is to say only when the guest's button asked. AVKit refuses
        // otherwise — "The UIScene for the content source has an activation state
        // other than UISceneActivationStateForegroundActive" — and on the way out
        // nothing needs calling: the controller has been armed since the guest
        // first reported a video, and AVKit starts it on backgrounding itself.
        if(UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            NSLog(@"[LC] video context %u armed; leaving the start to AVKit", vc.guestVideoContextId);
            return;
        }
        self.isStartingPiP = YES;
        [self.pipController startPictureInPicture];
        return;
    }
    if(self.pipController && self.displayingVC == vc && !self.isPiP
       && self.preparedVideoContextId == vc.guestVideoContextId) {
        self.isStartingPiP = YES;
        [self.pipController startPictureInPicture];
        return;
    }
    BOOL wasActive = self.isPiP;
    [self.pipController stopPictureInPicture];
    // Only a window that was really floating has to be brought back. An armed one
    // was never minimized, and telling the dock a window has left a PiP it never
    // entered leaves the switcher believing something that is not so.
    if(self.displayingVC && wasActive) {
        [self.displayingDecoratedVC unminimizeWindowPiP];
        [self pictureInPictureControllerDidStopPictureInPicture:self.pipController];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wasActive * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self prepareControllerForVC:vc];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.isStartingPiP = YES;
            [self.pipController startPictureInPicture];
        });
    });

}

- (void)stopPiP {
    [self.pipController stopPictureInPicture];
}

// PIP delegate
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // The one place both routes into PiP meet — chosen from a window's menu, or
    // started by AVKit because LiveContainer was backgrounded with a window
    // armed — and where a start AVKit began on its own is first heard about.
    //
    // Set before minimizing, which is what sets off the chain that would
    // otherwise disarm this controller mid-start.
    //
    // No audio session is taken here. LiveContainer used to claim one — playback,
    // not mixable, activated — on the reasoning that PiP had to keep running once
    // the app was backgrounded and a mixable session would not survive that. What
    // actually keeps it running is the assertion SpringBoard takes on this
    // process for the duration:
    //
    //     PGProcessAssertion … PIP Visible Assertion target: <our pid>
    //         domain:"com.apple.pictureinpicture" name:"PIPVisible"
    //
    // The host never plays anything, so its session only ever did one thing:
    // interrupt the guest whose window was about to float, stopping the playback
    // the user floated it to keep watching. If a PiP window is ever found dying
    // on backgrounding again, take a *mixable* session rather than this one —
    // secondary audio costs the guest nothing.
    self.isStartingPiP = YES;

    // Nothing to move or lay out on this path: AVKit builds the window's content
    // from the source layer itself, and sizes the window from the video.
    //
    // The window is also left where it is rather than minimized, which is the
    // difference between a PiP that survives and one that does not. The picture
    // in the window is a context the guest is still drawing into, and a guest
    // whose scene nothing is displaying stops drawing — so hiding the window took
    // the picture with it the moment the user went anywhere, whether to another
    // window, to FlekDeck's own springboard, or out of FlekDeck entirely. The
    // other path gets away with hiding the window because it moves the guest's
    // scene view into the PiP window, which is somewhere visible; this one moves
    // nothing. Leaving the app on stage behind its own floating video is what PiP
    // does everywhere else in any case.
    if(self.preparedVideoContextId != 0) {
        // Now, and not before: the app puts a placeholder where its video was as
        // soon as it hears this, so it must not hear it until there is a floating
        // window to put the video in.
        [self.displayingVC notifyGuestPiPStarted];
        [self.displayingVC setBackgroundNotificationEnabled:false];
        self.displayingVC.shouldIgnoreSceneUpdates = YES;
        [self beginKeepingGuestOnStage];
        [self.playbackProxy startDrivingTimebase];
        return;
    }

    [self.displayingDecoratedVC minimizeWindowPiP];

    if(self.displayingVC.usesHostingControllerAPI) {
        self.pipVideoCallContentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
        self.pipVideoCallViewController.additionalSafeAreaInsets = self.displayingVC.view.safeAreaInsets;
        [self.pipVideoCallContentView addSubview:self.displayingVC.contentView];
    } else {
        self.displayingVC.contentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
    }
    [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
    [self observeBoundsOfLayer:self.pipVideoCallViewController.view.layer];
    self.pipVideoCallViewController.preferredContentSize = self.displayingVC.view.bounds.size;
    [self.displayingVC setBackgroundNotificationEnabled:false];
    self.displayingVC.shouldIgnoreSceneUpdates = YES;
}



- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    // Never minimized on the video path, so there is nothing to bring back.
    if(self.preparedVideoContextId != 0) return;
    [self.displayingDecoratedVC unminimizeWindowPiP];
}

/// Holds the guest's scene foreground for as long as its video is floating.
///
/// `setBackgroundNotificationEnabled:` writes the scene's settings once, and on
/// iOS 18 and up FBSSceneObserver pushes the host's own state through on top of
/// whatever was written — so a single write survives only until LiveContainer next
/// changes state, which is precisely when it is needed. Re-applied on every such
/// change instead.
- (void)beginKeepingGuestOnStage {
    if(self.guestOnStageObserver) return;
    __weak typeof(self) weakSelf = self;
    void (^reassert)(NSNotification *) = ^(NSNotification *note) {
        PiPManager *manager = weakSelf;
        if(!manager || manager.preparedVideoContextId == 0) return;
        [manager.displayingVC setBackgroundNotificationEnabled:false];
    };
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    self.guestOnStageObserver = @[
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:reassert],
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:reassert],
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:reassert],
    ];
}

- (void)endKeepingGuestOnStage {
    for(id observer in self.guestOnStageObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
    }
    self.guestOnStageObserver = nil;
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // A controller already replaced — PiP handed from one window to another
    // before its stop came back — has nothing here that is still its own: the
    // window, the content view and the layer under observation all belong to
    // its successor now.
    if(pictureInPictureController != self.pipController) return;
    self.isStartingPiP = NO;
    // The video path never took the scene view out of its window, so there is
    // nothing to give back — putting the content view back would move a view that
    // never left. What does have to go back is the guest's own video layer, which
    // is out of the app's tree for as long as it is published.
    if(self.preparedVideoContextId != 0) {
        self.preparedVideoContextId = 0;
        self.displayingVC.guestVideoContextId = 0;
        [self.displayingVC notifyGuestPiPEnded];
        [self.displayingVC setBackgroundNotificationEnabled:true];
        [self.displayingDecoratedVC updateVerticalConstraints];
        [self observeBoundsOfLayer:nil];
        [self tearDownVideoShim];
        // Always dropped, whatever LCAutoEndPiP says. This controller is built
        // around a context the guest has stopped publishing, so there is nothing
        // for it to show a second time; the window arms a fresh one when it comes
        // back to the front.
        self.pipController = nil;
        return;
    }
    [self.displayingVC.view insertSubview:self.displayingVC.contentView atIndex:0];
    [self.displayingVC setBackgroundNotificationEnabled:true];
    // resize if needed (eg orientation differs)
    [self.displayingDecoratedVC updateVerticalConstraints];
    
    self.pipVideoCallContentView.transform = CGAffineTransformIdentity;
    // Before the view controller can be released below with the observation
    // still registered on its layer, which is a crash — and just the same when
    // it is kept: the next start watches a fresh layer, and this one is done.
    [self observeBoundsOfLayer:nil];
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoEndPiP"]) {
        self.pipController = nil;
        self.pipVideoCallViewController = nil;
    }
    // FIXME: HostingController path causes a tiny flicker during transition to and from PiP.
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    // The PiP window's own restore button, and the system's cue to put the
    // interface back for the content that was floating — with LiveContainer
    // brought to the foreground for it if it was in the background. AVKit waits
    // on the answer before it finishes the PiP window's exit, so the answer
    // waits on the window's fade: there is then something on stage where the
    // PiP window is headed. -willStop brings the window back as well, and both
    // run for a press of this button; the return is harmless to repeat.
    DecoratedAppSceneViewController *decoratedVC = self.displayingDecoratedVC;
    // On the video path the window never left the stage, so there is nothing to
    // wait for — only LiveContainer itself to come forward, which the system does
    // for us on the way out of this.
    if(!decoratedVC || self.preparedVideoContextId != 0) {
        completionHandler(YES);
        return;
    }
    [decoratedVC unminimizeWindowPiPWithCompletion:^{
        completionHandler(YES);
    }];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    // A start that never became one: nothing is holding this controller now, and
    // leaving the flag set would keep the window armed on it forever.
    self.isStartingPiP = NO;
    NSLog(@"[LC] PiP failed to start: %@", error);

    // Showing only the video is the better window but the newer path, and it asks
    // AVKit to start for a sample buffer layer nothing ever feeds. If it will not,
    // the window still floats — as the whole app, the way it did before any of
    // this — rather than not floating at all. The guest takes its video layer back
    // first, or the window it floats would be the one with the video missing.
    // Refused only because the scene is no longer foreground active. The armed
    // controller is still good and AVKit starts it on its own as the app
    // backgrounds; falling back here would swap the video for the whole window
    // for no reason.
    if(error.code == -1001) return;

    AppSceneViewController *vc = self.displayingVC;
    if(self.preparedVideoContextId != 0 && vc) {
        NSLog(@"[LC] falling back to floating the whole window");
        self.preparedVideoContextId = 0;
        vc.guestVideoContextId = 0;
        [vc notifyGuestPiPEnded];
        [self tearDownVideoShim];
        self.pipController = nil;
        [self startPiPWithVC:vc];
    }
}

/// Watches `layer`'s bounds, and stops watching whichever layer was being
/// watched before — nil to only stop. Every start and stop goes through here,
/// so the observation is registered exactly once per layer however the AVKit
/// callbacks arrive: -willStart can run without a -didStop (a start that
/// fails), and -didStop can run twice for one stop (once called directly when
/// PiP is handed from one window to another, once from AVKit).
- (void)observeBoundsOfLayer:(CALayer *)layer {
    if(self.observedLayer == layer) return;
    [self.observedLayer removeObserver:self forKeyPath:@"bounds" context:kPiPBoundsObservationContext];
    self.observedLayer = layer;
    [layer addObserver:self forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:kPiPBoundsObservationContext];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(NSObject*)object change:(NSDictionary<NSString *,id> *) change context:(void *) context {
    if(context != kPiPBoundsObservationContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    CGRect rect = [change[@"new"] CGRectValue];
    // The video path has no scene view in the window to scale — AVKit lays its
    // own content out — so there is nothing here for it.
    if(self.preparedVideoContextId != 0) return;
    CGFloat scale = self.displayingVC.usesHostingControllerAPI ? self.displayingVC.scaleRatio : 1;
    CGAffineTransform transform1 = CGAffineTransformScale(CGAffineTransformIdentity, rect.size.width / self.displayingVC.contentView.bounds.size.width/scale,rect.size.height /self.displayingVC.contentView.bounds.size.height/scale);
    self.pipVideoCallContentView.transform = transform1;
}

@end
