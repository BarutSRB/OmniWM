// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL omniwm_assessment_available(void);

void *_Nullable omniwm_assessment_activate(
    NSArray<NSString *> *allowedBundleIdentifiers,
    NSArray<NSNumber *> *allowedSystemItems,
    void (^_Nullable onFailure)(void));

void omniwm_assessment_invalidate(void *_Nullable handle);

NS_ASSUME_NONNULL_END
