//
//  LCGuestCaptureNotice.h
//  LiveContainer
//

@import Foundation;
@import UIKit;

NS_ASSUME_NONNULL_BEGIN

/// The host end of one guest's "the microphone was refused" channel.
///
/// iOS does not let an app extension record, and a multitask guest is an app
/// extension, so a call placed in a multitask window is silent in both
/// directions and a voice recorder sits at zero — with nothing said about it
/// anywhere. LCGuestCapture watches for the refusal inside the guest and posts
/// here; this raises a sheet explaining that the microphone needs Single Mode,
/// and showing the menu to reach for.
///
/// Advisory only. Nothing about the guest changes, and dismissing it changes
/// nothing either — it exists so a user whose call went quiet is told why.
@interface LCGuestCaptureNotice : NSObject

- (instancetype)initWithDataUUID:(NSString *)dataUUID;

/// The window's view controller, which the sheet is presented from. Weak: the
/// notice is owned by that controller and must not keep it alive.
@property(nonatomic, weak) UIViewController *hostViewController;

/// Drops the notification registration and takes down a sheet still on screen.
/// Safe to call more than once.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
