//
//  GPPlayerController.m
//  GPPlayer
//
//  Created by apple on 15/7/13.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import "GPPlayerController.h"
#import "GPAudioManager.h"
#import "GPLog.h"
#import "GPDecoder.h"
#import "GPDecoderRenderView.h"

@interface GPPlayerController (){
    NSMutableArray      *_videoFrames;
    NSMutableArray      *_audioFrames;
    NSMutableArray      *_subTitleFrames;
    
    CGFloat             _bufferedDuration;
    CGFloat             _minBufferedDuration;
    CGFloat             _maxBufferedDuration;
    
    BOOL                _buffered;
}

@property (nonatomic,strong) GPDecoder *decoder;

@property (nonatomic,weak) GPDecoderRenderView *renderView;

@property (nonatomic, assign) BOOL playing;

@property (nonatomic, assign) BOOL decoding;

@property (nonatomic,strong) dispatch_queue_t dispatchQueue;

@end

@implementation GPPlayerController

- (instancetype)initWithURLString:(NSString *)urlString{
    if ( self = [super init] ) {
        self.urlString = urlString;
    }
    return self;
}

- (void)setUp{
    if ( ![[GPAudioManager audioManager] activateAudioSession] ) {
        GPLogWarn(@"active audio session fail");
    }
    
    GPDecoder *decoder = [[GPDecoder alloc] init];
    self.decoder = decoder;
    
    self.dispatchQueue = dispatch_queue_create("decoder queue", DISPATCH_QUEUE_SERIAL);
    
    _videoFrames = [NSMutableArray array];
    _audioFrames = [NSMutableArray array];
    _subTitleFrames = [NSMutableArray array];
    
    _maxBufferedDuration = 5;
    _minBufferedDuration = 1;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        BOOL success = [decoder openURLString:self.urlString error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setUpRenderView:success];
        });
    });
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setUp];
}

- (void)setUpRenderView:(BOOL)success{
    if ( success ) {
        GPDecoderRenderView *renderView = [[GPDecoderRenderView alloc] initWithFrame:self.view.bounds decoder:self.decoder];
        [self.view addSubview:renderView];
        self.renderView = renderView;
        NSLog(@"decoder inial success");
        [self play];
    } else {
        NSLog(@"decoder intial fail");
    }
}


- (void)play{
    if ( self.playing ) return;
    
    if ( !self.decoder.validVideo || !self.decoder.validAudio ) {
        NSLog(@"decoder is not prepared");
        return;
    }
    self.playing = YES;
    
    [self asyncDecoderFrames];
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self tick];
    });
    
}

- (void)tick{
    if ( _decoder.isEOF ) {
        NSLog(@"stream is end");
        return;
    }
    _buffered = _bufferedDuration < _minBufferedDuration;
    
    if ( _buffered ) {
        NSLog(@"buffering...");
    }
    
    if ( !_buffered )
        [self presentFrame];
}

- (CGFloat)presentFrame{
    CGFloat interval = 0;
    
    if ( self.decoder.validVideo ) {
        GPVideoFrame *frame = nil;
        
        @synchronized( _videoFrames ) {
            if ( _videoFrames.count ) {
                frame = _videoFrames[0];
                [_videoFrames removeObjectAtIndex:0];
                _bufferedDuration -= frame.duration;
            }
        }
        
        if ( frame  )
            interval = [self presentFrame:frame];
    } else if ( self.decoder.validAudio ) {
        // TODO: artwork frame
    }
    
    NSLog(@"interval = %lf", interval);
    return interval;
}

- (CGFloat)presentFrame:(GPVideoFrame *)frame{
    if ( self.renderView ) {
        [self.renderView render:frame];
        return frame.position;
    } else {
        NSAssert(NO, @"render is not inialize");
    }
    
    return 0;
}

#pragma mark - frameControl
- (void)asyncDecoderFrames{
    if ( self.decoding ) {
        return;
    }
    
    const CGFloat duration = self.decoder.isNetWorkPath ? 0.0f : 0.1f;
    self.decoding = YES;
    
    __weak typeof(self) wself = self;
    __weak typeof(self.decoder) wdecoder = self.decoder;
    
    dispatch_async(self.dispatchQueue, ^{
        
            {
            __strong GPPlayerController *sself = wself;
            if ( !sself.playing ) {
                return ;
            }
            
            BOOL good = YES;
            while ( good ) {
                good = NO;
                @autoreleasepool {
                    
                    __strong GPDecoder *sdecoder = wdecoder;
                    if ( sdecoder && ( sdecoder.validAudio || sdecoder.validVideo ) ) {
                        
                        NSArray *frames = [sdecoder decodeFrames:duration];
                        good = [sself addFrames:frames];
                    }
                }
            }
            
            NSLog(@"_bufferedDuration = %lf",_bufferedDuration);
        }
    });
    
}

- (BOOL)addFrames:(NSArray *)frames{

    if ( self.decoder.validVideo ) {
        
        @synchronized( _videoFrames ) {

            for (GPFrame *item in frames) {
                if ( item.type == GPFrameTypeVideo ) {
                    [_videoFrames addObject:item];
                    _bufferedDuration += item.duration;
                    GPLogStream(@"------------add video duration %f",_bufferedDuration);
                }
            }
        }
    }
    
    if ( self.decoder.validAudio ) {
        
        for (GPFrame *item in frames) {
            if ( item.type == GPFrameTypeAudio ) {
                [_videoFrames addObject:item];
                
                if ( !self.decoder.validVideo ) _bufferedDuration += item.duration;
            }
        }
    }
    
    if ( self.decoder.validSubtitles ) {
        
        for (GPFrame *item in frames) {
            if ( item.type == GPFrameTypeSubtitle ) {
                [_subTitleFrames addObject:item];
            }
        }
    }
    
    return self.playing && _bufferedDuration < _maxBufferedDuration;
}

@end
