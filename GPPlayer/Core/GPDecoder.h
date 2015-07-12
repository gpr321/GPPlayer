//
//  GPDecoder.h
//  GPPlayer
//
//  Created by mac on 15/6/21.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import <UIKit/UIKit.h>

//typedef enum {
//    
//    kxMovieErrorNone,
//    kxMovieErrorOpenFile,
//    kxMovieErrorStreamInfoNotFound,
//    kxMovieErrorStreamNotFound,
//    kxMovieErrorCodecNotFound,
//    kxMovieErrorOpenCodec,
//    kxMovieErrorAllocateFrame,
//    kxMovieErroSetupScaler,
//    kxMovieErroReSampler,
//    kxMovieErroUnsupported,
//    
//} kxMovieError;

typedef NS_ENUM(NSInteger, GPDecoderErrorCode) {
    GPDecoderErrorNone,
    GPDecoderErrorOpenFile,
    GPDecoderErrorStreamInfoNotFound,
    GPDecoderErrorStreamNotFound,
    GPDecoderErrorCodecNotFound,
    GPDecoderErrorOpenDecodec,
    GPDecoderErrorAllocateFrame,
    GPDecoderErrorReSampler
};

@interface GPDecoder : NSObject

@property (readonly, nonatomic) NSUInteger frameWidth;
@property (readonly, nonatomic) NSUInteger frameHeight;
@property (readonly, nonatomic) CGFloat fps;

- (BOOL)openURLString:(NSString *)urlString error:(NSError **)error;

@end
