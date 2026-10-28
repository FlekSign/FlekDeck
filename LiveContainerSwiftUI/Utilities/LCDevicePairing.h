//
//  LCDevicePairing.h
//  LiveContainerSwiftUI
//
//  Makes a pairing file on the device itself, without a computer.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const LCDevicePairingErrorDomain;

typedef NS_ERROR_ENUM(LCDevicePairingErrorDomain, LCDevicePairingError) {
    /// IdevicePairing.dylib is not in this build, or would not load.
    LCDevicePairingErrorUnavailable = 1,
    /// The user has not allowed FlekDeck onto the local network.
    LCDevicePairingErrorLocalNetworkDenied,
    /// Nothing could be advertised, or listened on.
    LCDevicePairingErrorNetwork,
    /// The pairing library reported a failure of its own.
    LCDevicePairingErrorLibrary,
};

/// Advertises FlekDeck as a host this device can be paired with, and takes the
/// pairing once the user starts it from Settings › Privacy & Security ›
/// Developer Mode, which iOS 27 lets a device do with a host on its network —
/// itself included. An instance pairs once.
@interface LCDevicePairing : NSObject

/// Whether the pairing library is in this build. A Simulator build has none.
@property(class, nonatomic, readonly) BOOL isAvailable;

/// Starts advertising under `name`, which is what Settings shows. Each block is
/// called on the main queue.
///
/// The library makes the host's identifier out of the name, the same one for
/// the same name every time, and the service is advertised under that
/// identifier: two hosts of one name on one network are not told apart.
///
/// The device connects only once its user has picked the host, confirmed, and
/// typed the device's own passcode, in that order. Until then nothing arrives
/// here, however long the host has been listed.
/// - Parameters:
///   - withoutCode: Advertises a pairing that asks for no code. Whether a device
///     takes a host up on that is not known; the code is then all zeros.
///   - onEvent: Something happened, in a line of plain English: what a pairing
///     that does not go through has to be traced by, on a device with no
///     debugger attached.
///   - onPIN: The device has connected and asks its user for this code.
///   - onAttemptFailed: A try ended without a pairing; another is awaited.
///   - completion: The pairing file's contents, or why there will be none.
- (void)startWithName:(NSString *)name
          withoutCode:(BOOL)withoutCode
              onEvent:(void (^)(NSString *event))onEvent
                onPIN:(void (^)(NSString *pin))onPIN
      onAttemptFailed:(void (^)(NSString *reason))onAttemptFailed
           completion:(void (^)(NSData * _Nullable pairingFile, NSError * _Nullable error))completion;

/// Stops advertising and ends a try under way. No block is called afterwards.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
