//
//  PiPManager.h
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
@import Foundation;
@import AVKit;
@import UIKit;
#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface PiPManager : NSObject<AVPictureInPictureControllerDelegate>
@property (class, nonatomic, readonly) PiPManager *shared;
// Whether the singleton exists yet. Constructing it has side effects, so a
// caller that only wants to know whether PiP is running must ask this first —
// if there is no manager, there is no PiP, and the answer is already known.
@property (class, nonatomic, readonly) BOOL hasShared;
@property (nonatomic, readonly) bool isPiP;
- (BOOL)isPiPWithVC:(AppSceneViewController*)vc;
- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc;
- (void)stopPiP;
- (void)startPiPWithVC:(AppSceneViewController*)vc;
/// Readies `vc` to float when LiveContainer is backgrounded, without floating it
/// now. Only the window in front is ever armed — the system allows one PiP
/// window, and arming costs nothing, so it is simply kept current.
- (void)armForVC:(AppSceneViewController*)vc;
/// Drops the armed controller. A window that is actually floating is left alone.
- (void)disarmIfInactive;
/// `disarmIfInactive`, but only when it is `vc` that is armed — for a window on
/// its way out, which must not take another window's readiness with it.
- (void)disarmIfInactiveForVC:(AppSceneViewController*)vc;
/// Builds the armed controller again for `vc`, because what it should be built
/// around has changed — the guest reporting it has a video, which decides whether
/// leaving FlekDeck floats the video or the whole window.
- (void)rearmForVC:(AppSceneViewController*)vc;

@end
