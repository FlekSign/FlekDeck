//
//  main.m
//  LiveContainer
//
//  Created by Duy Tran on 30/8/26.
//
@import Foundation;
#import <CommonCrypto/CommonCrypto.h>
#import <notify.h>
#import "../LiveContainer/FoundationPrivate.h"
#import "../LiveContainer/UIKitPrivate.h"
#import "../LiveContainer/utils.h"

@interface LiveProcessHandler : NSObject<NSExtensionRequestHandling>
+ (NSExtensionContext *)extensionContext;
+ (NSDictionary *)retrievedAppInfo;
@end

@interface StikJITWrapper : NSObject
+ (NSString *)enableJITWith:(int)pid timeout:(NSTimeInterval)timeout pairingFile:(NSURL *)pairing ddiPath:(NSURL *)ddi scriptJs:(NSString *)script;
@end

/// Tells FlekDeck that this is done with its connection, JIT on or not: with
/// the app in a window, FlekDeck is what switches Mobile Data back on where
/// its shortcut had switched it off for the launch.
static void StikJITSayOver(void) {
    notify_post("com.flekdeck.jit.over");
}

static int StikJITExitWithError(NSString *error) {
    NSLog(@"Cancelling with error: %@", error);
    StikJITSayOver();
    NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
    [context cancelRequestWithError:[NSError errorWithDomain:@"StikJIT" code:1 userInfo:@{NSLocalizedDescriptionKey: error}]];
    return 1;
}

int StikJITHeadlessMain(void) {
    NSError *e;
    NSDictionary *appInfo = [NSClassFromString(@"LiveProcessHandler") retrievedAppInfo];
    NSString *sandboxExtension = appInfo[@"sandboxExtension"];
    NSArray *sandboxExtensionSplit = [sandboxExtension componentsSeparatedByString:@";"];
    if (sandbox_extension_consume(sandboxExtension.UTF8String) < 1) {
        return StikJITExitWithError(@"Failed in sandbox_extension_issue_file");
    }
    
    NSString *path = sandboxExtensionSplit.lastObject;
    NSURL *sandboxURL = [NSURL fileURLWithPath:path];
    if (!sandboxURL) {
        return StikJITExitWithError(e.localizedDescription);
    }
    
    NSURL *pairingFile = [sandboxURL URLByAppendingPathComponent:@"ALTPairingFile.mobiledevicepairing"];
    NSURL *ddiPath = [sandboxURL URLByAppendingPathComponent:@"DMG"];
    if (![NSFileManager.defaultManager fileExistsAtPath:pairingFile.path]) {
        return StikJITExitWithError(@"Pairing file is not set.");
    }
    
    pid_t pid = [appInfo[@"pid"] unsignedIntValue];
    NSString *scriptJs = appInfo[@"script"];
    NSString *error = [StikJITWrapper enableJITWith:pid timeout:0.2 pairingFile:pairingFile ddiPath:ddiPath scriptJs:scriptJs];
    // FlekDeck's own VPN is turned on as the guest launches and takes a moment
    // to come up, during which the device does not answer.
    for (int attempt = 0; attempt < 12 && [appInfo[@"waitForVPN"] boolValue] && [error containsString:@"Timed out connecting to"]; attempt++) {
        error = [StikJITWrapper enableJITWith:pid timeout:0.5 pairingFile:pairingFile ddiPath:ddiPath scriptJs:scriptJs];
    }
    if (error.length < 1) {
        // The debugger has let go of the app, which with TXM is some time
        // after JIT came on: from here the app needs no connection, and says
        // so where the user is waiting to switch one back on.
        notify_post([NSString stringWithFormat:@"com.flekdeck.jit.done.%d", pid].UTF8String);
        StikJITSayOver();
        return 0;
    }
    if ([error containsString:@"Timed out connecting to"]) {
        error = [error stringByAppendingString:@"\n\nIs the VPN connected, and this device on Wi-Fi or in Airplane Mode? Turn the VPN on in Settings, under JIT, or connect LocalDevVPN."];
        // FIXME: auto open URL does not work
        // NSString *callbackScheme = appInfo[@"callbackScheme"];
        // LSApplicationWorkspace* workspace = [PrivClass(LSApplicationWorkspace) defaultWorkspace];
        // [workspace openURL:[NSURL fileURLWithPath:[@"localdevvpn://enable?scheme=" stringByAppendingString:callbackScheme]]];
        // error = [StikJITWrapper enableJITWith:pid timeout:4 pairingFile:pairingFile ddiPath:ddiPath scriptJs:scriptJs];
    }
    return StikJITExitWithError(error);
}
