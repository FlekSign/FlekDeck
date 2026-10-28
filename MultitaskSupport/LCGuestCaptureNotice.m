//
//  LCGuestCaptureNotice.m
//  LiveContainer
//

#import "LCGuestCaptureNotice.h"
#import "Localization.h"
#import <notify.h>

/// The kind of report, carried in the notification's 64-bit state. See
/// LCGuestCapture.m: a user action is one tap producing one refusal, while a
/// repeating failure can announce itself on its own for as long as the app runs.
typedef NS_ENUM(uint64_t, LCCaptureReportSource) {
    LCCaptureReportUserAction = 0,
    LCCaptureReportRepeating = 1,
};

#pragma mark - Sheet

/// The explainer itself: symbol, title, what happened, what to do, a picture of
/// the menu to do it in, and one button. Laid out the way the system lays out
/// its own "this isn't available, here's why" sheets — Dynamic Type throughout,
/// system colours, a grabber, and a detent that fits the content rather than a
/// guessed height.
API_AVAILABLE(ios(16.0))
@interface LCMicSingleModeSheet : UIViewController
@property(nonatomic, copy) void (^onDismiss)(void);
@end

@interface LCMicSingleModeSheet()
@property(nonatomic) UIStackView *stack;
@property(nonatomic) UIScrollView *scroll;
@end

@implementation LCMicSingleModeSheet

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = NO;
    [self.view addSubview:_scroll];

    _stack = [UIStackView new];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.alignment = UIStackViewAlignmentFill;
    _stack.spacing = 12;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack];

    UILayoutGuide *content = _scroll.contentLayoutGuide;
    UILayoutGuide *frame = _scroll.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // The grabber sits in the top 20pt or so of the sheet, so the content
        // starts below it rather than under it.
        [_stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:28],
        [_stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [_stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [_stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-48],
    ]];

    [self buildContent];
}

- (UILabel *)labelWithText:(NSString *)text style:(UIFontTextStyle)style color:(UIColor *)color bold:(BOOL)bold {
    UILabel *label = [UILabel new];
    UIFont *font = [UIFont preferredFontForTextStyle:style];
    if(bold) {
        UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
        if(descriptor) font = [UIFont fontWithDescriptor:descriptor size:0];
    }
    label.font = font;
    label.adjustsFontForContentSizeCategory = YES;
    label.text = text;
    label.textColor = color;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    return label;
}

- (void)buildContent {
    UIImageSymbolConfiguration *symbolConfig =
        [[UIImageSymbolConfiguration configurationWithPointSize:44 weight:UIImageSymbolWeightRegular]
            configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationPreferringMulticolor]];
    UIImageView *symbol = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"mic.slash.fill" withConfiguration:symbolConfig]];
    symbol.tintColor = self.view.tintColor;
    symbol.contentMode = UIViewContentModeScaleAspectFit;
    [symbol.heightAnchor constraintEqualToConstant:48].active = YES;
    [self.stack addArrangedSubview:symbol];

    UILabel *title = [self labelWithText:@"lc.multitask.micSingleMode.title".loc
                                   style:UIFontTextStyleTitle2 color:UIColor.labelColor bold:YES];
    [self.stack addArrangedSubview:title];
    [self.stack setCustomSpacing:16 afterView:symbol];

    UILabel *desc = [self labelWithText:@"lc.multitask.micSingleMode.desc".loc
                                  style:UIFontTextStyleSubheadline color:UIColor.secondaryLabelColor bold:NO];
    [self.stack addArrangedSubview:desc];
    [self.stack setCustomSpacing:8 afterView:title];

    UILabel *how = [self labelWithText:@"lc.multitask.micSingleMode.how".loc
                                 style:UIFontTextStyleSubheadline color:UIColor.labelColor bold:NO];
    [self.stack addArrangedSubview:how];
    [self.stack setCustomSpacing:20 afterView:desc];

    // The screenshot of the menu just described. Drawn from LiveContainer's own
    // bundle rather than whatever NSBundle.mainBundle has become, which is the
    // same bundle the strings above came from.
    NSBundle *bundle = NSUserDefaults.lcMainBundle ?: NSBundle.mainBundle;
    UIImage *helper = [UIImage imageNamed:@"singleHelper" inBundle:bundle compatibleWithTraitCollection:nil];
    UIView *lastBeforeButton = how;
    if(helper && helper.size.height > 0) {
        UIImageView *shot = [[UIImageView alloc] initWithImage:helper];
        shot.translatesAutoresizingMaskIntoConstraints = NO;
        shot.contentMode = UIViewContentModeScaleAspectFill;
        shot.layer.cornerRadius = 14;
        shot.layer.cornerCurve = kCACornerCurveContinuous;
        shot.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        shot.layer.borderColor = UIColor.separatorColor.CGColor;
        shot.clipsToBounds = YES;
        shot.isAccessibilityElement = NO;

        // Centred in a full-width row rather than filling one. An arranged
        // subview is stretched to the stack's width, and a portrait screenshot
        // stretched that way keeps its own size but takes a landscape frame — so
        // the rounded border and the picture stop being the same rectangle, and
        // what you see is a wide grey box with the screenshot floating in it.
        UIView *row = [UIView new];
        [row addSubview:shot];
        // The image is a 1x asset, so its intrinsic size is 588x819 *points* —
        // and at the default compression resistance that beats a height of our
        // own and blows the sheet past the bottom of the screen. The picture is
        // being scaled deliberately here; its natural size is not wanted.
        [shot setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
        [shot setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [shot setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
        [shot setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        // Tall enough to read the menu in, and beaten by the width limit below on
        // a narrow window, where the picture would otherwise run past the edges.
        NSLayoutConstraint *height = [shot.heightAnchor constraintEqualToConstant:280];
        height.priority = UILayoutPriorityRequired - 1;
        [NSLayoutConstraint activateConstraints:@[
            [shot.widthAnchor constraintEqualToAnchor:shot.heightAnchor
                                           multiplier:helper.size.width / helper.size.height],
            height,
            [shot.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor],
            [shot.topAnchor constraintEqualToAnchor:row.topAnchor],
            [shot.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
            [shot.centerXAnchor constraintEqualToAnchor:row.centerXAnchor],
        ]];
        [self.stack addArrangedSubview:row];
        [self.stack setCustomSpacing:12 afterView:how];
        lastBeforeButton = row;
    }

    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"lc.common.ok".loc;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.buttonSize = UIButtonConfigurationSizeLarge;
    __weak typeof(self) weakSelf = self;
    UIButton *ok = [UIButton buttonWithConfiguration:config primaryAction:
        [UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(UIAction *action) {
            LCMicSingleModeSheet *sheet = weakSelf;
            if(sheet.onDismiss) sheet.onDismiss();
            [sheet dismissViewControllerAnimated:YES completion:nil];
        }]];
    [self.stack addArrangedSubview:ok];
    [self.stack setCustomSpacing:24 afterView:lastBeforeButton];
}

/// The height this content wants at `width`, for the sheet's detent.
- (CGFloat)contentHeightForWidth:(CGFloat)width bottomInset:(CGFloat)bottomInset {
    [self.view layoutIfNeeded];
    CGFloat stackHeight = [self.stack systemLayoutSizeFittingSize:CGSizeMake(width - 48, UILayoutFittingCompressedSize.height)
                                   withHorizontalFittingPriority:UILayoutPriorityRequired
                                         verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    // The stack's own insets, plus room for the home indicator underneath the
    // button — a prominent button flush against the bottom edge reads as cut off.
    // The home indicator's strip already provides some of that, so only what it
    // does not cover is added.
    return stackHeight + 28 + 16 + MAX(bottomInset - 16, 0);
}

@end

#pragma mark - Notice

@interface LCGuestCaptureNotice()<UIAdaptivePresentationControllerDelegate>
@property(nonatomic) NSString *dataUUID;
@property(nonatomic) NSNumber *token;
@property(nonatomic, weak) UIViewController *sheet;
/// Whether the user has put this sheet away since the last time a repeating
/// failure raised it. Only repeating reports are held off by it; asking again is
/// always answered.
@property(nonatomic) BOOL dismissedByUser;
/// A retry is already scheduled for a window that had nothing to present from.
@property(nonatomic) BOOL awaitingPresenter;
@end

@implementation LCGuestCaptureNotice

- (instancetype)initWithDataUUID:(NSString *)dataUUID {
    self = [super init];
    if(self) {
        _dataUUID = dataUUID;
        [self observeGuest];
    }
    return self;
}

- (void)dealloc {
    // Only the token: the sheet belongs to the presentation it is part of, and by
    // the time this runs there is no main-thread guarantee to dismiss it on.
    if(_token) notify_cancel(_token.intValue);
}

// The same fixed literal keyed by container that LCAudioMute's and LCGuestPiP's
// channels use, and for the same reason: the two processes each work the app
// group id out for themselves, and they only have to disagree once for every
// message to vanish.
- (void)observeGuest {
    if(self.token || self.dataUUID.length == 0) return;
    NSString *name = [NSString stringWithFormat:@"com.kdt.livecontainer.capture.%@.unavailable", self.dataUUID];
    int token = 0;
    __weak typeof(self) weakSelf = self;
    if(notify_register_dispatch(name.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        // An unreadable state is treated as a user action: answering an attempt
        // that was not made is a smaller failure than ignoring one that was.
        if(notify_get_state(t, &state) != NOTIFY_STATUS_OK) state = LCCaptureReportUserAction;
        [weakSelf handleReport:(LCCaptureReportSource)state];
    }) == NOTIFY_STATUS_OK) {
        self.token = @(token);
    }
}

- (void)invalidate {
    // Cancelled here rather than on the main queue: this is called from the
    // guest's teardown, which does not run on it, and the point of cancelling is
    // that nothing more arrives — waiting for a main-queue hop would leave a
    // window open for one last sheet against a window that is closing.
    if(self.token) {
        notify_cancel(self.token.intValue);
        self.token = nil;
    }
    UIViewController *sheet = self.sheet;
    self.sheet = nil;
    if(!sheet.presentingViewController) return;
    dispatch_block_t takeDown = ^{ [sheet dismissViewControllerAnimated:NO completion:nil]; };
    if(NSThread.isMainThread) {
        takeDown();
    } else {
        dispatch_async(dispatch_get_main_queue(), takeDown);
    }
}

#pragma mark - Reporting

- (void)handleReport:(LCCaptureReportSource)source {
    // Something the user just did is always answered, however recently they put
    // the last answer away. Deciding that from the gap between reports instead —
    // which is what this used to do — could not tell a second tap on the call
    // button from the tail of the first one, and swallowed it.
    NSLog(@"[LCGuestCapture/host] report received: %@ (dismissed=%d, sheetUp=%d)",
          source == LCCaptureReportUserAction ? @"user action" : @"repeating",
          self.dismissedByUser, self.sheet.presentingViewController != nil);

    if(source == LCCaptureReportUserAction) {
        self.dismissedByUser = NO;
        [self show];
        return;
    }

    // A failure that repeats on its own gets one showing. Once the user has put
    // it away it stays away, because the next hundred reports say nothing the
    // first one did not — until a user action re-arms it above.
    if(self.dismissedByUser) {
        NSLog(@"[LCGuestCapture/host] repeating report held: already dismissed");
        return;
    }
    [self show];
}

#pragma mark - Presentation

/// The controller to present from: the window's own, or whatever it has already
/// put up. A window that is minimised or otherwise off screen has nothing to
/// present from and is left alone — the guest will report again next time.
- (UIViewController *)presenter {
    UIViewController *vc = self.hostViewController;
    if(!vc.viewIfLoaded.window) return nil;
    while(vc.presentedViewController) {
        // Nothing can be presented from either side of a dismissal that is still
        // animating. Rather than present onto a controller that will refuse it,
        // -show waits out the animation and tries once more.
        if(vc.presentedViewController.isBeingDismissed) return nil;
        vc = vc.presentedViewController;
    }
    return vc;
}

- (void)show {
    if(@available(iOS 16.0, *)) {
        // Already up and staying up: it is saying this already. A sheet that is
        // on its way out is a different matter — it is not going to say anything
        // more, so this falls through to -presenter, which answers nil while the
        // dismissal animates and so takes the retry below.
        if(self.sheet.presentingViewController && !self.sheet.isBeingDismissed) {
            NSLog(@"[LCGuestCapture/host] show skipped: sheet already on screen");
            return;
        }

        UIViewController *presenter = [self presenter];
        if(!presenter) {
            // Once, and only once: a window that is minimised or gone stays that
            // way, and a retry loop against it would never end.
            NSLog(@"[LCGuestCapture/host] nothing to present from (window=%d, presented=%@); retrying once",
                  self.hostViewController.viewIfLoaded.window != nil,
                  self.hostViewController.presentedViewController);
            if(self.awaitingPresenter) return;
            self.awaitingPresenter = YES;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LCGuestCaptureNotice *notice = weakSelf;
                notice.awaitingPresenter = NO;
                if([notice presenter]) [notice show];
            });
            return;
        }

        LCMicSingleModeSheet *sheet = [LCMicSingleModeSheet new];
        sheet.modalPresentationStyle = UIModalPresentationPageSheet;
        sheet.presentationController.delegate = self;
        __weak typeof(self) weakSelf = self;
        sheet.onDismiss = ^{ weakSelf.dismissedByUser = YES; };

        // Forced to lay out against the width it is about to be shown at, so the
        // detent below measures the real thing rather than a 0-wide stack.
        CGRect bounds = presenter.view.bounds;
        sheet.view.frame = bounds;
        CGFloat height = [sheet contentHeightForWidth:CGRectGetWidth(bounds)
                                          bottomInset:presenter.view.window.safeAreaInsets.bottom];

        UISheetPresentationController *presentation = sheet.sheetPresentationController;
        presentation.prefersGrabberVisible = YES;
        presentation.prefersScrollingExpandsWhenScrolledToEdge = NO;
        presentation.detents = @[
            [UISheetPresentationControllerDetent customDetentWithIdentifier:@"lcMicSingleMode"
                                                                  resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                // Never taller than the sheet is allowed to be; the scroll view
                // inside takes up the slack at the largest Dynamic Type sizes.
                return MIN(height, context.maximumDetentValue);
            }],
            UISheetPresentationControllerDetent.largeDetent,
        ];

        self.sheet = sheet;
        NSLog(@"[LCGuestCapture/host] presenting the sheet from %@", presenter);
        [presenter presentViewController:sheet animated:YES completion:nil];
    }
}

#pragma mark - UIAdaptivePresentationControllerDelegate

// Swiped away rather than dismissed by the button. Same meaning: the user has
// seen it, and nothing should show it again until the app asks afresh.
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    self.dismissedByUser = YES;
}

@end
