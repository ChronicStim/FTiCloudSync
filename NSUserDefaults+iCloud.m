//
//  NSUserDefaults+iCloud.m
//  FTiCloudSync
//
//  Copyright (c) 2012:
//  Ortwin Gentz, FutureTap GmbH, http://www.futuretap.com
//  All rights reserved.
// 
//  Licensed under CC-BY-SA 3.0: http://creativecommons.org/licenses/by-sa/3.0/
//  You are free to share, adapt and make commercial use of the work as long as you give attribution and keep this license.
//  To give credit, we suggest this text: "Uses FTiCloudSync by Ortwin Gentz", with a link to the GitHub page

#import "NSUserDefaults+iCloud.h"
#import "RegexKitLite.h"
#import "JRSwizzle.h"

NSString* const FTiCloudSyncDidUpdateNotification = @"FTiCloudSyncDidUpdateNotification";
NSString* const FTiCloudSyncChangedKeys = @"changedKeys";
NSString* const FTiCloudSyncRemovedKeys = @"removedKeys";
NSString* const iCloudBlacklistRegex = @"(^!|^Apple|^ATOutputLevel|Hockey|DateOfVersionInstallation|^MF|^NS|Quincy|^BIT|^TV|UsageTime|^Web|preferredLocaleIdentifier|^crittercism|^current_device|^kAppirater|^kStatKey|^dropbox|^kDropboxDBSync|^CPTSyncActionController)";
NSString* const iCloudGreenlistRegex = @"(^!Cloud)";

@implementation NSUserDefaults(Additions)

#pragma mark - Swizzling to get a hook for iCloud
+(void)load {
	if(NSClassFromString(@"NSUbiquitousKeyValueStore")) { // is iOS 5?
        CPT_LOGDebug(@"[NSUserDefaults] Start +load swizzle methods");
        {
            NSError *error = nil;
            [NSUserDefaults jr_swizzleMethod:@selector(setObject:forKey:)
                                  withMethod:@selector(my_setObject:forKey:)
                                            error:&error];
            if (nil != error) {
                CPT_LOGError(@"Swizzle error. Code %i; %@; %@",error.code,error.localizedDescription,error.userInfo);
            }
        }
        {
            NSError *error = nil;
            [NSUserDefaults jr_swizzleMethod:@selector(removeObjectForKey:)
                                  withMethod:@selector(my_removeObjectForKey:)
                                            error:&error];
            if (nil != error) {
                CPT_LOGError(@"Swizzle error. Code %i; %@; %@",error.code,error.localizedDescription,error.userInfo);
            }
        }
        {
            NSError *error = nil;
            [NSUserDefaults jr_swizzleMethod:@selector(synchronize)
                                  withMethod:@selector(my_synchronize)
                                            error:&error];
            if (nil != error) {
                CPT_LOGError(@"Swizzle error. Code %i; %@; %@",error.code,error.localizedDescription,error.userInfo);
            }
        }

		[[NSNotificationCenter defaultCenter] addObserver:self 
												 selector:@selector(updateFromiCloud:) 
													 name:NSUbiquitousKeyValueStoreDidChangeExternallyNotification 
												   object:nil];
	}
}

+ (void)updateFromiCloud:(NSNotification*)notificationObject {
    CPT_LOGDebug(@"Start +updateFromiCloud: with notificationObject: (%@) %@",[notificationObject class],[notificationObject debugDescription]);
    
    NSNumber *reason = [[notificationObject userInfo] objectForKey:NSUbiquitousKeyValueStoreChangeReasonKey];
    CPT_LOGDebug(@"NSUbiquitousKeyValueStore change reason key = %ld",(long)[reason integerValue]);
	if ([reason intValue] == NSUbiquitousKeyValueStoreQuotaViolationChange) {
		CPT_LOGError(@"NSUbiquitousKeyValueStoreQuotaViolationChange");
	}
	NSMutableArray *changedKeys = [NSMutableArray array];
	NSMutableArray *removedKeys = nil;
	@synchronized(self) {
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		NSDictionary *dict = [[NSUbiquitousKeyValueStore defaultStore] dictionaryRepresentation];

		[dict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
			if ([key isMatchedByRegex:iCloudGreenlistRegex] && ![[defaults valueForKey:key] isEqual:obj]) {
				[defaults my_setObject:obj forKey:key]; // call original implementation
				[changedKeys addObject:key];
			}
		}];
		
		removedKeys = [NSMutableArray arrayWithArray:[defaults dictionaryRepresentation].allKeys];
		[removedKeys removeObjectsInArray:dict.allKeys];
		[removedKeys enumerateObjectsUsingBlock:^(id key, NSUInteger idx, BOOL *stop) {
			if ([key isMatchedByRegex:iCloudGreenlistRegex]) {
				[defaults my_removeObjectForKey:key]; // non-swizzled/original implementation
			}
		}];
		
		[defaults my_synchronize];  // call original implementation (don't sync with iCloud again)
        CPT_LOGDebug(@"updateFromiCloud: has changedKeys:%@ and removedKeys:%@",changedKeys,removedKeys);
	}
    [[NSNotificationCenter defaultCenter] postNotificationName:FTiCloudSyncDidUpdateNotification
														object:self
													  userInfo:[NSDictionary dictionaryWithObjectsAndKeys:changedKeys, FTiCloudSyncChangedKeys, removedKeys, FTiCloudSyncRemovedKeys, nil]];
}

- (void)my_setObject:(id)object forKey:(NSString *)key {
    
    //CPT_LOGDebug(@"[NSUserDefaults] Start my_setObject: %@ forKey %@", [object description], key);

    if (nil == key) {
        CPT_LOGError(@"[NSUserDefaults] Error: Key for my_setObject:forKey: was nil for object: (%@)%@", NSStringFromClass([object class]),[object debugDescription]);
        return;
    }

	BOOL equal = [[self objectForKey:key] isEqual:object];
	[self my_setObject:object forKey:key]; // call original implementation
	if (!equal && [key isMatchedByRegex:iCloudGreenlistRegex] && [NSUbiquitousKeyValueStore defaultStore]) {
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
			[[NSUbiquitousKeyValueStore defaultStore] setObject:object forKey:key];
            CPT_LOGDebug(@"Just told NSUbiquitousKeyValueStore to setObject: %@ forKey: %@",object,key);
		});
	}
}

- (void)my_removeObjectForKey:(NSString *)key {
    
    CPT_LOGDebug(@"[NSUserDefaults] Start my_removeObjectForKey: %@", key);
    
    if (nil == key) {
        CPT_LOGError(@"[NSUserDefaults] Error: Key for my_removeObjectForKey: was nil.");
        return;
    }
    
	BOOL exists = !![self objectForKey:key];
	[self my_removeObjectForKey:key]; // call original implementation
	
	if (exists && [key isMatchedByRegex:iCloudGreenlistRegex] && [NSUbiquitousKeyValueStore defaultStore]) {
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
			[[NSUbiquitousKeyValueStore defaultStore] removeObjectForKey:key];
            CPT_LOGDebug(@"Just told NSUbiquitousKeyValueStore to removeObjectForKey: %@",key);
		});
	}
}

- (void)my_synchronize {
    //CPT_LOGDebug(@"[NSUserDefaults] Start my_synchronize");
	[self my_synchronize]; // call original implementation
	if ([NSUbiquitousKeyValueStore defaultStore]) {
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
			if(![[NSUbiquitousKeyValueStore defaultStore] synchronize]) {
				CPT_LOGError(@"iCloud sync failed");
			}
		});
	}
}

@end
