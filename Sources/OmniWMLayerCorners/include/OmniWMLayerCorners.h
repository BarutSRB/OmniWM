// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct CACornerRadii {
    CGSize topLeft;
    CGSize topRight;
    CGSize bottomRight;
    CGSize bottomLeft;
} CACornerRadii;

@interface CALayer (OmniWMLayerCorners)
@property(nonatomic) CACornerRadii cornerRadii NS_SWIFT_MAIN_ACTOR;
@property(nullable, nonatomic) CGColorRef rimColor NS_SWIFT_MAIN_ACTOR;
@property(nonatomic) double rimWidth NS_SWIFT_MAIN_ACTOR;
@property(nonatomic) float rimOpacity NS_SWIFT_MAIN_ACTOR;
@end

BOOL omniwm_layer_border_available(void);

NS_ASSUME_NONNULL_END
