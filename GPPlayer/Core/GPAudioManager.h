//
//  GPAudioManager.h
//  GPPlayer
//
//  Created by mac on 15/6/27.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void (^GPAudioManagerOutputBlock)(float *data, UInt32 numFrames, UInt32 numChannels);

@protocol GPAudioManager <NSObject>

@property (readonly, nonatomic) UInt32              numOutputChannels;
@property (readonly, nonatomic) Float64             samplingRate;
@property (readonly, nonatomic) UInt32              numBytesPerSample;
@property (readonly, nonatomic) Float32             outputVolume;
@property (readonly, nonatomic) BOOL                playing;
@property (readonly, strong) NSString               *audioRoute;

@property (readwrite, copy) GPAudioManagerOutputBlock outputBlock;

- (BOOL) activateAudioSession;
- (void) deactivateAudioSession;
- (BOOL) play;
- (void) pause;

@end

@interface GPAudioManager : NSObject

+ (id<GPAudioManager>) audioManager;

@end
