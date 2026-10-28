//
//  LCDevicePairing.m
//  LiveContainerSwiftUI
//
//  Makes a pairing file on the device itself, without a computer.
//
//  A pairing file is what a host is left with once a device has agreed to be
//  paired with it. Up to iOS 26 the device only agrees over a cable. iOS 27 also
//  lists the hosts advertising themselves on its network, under Settings ›
//  Privacy & Security › Developer Mode, and pairs with the one its user picks
//  and types the host's code for. The host can be an app on that very device.
//
//  So this is a host: it advertises the service the device looks for, accepts
//  the device's connection, and lets idevice run the pairing over it. What comes
//  out is the RemotePairing record that built-in JIT connects with.
//
//  idevice is not linked. Only its pairing functions are needed, and those live
//  in IdevicePairing.dylib, which is loaded here the first time it is asked for
//  — see IdevicePairing/build.sh.
//

#import "LCDevicePairing.h"
#import <dlfcn.h>
#import <dns_sd.h>
#import <netinet/in.h>
#import <os/lock.h>
#import <poll.h>
#import <stdatomic.h>
#import <sys/socket.h>

NSErrorDomain const LCDevicePairingErrorDomain = @"LCDevicePairing";

#pragma mark idevice

// The part of idevice's C interface used here, as its header declares it
// (https://github.com/jkcoxson/idevice, MIT).
typedef struct {
    int32_t code;
    int32_t sub_code;
    const char *message;
} IdeviceFfiError;
typedef struct PairableHostHandle PairableHostHandle;
typedef struct RpPairingFileHandle RpPairingFileHandle;
typedef void (*PairableHostPinCb)(const char *pin, void *context);

static IdeviceFfiError *(*pairable_host_prepare)(const char *name, const char *model, bool allows_pinless_pairing,
                                                 PairableHostHandle **out_handle, char **out_service_id,
                                                 uint8_t **out_txt_data, uintptr_t *out_txt_len,
                                                 uint8_t *out_host_alt_irk);
static IdeviceFfiError *(*pairable_host_accept_fd)(PairableHostHandle *handle, int32_t fd, PairableHostPinCb pin_cb,
                                                   void *ctx, void **out_peer_device,
                                                   RpPairingFileHandle **out_pairing_file);
static void (*pairable_host_free)(PairableHostHandle *handle);
static IdeviceFfiError *(*rp_pairing_file_to_bytes)(RpPairingFileHandle *handle, uint8_t **out_data, uintptr_t *out_len);
static void (*rp_pairing_file_free)(RpPairingFileHandle *handle);
static void (*idevice_error_free)(IdeviceFfiError *err);
static void (*idevice_string_free)(char *string);
static void (*idevice_data_free)(uint8_t *data, uintptr_t len);

static NSString *LCPairingLibraryPath(void) {
    return [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"IdevicePairing.dylib"];
}

static BOOL LCLoadPairingLibrary(void) {
    static BOOL loaded;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *library = dlopen(LCPairingLibraryPath().fileSystemRepresentation, RTLD_LAZY);
        if(!library) {
            NSLog(@"[LC] IdevicePairing did not load: %s", dlerror());
            return;
        }
        pairable_host_prepare = dlsym(library, "pairable_host_prepare");
        pairable_host_accept_fd = dlsym(library, "pairable_host_accept_fd");
        pairable_host_free = dlsym(library, "pairable_host_free");
        rp_pairing_file_to_bytes = dlsym(library, "rp_pairing_file_to_bytes");
        rp_pairing_file_free = dlsym(library, "rp_pairing_file_free");
        idevice_error_free = dlsym(library, "idevice_error_free");
        idevice_string_free = dlsym(library, "idevice_string_free");
        idevice_data_free = dlsym(library, "idevice_data_free");
        loaded = pairable_host_prepare && pairable_host_accept_fd && pairable_host_free &&
            rp_pairing_file_to_bytes && rp_pairing_file_free &&
            idevice_error_free && idevice_string_free && idevice_data_free;
    });
    return loaded;
}

/// Takes an error from the library, leaving its text behind.
static NSError *LCConsumeLibraryError(IdeviceFfiError *error) {
    NSString *message = error->message ? @(error->message) : nil;
    NSError *result = [NSError errorWithDomain:LCDevicePairingErrorDomain
                                          code:LCDevicePairingErrorLibrary
                                      userInfo:@{NSLocalizedDescriptionKey: message ?: [NSString stringWithFormat:@"idevice error %d", error->code]}];
    idevice_error_free(error);
    return result;
}

static NSError *LCPairingError(LCDevicePairingError code, NSString *description) {
    return [NSError errorWithDomain:LCDevicePairingErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark -

@implementation LCDevicePairing {
    PairableHostHandle *_host;
    char *_serviceName;
    uint8_t *_txtPlist;
    uintptr_t _txtPlistLength;
    DNSServiceRef _advertisement;
    int _listener;

    /// The connection a try is running over, or -1. `cancel` ends the try
    /// through it, as the library offers no way of its own to stop one. Under
    /// the lock, so that what `cancel` shuts down is still that connection.
    int _connection;
    os_unfair_lock _connectionLock;
    atomic_bool _cancelled;
    /// Whether the try under way got as far as asking for the code, which is
    /// what its end is put down as.
    atomic_bool _askedForPIN;
    BOOL _finished;

    void (^_onEvent)(NSString *event);
    void (^_onPIN)(NSString *pin);
    void (^_onAttemptFailed)(NSString *reason);
    void (^_completion)(NSData *pairingFile, NSError *error);
}

// Asked for whenever the settings are drawn, so it only looks: the library is
// not loaded until a pairing starts.
+ (BOOL)isAvailable {
    return [NSFileManager.defaultManager fileExistsAtPath:LCPairingLibraryPath()];
}

- (instancetype)init {
    if((self = [super init])) {
        _listener = -1;
        _connection = -1;
        _connectionLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc {
    [self tearDown];
}

- (void)startWithName:(NSString *)name
          withoutCode:(BOOL)withoutCode
              onEvent:(void (^)(NSString *))onEvent
                onPIN:(void (^)(NSString *))onPIN
      onAttemptFailed:(void (^)(NSString *))onAttemptFailed
           completion:(void (^)(NSData *, NSError *))completion {
    _onEvent = [onEvent copy];
    _onPIN = [onPIN copy];
    _onAttemptFailed = [onAttemptFailed copy];
    _completion = [completion copy];

    if(!LCLoadPairingLibrary()) {
        [self finishWithFile:nil error:LCPairingError(LCDevicePairingErrorUnavailable, @"IdevicePairing.dylib could not be loaded.")];
        return;
    }

    // A host identity, and with it the name and the records the device expects
    // the service to be advertised under. No model: the library's default is a
    // Mac's, which is what iOS takes a host to be.
    IdeviceFfiError *error = pairable_host_prepare(name.UTF8String, NULL, withoutCode, &_host, &_serviceName, &_txtPlist, &_txtPlistLength, NULL);
    if(error) {
        [self finishWithFile:nil error:LCConsumeLibraryError(error)];
        return;
    }

    uint16_t port = 0;
    if(![self listenOnPort:&port]) {
        [self finishWithFile:nil error:LCPairingError(LCDevicePairingErrorNetwork, @"Could not open a port for the device to connect to.")];
        return;
    }
    DNSServiceErrorType advertised = [self advertiseOnPort:port];
    if(advertised != kDNSServiceErr_NoError) {
        [self finishWithFile:nil error:[self errorForAdvertising:advertised]];
        return;
    }
    [self note:[NSString stringWithFormat:@"Advertising on port %d", port]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self acceptConnections];
    });
}

- (void)cancel {
    atomic_store(&_cancelled, true);
    // Ends a try that is waiting for the code to be typed: the library reads
    // from a duplicate of this socket, and shutting the socket down reaches both.
    os_unfair_lock_lock(&_connectionLock);
    if(_connection >= 0) {
        shutdown(_connection, SHUT_RDWR);
    }
    os_unfair_lock_unlock(&_connectionLock);
    _finished = YES;
    [self stopAdvertising];
    [self forgetBlocks];
}

/// From any thread. Dropped once the pairing is over.
- (void)note:(NSString *)event {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!self->_finished && self->_onEvent) {
            self->_onEvent(event);
        }
    });
}

/// The blocks hold on to whoever started the pairing, who holds this object.
- (void)forgetBlocks {
    _onEvent = nil;
    _onPIN = nil;
    _onAttemptFailed = nil;
    _completion = nil;
}

#pragma mark Listening and advertising

/// Both address families on one socket: the device connects to whichever of
/// this device's own addresses the service resolves to.
- (BOOL)listenOnPort:(uint16_t *)port {
    _listener = socket(AF_INET6, SOCK_STREAM, 0);
    if(_listener < 0) {
        return NO;
    }
    int off = 0, on = 1;
    setsockopt(_listener, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof(off));
    setsockopt(_listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in6 address = { .sin6_len = sizeof(address), .sin6_family = AF_INET6, .sin6_addr = in6addr_any };
    socklen_t length = sizeof(address);
    if(bind(_listener, (struct sockaddr *)&address, length) != 0 || listen(_listener, 4) != 0 ||
       getsockname(_listener, (struct sockaddr *)&address, &length) != 0) {
        return NO;
    }
    *port = ntohs(address.sin6_port);
    return YES;
}

static void LCAdvertisementReply(DNSServiceRef service, DNSServiceFlags flags, DNSServiceErrorType errorCode,
                                 const char *name, const char *type, const char *domain, void *context) {
    if(errorCode == kDNSServiceErr_NoError) {
        return;
    }
    // Refused after the fact, which is how a denied Local Network permission
    // arrives: the registration itself is accepted first.
    LCDevicePairing *pairing = (__bridge LCDevicePairing *)context;
    [pairing finishWithFile:nil error:[pairing errorForAdvertising:errorCode]];
}

- (DNSServiceErrorType)advertiseOnPort:(uint16_t)port {
    // The library hands the records over as a property list of names to values.
    NSData *plist = [NSData dataWithBytesNoCopy:_txtPlist length:_txtPlistLength freeWhenDone:NO];
    NSDictionary *records = [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL];
    if(![records isKindOfClass:NSDictionary.class]) {
        return kDNSServiceErr_BadParam;
    }
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    for(NSString *key in records) {
        id value = records[key];
        NSData *bytes = [value isKindOfClass:NSData.class] ? value : [[value description] dataUsingEncoding:NSUTF8StringEncoding];
        TXTRecordSetValue(&txt, key.UTF8String, (uint8_t)MIN(bytes.length, UINT8_MAX), bytes.bytes);
    }

    DNSServiceErrorType result = DNSServiceRegister(&_advertisement, 0, kDNSServiceInterfaceIndexAny, _serviceName,
                                                    "_remotepairing-pairable-host._tcp", NULL, NULL, htons(port),
                                                    TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
                                                    LCAdvertisementReply, (__bridge void *)self);
    TXTRecordDeallocate(&txt);
    if(result == kDNSServiceErr_NoError) {
        // Replies on the main queue, where the blocks are called and where the
        // advertisement is taken down, so that none arrives after that.
        result = DNSServiceSetDispatchQueue(_advertisement, dispatch_get_main_queue());
    }
    return result;
}

- (NSError *)errorForAdvertising:(DNSServiceErrorType)code {
    if(code == kDNSServiceErr_PolicyDenied) {
        return LCPairingError(LCDevicePairingErrorLocalNetworkDenied, @"Local Network access is turned off for this app.");
    }
    return LCPairingError(LCDevicePairingErrorNetwork, [NSString stringWithFormat:@"Could not advertise on the network (%d).", (int)code]);
}

- (void)stopAdvertising {
    if(_advertisement) {
        DNSServiceRefDeallocate(_advertisement);
        _advertisement = NULL;
    }
}

#pragma mark Pairing

static void LCPairingAsksForPIN(const char *pin, void *context) {
    LCDevicePairing *pairing = (__bridge LCDevicePairing *)context;
    atomic_store(&pairing->_askedForPIN, true);
    NSString *code = pin ? @(pin) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!pairing->_finished && pairing->_onPIN) {
            pairing->_onPIN(code);
        }
    });
}

/// Runs off the main thread until the device is paired or the pairing is
/// cancelled. A try that fails, a mistyped code say, leaves the device free to
/// start another, so the wait goes on.
- (void)acceptConnections {
    while(!atomic_load(&_cancelled)) {
        struct pollfd incoming = { .fd = _listener, .events = POLLIN };
        int ready = poll(&incoming, 1, 500);
        if(ready == 0 || (ready < 0 && errno == EINTR)) {
            continue;
        }
        int connection = -1;
        if(ready > 0 && !(incoming.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            connection = accept(_listener, NULL, NULL);
            if(connection < 0 && (errno == EINTR || errno == EAGAIN || errno == ECONNABORTED)) {
                continue;
            }
        }
        if(connection < 0) {
            // The socket itself is gone, which the system does to one whose
            // app it has kept suspended for a while. Nothing can reach it
            // again, and waiting on it would spin, so the pairing ends here
            // and is started afresh.
            int code = errno;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self note:[NSString stringWithFormat:@"Listening socket lost (%d)", code]];
                [self finishWithFile:nil error:LCPairingError(LCDevicePairingErrorNetwork, @"The connection for pairing was lost. Try again.")];
            });
            return;
        }
        [self note:@"Device connected"];
        // The device may hang up at any point, and a write to a socket it has
        // closed would otherwise end the app with SIGPIPE.
        int on = 1;
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));

        atomic_store(&_askedForPIN, false);
        os_unfair_lock_lock(&_connectionLock);
        _connection = connection;
        os_unfair_lock_unlock(&_connectionLock);
        RpPairingFileHandle *file = NULL;
        IdeviceFfiError *error = NULL;
        // Not once cancelled: that may have been before the connection was
        // there to be shut down, and nothing would then end the try.
        if(!atomic_load(&_cancelled)) {
            error = pairable_host_accept_fd(_host, connection, LCPairingAsksForPIN, (__bridge void *)self, NULL, &file);
        }
        os_unfair_lock_lock(&_connectionLock);
        _connection = -1;
        close(connection);
        os_unfair_lock_unlock(&_connectionLock);

        NSError *failure = error ? LCConsumeLibraryError(error) : nil;
        NSData *pairingFile = nil;
        if(file) {
            uint8_t *bytes = NULL;
            uintptr_t length = 0;
            error = rp_pairing_file_to_bytes(file, &bytes, &length);
            if(error) {
                failure = LCConsumeLibraryError(error);
            } else {
                pairingFile = [NSData dataWithBytes:bytes length:length];
                idevice_data_free(bytes, length);
            }
            rp_pairing_file_free(file);
        }
        if(atomic_load(&_cancelled)) {
            break;
        }
        if(pairingFile) {
            [self note:@"Paired"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishWithFile:pairingFile error:nil];
            });
            return;
        }
        [self note:[NSString stringWithFormat:@"%@: %@",
                    atomic_load(&_askedForPIN) ? @"Try failed" : @"Connection ended before the code",
                    failure.localizedDescription ?: @"no reason given"]];
        // Told of either way. A try that ended before the code leaves nothing
        // on this side to show for it, and the user in Settings none the wiser.
        NSString *reason = failure.localizedDescription ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            if(!self->_finished && self->_onAttemptFailed) {
                self->_onAttemptFailed(reason);
            }
        });
    }
}

/// On the main queue. Only the first outcome counts.
- (void)finishWithFile:(NSData *)pairingFile error:(NSError *)error {
    if(_finished) {
        return;
    }
    _finished = YES;
    atomic_store(&_cancelled, true);
    [self stopAdvertising];
    void (^completion)(NSData *, NSError *) = _completion;
    [self forgetBlocks];
    if(completion) {
        completion(pairingFile, error);
    }
}

/// Everything the library and the system were asked for. Left to the end of
/// the object's life: the thread accepting connections holds the object until
/// it is done with all of it.
- (void)tearDown {
    [self stopAdvertising];
    if(_listener >= 0) {
        close(_listener);
        _listener = -1;
    }
    if(_host) {
        pairable_host_free(_host);
        _host = NULL;
    }
    if(_serviceName) {
        idevice_string_free(_serviceName);
        _serviceName = NULL;
    }
    if(_txtPlist) {
        idevice_data_free(_txtPlist, _txtPlistLength);
        _txtPlist = NULL;
    }
}

@end
