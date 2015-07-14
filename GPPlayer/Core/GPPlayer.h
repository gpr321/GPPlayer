//
//  GPPlayer.h
//  GPPlayer
//
//  Created by apple on 15/7/14.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import <UIKit/UIKit.h>
@class GPPlayer;

extern NSString *const GPCurrBufferedDuaration;

typedef NS_ENUM(NSInteger, GPPlayerState) {
    GPPlayerStateUnknow,
    GPPlayerStateInialFail,
    GPPlayerStateBuffering,
    GPPlayerStateBufferCompleted,
    GPPlayerStatePrepared,
    GPPlayerStateStreamEnd
};

@protocol GPPlayerDelegate <NSObject>

@optional
- (void)player:(GPPlayer *)player stateDidChanged:(GPPlayerState)sate withParams:(NSDictionary *)params;

@end

@interface GPPlayer : NSObject

@property (nonatomic,weak) id<GPPlayerDelegate> delegate;
@property (nonatomic, assign) GPPlayerState state;

@property (nonatomic, assign) CGFloat bufferedDuration;
@property (nonatomic, assign) CGFloat minBufferedDuration;
@property (nonatomic, assign) CGFloat maxBufferedDuration;

@property (nonatomic, strong, readonly) NSString *urlString;

- (instancetype)initWithURLString:(NSString *)urlString targetView:(UIView *)targetView;

- (void)prepare;

- (void)play;

@end
