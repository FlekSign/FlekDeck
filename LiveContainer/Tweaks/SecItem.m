//
//  SecItem.m
//  LiveContainer
//
//  Created by s s on 2024/11/29.
//
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <os/log.h>
#import "utils.h"
#import <CommonCrypto/CommonDigest.h>
#import "../../litehook/src/litehook.h"
#import "LCSharedUtils.h"

extern void* (*msHookFunction)(void *symbol, void *hook, void **old);
OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = SecItemAdd;
OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = SecItemCopyMatching;
OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) = SecItemUpdate;
OSStatus (*orig_SecItemDelete)(CFDictionaryRef query) = SecItemDelete;
SecKeyRef (*orig_SecKeyCreateRandomKey)(CFDictionaryRef parameters, CFErrorRef *error) = SecKeyCreateRandomKey;
SecKeyRef (*orig_SecKeyCreateWithData)(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) = SecKeyCreateWithData;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus (*orig_SecKeyGeneratePair)(CFDictionaryRef query, SecKeyRef *publicKey, SecKeyRef *privateKey) = SecKeyGeneratePair;
#pragma clang diagnostic pop
NSString* accessGroup = nil;
NSString* containerId = nil;

// Enough to tell one item from another when a guest treats a failed keychain
// write as fatal. os_log rather than NSLog because these have to come out of the
// unified log readable: NSLog redacts every string it is handed, and the marker
// that would prevent it is only honoured here. Names of items, never their data.
static void logKeychainFailure(const char* operation, OSStatus status, NSDictionary* item) {
    id itemClass = item[(__bridge id)kSecClass];
    id account = item[(__bridge id)kSecAttrAccount];
    id service = item[(__bridge id)kSecAttrService];
    os_log_error(OS_LOG_DEFAULT,
          "[LC] keychain %{public}s failed with %{public}d (group %{public}s, class %{public}s, account %{public}s, service %{public}s)",
          operation, (int)status,
          accessGroup.UTF8String ?: "none",
          [itemClass isKindOfClass:NSString.class] ? [itemClass UTF8String] : "?",
          [account isKindOfClass:NSString.class] ? [account UTF8String] : "?",
          [service isKindOfClass:NSString.class] ? [service UTF8String] : "?");
}

OSStatus new_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSMutableDictionary *attributesCopy = ((__bridge NSDictionary *)attributes).mutableCopy;
    attributesCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    // for keychain deletion in LCUI
    attributesCopy[@"alis"] = containerId;

    OSStatus status = orig_SecItemAdd((__bridge CFDictionaryRef)attributesCopy, result);
    if(status == errSecParam) {
        // Something we added is not welcome on this item. Give up the tag first,
        // then the access group, keeping ours as long as possible — putting the
        // guest's own group back is the last resort, because this process is
        // usually not entitled to it and it fails for that reason alone.
        [attributesCopy removeObjectForKey:@"alis"];
        status = orig_SecItemAdd((__bridge CFDictionaryRef)attributesCopy, result);
    }
    if(status == errSecParam) {
        [attributesCopy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        status = orig_SecItemAdd((__bridge CFDictionaryRef)attributesCopy, result);
    }
    if(status == errSecParam) {
        status = orig_SecItemAdd(attributes, result);
    }
    if(status != errSecSuccess) {
        logKeychainFailure("add", status, attributesCopy);
    }

    return status;
}

OSStatus new_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    OSStatus status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)queryCopy, result);
    if(status == errSecParam) {
        // if this search don't support kSecAttrAccessGroup, we just use the original search
        [queryCopy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)queryCopy, result);
    }
    // Not finding an item is an ordinary answer, not a failure worth reporting.
    if(status != errSecSuccess && status != errSecItemNotFound) {
        logKeychainFailure("lookup", status, queryCopy);
    }

    return status;
}

OSStatus new_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    
    NSMutableDictionary *attrCopy = ((__bridge NSDictionary *)attributesToUpdate).mutableCopy;
    attrCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;

    OSStatus status = orig_SecItemUpdate((__bridge CFDictionaryRef)queryCopy, (__bridge CFDictionaryRef)attrCopy);

    if(status == errSecParam) {
        [queryCopy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        [attrCopy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        status = orig_SecItemUpdate((__bridge CFDictionaryRef)queryCopy, (__bridge CFDictionaryRef)attrCopy);
    }
    if(status != errSecSuccess && status != errSecItemNotFound) {
        logKeychainFailure("update", status, queryCopy);
    }

    return status;
}

// Generic and internet passwords: what a login is kept in, and always added
// through new_SecItemAdd, so always tagged with the container they belong to.
// Keys are not: the ones made through SecKeyCreateRandomKey and its kin never
// get the tag.
static BOOL isPasswordClass(id itemClass) {
    return [itemClass isEqual:(__bridge id)kSecClassGenericPassword] ||
           [itemClass isEqual:(__bridge id)kSecClassInternetPassword];
}

OSStatus new_SecItemDelete(CFDictionaryRef query){
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    // Only this container's own passwords. accessGroup can be shared by every
    // container of every app, and many apps clear the keychain out whenever they
    // believe they have just been installed — in a new container, or one whose
    // preferences were lost — which signed every other app out along with them.
    // Keys stay unscoped, since a tag they do not carry would put them out of
    // reach of their own app.
    if(isPasswordClass(queryCopy[(__bridge id)kSecClass])) {
        queryCopy[@"alis"] = containerId;
    }
    OSStatus status = orig_SecItemDelete((__bridge CFDictionaryRef)queryCopy);
    if(status == errSecParam && queryCopy[@"alis"]) {
        [queryCopy removeObjectForKey:@"alis"];
        status = orig_SecItemDelete((__bridge CFDictionaryRef)queryCopy);
    }
    if(status == errSecParam) {
        [queryCopy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        status = orig_SecItemDelete((__bridge CFDictionaryRef)queryCopy);
    }
    if(status != errSecSuccess && status != errSecItemNotFound) {
        logKeychainFailure("delete", status, queryCopy);
    }

    return status;
}

SecKeyRef new_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    NSMutableDictionary *paramsCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    SecKeyRef key = orig_SecKeyCreateRandomKey((__bridge CFDictionaryRef)paramsCopy, error);
    if(!key && error && *error) {
        CFRelease(*error);
        *error = NULL;
        key = orig_SecKeyCreateRandomKey(parameters, error);
    }
    
    return key;
}

SecKeyRef new_SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) {
    NSMutableDictionary *paramsCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    SecKeyRef key = orig_SecKeyCreateWithData(keyData, (__bridge CFDictionaryRef)paramsCopy, error);
    if(!key && error && *error) {
        CFRelease(*error);
        *error = NULL;
        key = orig_SecKeyCreateWithData(keyData, parameters, error);
    }
    
    return key;
}

OSStatus new_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    OSStatus status = orig_SecKeyGeneratePair((__bridge CFDictionaryRef)queryCopy, publicKey, privateKey);
    if(status == errSecParam) {
        return orig_SecKeyGeneratePair(parameters, publicKey, privateKey);
    }
    
    return status;
}

// Declared in FoundationPrivate.h, repeated here to keep this file's includes short.
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef key, CFErrorRef *error);

// A read proves nothing. A search happily answers "no such item" for a group this
// process could never write to, so checking with SecItemCopyMatching picks groups
// that every later add rejects with errSecMissingEntitlement — com.apple.token is
// entitled to us and behaves exactly like that. Write something instead, and take
// it back out.
static BOOL accessGroupIsUsable(NSString* group) {
    if(group.length == 0) return NO;

    NSDictionary *probe = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"com.kdt.livecontainer.accessGroupProbe",
        (__bridge id)kSecAttrService: @"com.kdt.livecontainer.accessGroupProbe",
        (__bridge id)kSecAttrAccessGroup: group
    };
    NSMutableDictionary *toAdd = probe.mutableCopy;
    toAdd[(__bridge id)kSecValueData] = [@"probe" dataUsingEncoding:NSUTF8StringEncoding];

    OSStatus status = orig_SecItemAdd((__bridge CFDictionaryRef)toAdd, NULL);
    // Already present means a previous launch got one in, which is the answer too.
    if(status == errSecSuccess || status == errSecDuplicateItem) {
        orig_SecItemDelete((__bridge CFDictionaryRef)probe);
        return YES;
    }
    // Only a missing entitlement rules a group out. Any other refusal — a locked
    // device being the likely one — says nothing about whether we are allowed to
    // write here, and treating it as a refusal would send this container's items
    // to some other group, losing sight of everything already stored in this one.
    return status != errSecMissingEntitlement;
}

// What the signature actually grants, which is not always what the project asked
// for: a re-signing service will replace the entitlements with a generic set and
// drop the com.kdt.livecontainer.shared groups on the way.
static NSArray<NSString*>* entitledAccessGroups(void) {
    NSMutableArray<NSString*>* groups = [NSMutableArray new];
    void* taskSelf = SecTaskCreateFromSelf(NULL);
    if(!taskSelf) return groups;

    // The application identifier is an access group in its own right, it always
    // belongs to us, and it is the one most likely to survive re-signing intact,
    // so try it ahead of whatever else is declared.
    CFTypeRef appIdentifier = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("application-identifier"), NULL);
    if(appIdentifier) {
        if(CFGetTypeID(appIdentifier) == CFStringGetTypeID()) {
            [groups addObject:(__bridge NSString*)appIdentifier];
        }
        CFRelease(appIdentifier);
    }

    CFTypeRef declared = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("keychain-access-groups"), NULL);
    if(declared) {
        if(CFGetTypeID(declared) == CFArrayGetTypeID()) {
            for(id group in (__bridge NSArray*)declared) {
                if(![group isKindOfClass:NSString.class]) continue;
                // A '*' here is not a wildcard to securityd, it is part of a group
                // name that nothing can be added to, so it is no use to us.
                if([group containsString:@"*"]) continue;
                // Apple's smart card group. Entitled to everyone, ours to nobody.
                if([group isEqualToString:@"com.apple.token"]) continue;
                [groups addObject:group];
            }
        }
        CFRelease(declared);
    }

    CFRelease(taskSelf);
    return groups;
}

void SecItemGuestHooksInit(void)  {

    containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    int keychainGroupId = [infoDict[@"keychainGroupId"] intValue];
    NSString* groupId = [LCSharedUtils teamIdentifier];
    NSString* ownPrefix = [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared", groupId];

    // Best first: the group this container was given, then the one every container
    // shares, then whatever the signature turns out to grant.
    NSMutableArray<NSString*>* candidates = [NSMutableArray new];
    if(keychainGroupId != 0) {
        [candidates addObject:[NSString stringWithFormat:@"%@.%d", ownPrefix, keychainGroupId]];
    }
    [candidates addObject:ownPrefix];
    [candidates addObjectsFromArray:entitledAccessGroups()];

    accessGroup = nil;
    for(NSString* candidate in candidates) {
        if(accessGroupIsUsable(candidate)) {
            accessGroup = candidate;
            break;
        }
    }

    // Leaving the hooks off means the guest reaches the keychain under its own
    // access group, which this process is not entitled to, so every write fails.
    // An app that treats the keychain as something that cannot fail then dies on
    // the spot — Infinity Blade 3 asserts "Couldn't add the Keychain Item." and
    // aborts. Borrowing a group we do hold costs the separation between
    // containers, which the shared group gives up anyway, and keeps them running.
    if(!accessGroup) {
        os_log_error(OS_LOG_DEFAULT, "[LC] no keychain access group accepts writes, leaving the guest's keychain calls alone");
        return;
    }
    if(![accessGroup hasPrefix:ownPrefix]) {
        os_log_error(OS_LOG_DEFAULT,
              "[LC] keychain group %{public}s is unavailable, containers will share %{public}s instead",
              ownPrefix.UTF8String, accessGroup.UTF8String);
    }

    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, new_SecItemAdd, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, new_SecItemCopyMatching, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, new_SecItemUpdate, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, new_SecItemDelete, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateRandomKey, new_SecKeyCreateRandomKey, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateWithData, new_SecKeyCreateWithData, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyGeneratePair, new_SecKeyGeneratePair, nil);
}
