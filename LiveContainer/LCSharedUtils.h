@import Foundation;

// Posted by FlekDeck when its windows' processes may be about to die with no
// warning of their own, telling each guest to write out what it keeps in memory.
#define LCGuestFlushNotification "com.kdt.livecontainer.guest.flush"

@interface LCSharedUtils : NSObject
+ (NSString*) teamIdentifier;
+ (NSString *)appGroupID;
+ (NSURL*) appGroupPath;
+ (NSURL*) shareInboxPath;
+ (NSString *)certificatePassword;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode;
+ (void)requestGuestFlush;
+ (BOOL)launchToGuestAppWithURL:(NSURL *)url;
+ (void)setWebPageUrlForNextLaunch:(NSString*)urlString;
+ (BOOL)isLCSchemeInUse:(NSString*)lc;
+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName;
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57;
+ (void)moveSharedAppFolderBack;
// Puts back the copy of this private app's data container a window left in the
// app group, if there is one. Call before the app starts in single mode.
+ (void)settleStagedContainer:(NSString*)folderName;
+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut;
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID;
+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId;
+ (NSArray<NSString*>*)lcUnorderedUrlSchemes;
+ (NSArray<NSString*>*)lcUrlSchemes;
+ (NSString *)liveProcessBundleIdentifier;
// Turns on FlekDeck's own VPN, which built-in JIT connects through, if the user
// has set it up. The handler gets whether a start was asked for, on the main
// queue; the tunnel itself is up a moment later.
+ (void)startBuiltInVPNWithCompletionHandler:(void (^)(BOOL requested))completionHandler;
@end

// Staging of private apps for windows, used by AppSceneViewController.m and by a
// single-mode launch. appGroupLC is the LiveContainer folder in the app group.
// Trees are discarded by a rename into a trash folder, emptied by the sweep.
BOOL LCDiscardTree(NSURL *url, NSURL *appGroupLC);
void LCSweepStagingTrash(NSURL *appGroupLC);
BOOL LCCloneTree(NSURL *src, NSURL *dst);
NSString *LCStagingRelativePath(void);
NSURL *LCStagingRootURL(NSURL *appGroupLC);
void LCWriteStagingMark(NSURL *staged, NSURL *local);
BOOL LCContainerIsInUse(NSString *folderName);
void LCReclaimStagedContainer(NSURL *stagedData, NSURL *localData, NSURL *appGroupLC);
