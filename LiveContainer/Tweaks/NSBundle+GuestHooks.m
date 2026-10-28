//
//  NSBundle+GuestHooks.m
//  LiveContainer
//
//  UIKit does not open an asset catalog from the NSBundle it is handed. CoreUI
//  takes that bundle's identifier, asks +[NSBundle bundleWithIdentifier:] for a
//  bundle and reads Assets.car out of whatever comes back. The lookup is
//  CoreFoundation's, which only knows the identifier written in Info.plist.
//
//  A tweak that answers -[NSBundle bundleIdentifier] with something else for the
//  main bundle breaks that round trip: the identifier CoreUI asks for belongs to
//  no bundle, the catalog is never opened, and every image in it is nil for the
//  rest of the process. Regram does this whenever Instagram's identifier on disk
//  is not com.burbn.instagram — its duplicate IPA, a re-signed copy, or "Use
//  FlekDeck's Bundle ID" — and Instagram, which hands its images around as lazy
//  proxies, then throws the first time it uses one of them:
//  -[NSProxy doesNotRecognizeSelector:_rasterizedImage].
//
//  So when nothing answers to an identifier, and it is the one the main bundle
//  reports for itself, answer with the main bundle.
//

#import "utils.h"
#import "Tweaks.h"

@implementation NSBundle(LiveContainerGuestHooks)

+ (NSBundle *)hook_bundleWithIdentifier:(NSString *)identifier {
    NSBundle *bundle = [self hook_bundleWithIdentifier:identifier];
    if(bundle || !identifier) {
        return bundle;
    }
    NSBundle *mainBundle = NSBundle.mainBundle;
    if(![identifier isEqualToString:mainBundle.bundleIdentifier]) {
        return nil;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[LC] no bundle answers to %@, which the main bundle reports as its identifier; answering with the main bundle", identifier);
    });
    return mainBundle;
}

@end

void NSBundleGuestHooksInit(void) {
    swizzleClassMethod(NSBundle.class, @selector(bundleWithIdentifier:), @selector(hook_bundleWithIdentifier:));
}
