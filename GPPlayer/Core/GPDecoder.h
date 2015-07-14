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
    GPDecoderErrorReSampler,
    GPDecoderErrorUnsupport
};

typedef NS_ENUM(int, GPFrameType) {
    GPFrameTypeAudio,
    GPFrameTypeVideo,
    GPFrameTypeArtwork,
    GPFrameTypeSubtitle
};

typedef NS_ENUM(int, GPVideoFrameFormat) {
    GPVideoFrameFormatRGB,
    GPVideoFrameFormatYUV
};

@interface GPFrame : NSObject
@property (nonatomic, assign, readonly) GPFrameType type;
@property (nonatomic, assign, readonly) CGFloat position;
@property (nonatomic, assign, readonly) CGFloat duration;
@end

@interface GPAudioFrame : GPFrame
@property (nonatomic,strong, readonly) NSData *samples;
@end

@interface GPVideoFrame : GPFrame
@property (nonatomic, assign, readonly) GPVideoFrameFormat format;
@property (nonatomic, assign, readonly) CGFloat height;
@property (nonatomic, assign, readonly) CGFloat width;
@end

@interface GPVideoFrameRGB : GPVideoFrame
@property (nonatomic, assign) NSUInteger linesize;
@property (nonatomic, strong) NSData *rgb;
- (UIImage *) asImage;
@end

@interface GPVideoFrameYUV : GPVideoFrame
@property (nonatomic, strong, readonly) NSData *luma;
@property (nonatomic, strong, readonly) NSData *chromaB;
@property (nonatomic, strong, readonly) NSData *chromaR;
@end

@interface GPArtworkFrame : GPFrame
@property (readonly, nonatomic, strong) NSData *picture;
- (UIImage *) asImage;
@end

@interface GPSubtitleFrame : GPFrame
@property (readonly, nonatomic, strong) NSString *text;
@end

@interface GPSubtitleASSParser : NSObject

+ (NSArray *) parseEvents: (NSString *) events;
+ (NSArray *) parseDialogue: (NSString *) dialogue
                  numFields: (NSUInteger) numFields;
+ (NSString *) removeCommandsFromEventText: (NSString *) text;

@end

@interface GPDecoder : NSObject

@property (readonly, nonatomic) NSUInteger frameWidth;
@property (readonly, nonatomic) NSUInteger frameHeight;
@property (readonly, nonatomic) CGFloat fps;
@property (readonly, nonatomic) BOOL isEOF;

@property (readonly, nonatomic) BOOL validVideo;
@property (readonly, nonatomic) BOOL validAudio;
@property (readonly, nonatomic) BOOL validSubtitles;

@property (nonatomic, assign) BOOL isNetWorkPath;

@property (readwrite,nonatomic) NSInteger selectedSubtitleStream;
@property (readonly, nonatomic) NSUInteger subtitleStreamsCount;
@property (assign, nonatomic) BOOL disableDeinterlacing;

- (BOOL)openURLString:(NSString *)urlString error:(NSError **)error;
- (NSArray *)decodeFrames:(CGFloat)minDuration;
- (BOOL)setVideoFormat:(GPVideoFrameFormat)videoFormat;

@end
