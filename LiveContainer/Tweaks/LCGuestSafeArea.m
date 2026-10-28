//
//  LCGuestSafeArea.m
//  LiveContainer
//
//  Keeps a multitask guest from being laid out without a safe area while its
//  window's scene is still being set up.
//
//  An app built against the iOS 26 SDK or later is laid out from a scene's
//  `safeAreaEdgeInsets` once the scene carries them, and from the older
//  `safeAreaInsetsPortrait` before that. A window's scene reaches the guest with
//  FlekDeck's insets in the older field and all zeros in the newer one, which
//  FlekDeck only fills in once the window's view is on screen. The guest's window
//  reads no safe area for its first frames, and the right insets arrive a moment
//  later.
//
//  Most apps lay out again when they do. An app that measures its insets once, at
//  launch, keeps the zero: Instagram takes its window's top inset as the height
//  of the status bar a single time, and drew every navigation bar underneath the
//  status bar, where it could not be tapped. Measured on an iPhone 16 Pro: the
//  scene carried {62, 0, 0, 0} in the older field and zeros in the newer one
//  while Instagram's window first came on screen.
//
//  So in LiveProcess, a scene whose newer field is empty while the older one is
//  not is laid out from the older one. FlekDeck writes the two together on every
//  later update, so this only applies while the scene is being set up.
//
@import UIKit;
@import ObjectiveC;
#import <objc/message.h>
#import "utils.h"

static UIEdgeInsets LCSceneSettingInsets(UIScene *scene, NSString *name) {
    SEL fbsSceneSel = NSSelectorFromString(@"_FBSScene");
    if(![scene respondsToSelector:fbsSceneSel]) return UIEdgeInsetsZero;
    id fbsScene = ((id (*)(id, SEL))objc_msgSend)(scene, fbsSceneSel);
    SEL settingsSel = NSSelectorFromString(@"settings");
    if(![fbsScene respondsToSelector:settingsSel]) return UIEdgeInsetsZero;
    id settings = ((id (*)(id, SEL))objc_msgSend)(fbsScene, settingsSel);
    SEL insetsSel = NSSelectorFromString(name);
    if(![settings respondsToSelector:insetsSel]) return UIEdgeInsetsZero;
    return ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(settings, insetsSel);
}

@implementation UIWindowScene(LCGuestSafeArea)
- (BOOL)hook__usesSceneSettingBasedSafeAreaInsets {
    if(![self hook__usesSceneSettingBasedSafeAreaInsets]) return NO;
    if(!UIEdgeInsetsEqualToEdgeInsets(LCSceneSettingInsets(self, @"safeAreaEdgeInsets"), UIEdgeInsetsZero)) return YES;
    return UIEdgeInsetsEqualToEdgeInsets(LCSceneSettingInsets(self, @"safeAreaInsetsPortrait"), UIEdgeInsetsZero);
}
@end

// Installed as the framework loads, before the guest has any code running, and
// only in LiveProcess: Single Mode runs in FlekDeck's own scene, which SpringBoard
// fills in like any other app's.
__attribute__((constructor))
static void LCGuestSafeAreaInit(void) {
    if(![NSBundle.mainBundle.bundlePath hasSuffix:@"PlugIns/LiveProcess.appex"]) return;
    SEL original = NSSelectorFromString(@"_usesSceneSettingBasedSafeAreaInsets");
    if(!class_getInstanceMethod(UIWindowScene.class, original)) return;
    swizzle(UIWindowScene.class, original, @selector(hook__usesSceneSettingBasedSafeAreaInsets));
}
