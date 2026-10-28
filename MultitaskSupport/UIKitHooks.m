//
//  UIKitHooks.m
//  LiveContainer
//
//  Created by Duy Tran on 25/6/26.
//
@import ObjectiveC;
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"

static BOOL LCHasRemoteSheetProviderSelector;

UIEdgeInsets LCUIEdgeInsetsRotateToOrientation(UIEdgeInsets insets, UIInterfaceOrientation orientation) {
    switch(orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return UIEdgeInsetsMake(insets.left, 0, insets.right, insets.bottom);
        case UIInterfaceOrientationLandscapeRight:
            return UIEdgeInsetsMake(insets.left, insets.bottom, insets.right, 0);
        default:
            return insets;
    }
}

/// `UIApplication.statusBarOrientation` is the old way to ask, and on iOS 27 it
/// is a no-op for an app built against the iOS 27 SDK: it answers unknown, and
/// UIKit logs that it has been deprecated. A guest's scene created from that
/// answer faces no direction at all until a later update gives it one, and UIKit
/// looks a scene's status bar height up by orientation.
UIInterfaceOrientation LCHostInterfaceOrientation(UIView *view) {
    UIWindowScene *scene = view.window.windowScene;
    if(!scene) {
        for(UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if(![candidate isKindOfClass:UIWindowScene.class]) continue;
            scene = (UIWindowScene *)candidate;
            if(candidate.activationState == UISceneActivationStateForegroundActive) break;
        }
    }
    return scene.interfaceOrientation;
}

// Fix _UIPrototypingMenuSlider not continually updating its value on iOS 17+
API_AVAILABLE(ios(17.0))
@implementation _UIFluidSliderInteraction(Hook)
- (NSInteger)_state {
    return 2;
}
@end

@interface FBScene(hooks)
- (void)hook__performUpdateWithoutActivation:(void (^)(UIMutableApplicationSceneSettings *settings, FBSSceneTransitionContext *context))updateBlock;
@end

/// Hook to fix safe area scaling and orientation. We use superview's safeAreaInsets because self one tends to bug out with certain scaling, and also allows us to customize safe area while in PiP mode later on.
/// This hook applies across 18.0-27.0. 17.4+ is uncertain.
API_AVAILABLE(ios(17.0))
void hook_FBScene_performUpdateWithoutActivation(FBScene* self, SEL _cmd, void (^updateBlock)(UIMutableApplicationSceneSettings *, FBSSceneTransitionContext *)) {
    // We don't wanna mess up system extensions on iOS 26+
    if(LCHasRemoteSheetProviderSelector && self.ui_viewServiceComponent) {
        [self hook__performUpdateWithoutActivation:updateBlock];
        return;
    }
    
    _UISceneHostingController *controller = self.delegate;
    _UISceneHostingView *view = controller.sceneView;
    id wrappedBlock = ^(UIMutableApplicationSceneSettings *settings, FBSSceneTransitionContext *context) {
        updateBlock(settings, context);
        CGAffineTransform transform = view.transform;
        UIEdgeInsets orig = view.superview.safeAreaInsets;
        if(LCHasRemoteSheetProviderSelector && UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
            // apps with glass has an extra top safe area space, so clear it (will it cause inconsistencies?)
            orig.top = 0;
        }
        UIEdgeInsets insets = UIEdgeInsetsMake(orig.top / transform.d, orig.left / transform.a, orig.bottom / transform.d, orig.right / transform.a);
        if(@available(iOS 19.0, *)) {
            settings.safeAreaEdgeInsets = insets;
            // fix orientation
            settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(insets, settings.interfaceOrientation);
        } else {
            settings.safeAreaInsetsPortrait = insets;
        }
    };
    [self hook__performUpdateWithoutActivation:wrappedBlock];
}

void UIKitFixesInit(void) {
    if (@available(iOS 17.0, *)) {
        Class FBSceneClass = PrivClass(FBScene);
        LCHasRemoteSheetProviderSelector = [FBSceneClass instancesRespondToSelector:@selector(ui_viewServiceComponent)];
        class_addMethod(FBSceneClass, @selector(hook__performUpdateWithoutActivation:), (IMP)hook_FBScene_performUpdateWithoutActivation, "v@:@");
        swizzle(FBSceneClass, @selector(_performUpdateWithoutActivation:), @selector(hook__performUpdateWithoutActivation:));
    }
}
