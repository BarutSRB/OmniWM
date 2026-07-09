// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

#import "OmniWMMenuBarAssertion.h"
#import <dlfcn.h>

@interface MBAssessmentModeConfiguration : NSObject
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)systemItems
                  allowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers;
@end

@interface MBAssessmentModeAssertion : NSObject
- (void)activateWithConfiguration:(id)configuration
                completionHandler:(void (^)(NSError *_Nullable error))completionHandler;
- (void)invalidate;
@end

static const char *kMenuBarClientCorePath =
    "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";

static BOOL OmniWMEnsureMenuBarClientCoreLoaded(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded = NO;
    dispatch_once(&onceToken, ^{
        loaded = (dlopen(kMenuBarClientCorePath, RTLD_NOW) != NULL);
        if (!loaded) {
            NSLog(@"[OmniWMMenuBarAssertion] dlopen MenuBarClientCore failed: %s", dlerror());
        }
    });
    return loaded;
}

BOOL omniwm_assessment_available(void) {
    if (!OmniWMEnsureMenuBarClientCoreLoaded()) {
        return NO;
    }
    return NSClassFromString(@"MBAssessmentModeConfiguration") != nil &&
           NSClassFromString(@"MBAssessmentModeAssertion") != nil;
}

void *_Nullable omniwm_assessment_activate(NSArray<NSString *> *allowedBundleIdentifiers,
                                           NSArray<NSNumber *> *allowedSystemItems,
                                           void (^_Nullable onFailure)(void)) {
    if (!OmniWMEnsureMenuBarClientCoreLoaded()) {
        return NULL;
    }

    Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    if (!configurationClass || !assertionClass) {
        return NULL;
    }

    @try {
        MBAssessmentModeConfiguration *configuration =
            [[configurationClass alloc] initWithAllowedSystemItems:(allowedSystemItems ?: @[])
                                          allowedBundleIdentifiers:(allowedBundleIdentifiers ?: @[])];
        if (!configuration) {
            return NULL;
        }

        MBAssessmentModeAssertion *assertion = [[assertionClass alloc] init];
        if (!assertion) {
            return NULL;
        }

        void (^failureCopy)(void) = onFailure ? [onFailure copy] : nil;
        [assertion activateWithConfiguration:configuration
                           completionHandler:^(NSError *_Nullable error) {
            if (error) {
                NSLog(@"[OmniWMMenuBarAssertion] activation reported error: %@", error);
                if (failureCopy) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        failureCopy();
                    });
                }
            }
        }];

        return (void *)CFBridgingRetain(assertion);
    } @catch (NSException *exception) {
        NSLog(@"[OmniWMMenuBarAssertion] activation threw: %@", exception);
        return NULL;
    }
}

void omniwm_assessment_invalidate(void *_Nullable handle) {
    if (handle == NULL) {
        return;
    }
    MBAssessmentModeAssertion *assertion = (MBAssessmentModeAssertion *)CFBridgingRelease(handle);
    @try {
        [assertion invalidate];
    } @catch (NSException *exception) {
        NSLog(@"[OmniWMMenuBarAssertion] invalidate threw: %@", exception);
    }
}
