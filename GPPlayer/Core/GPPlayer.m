//
//  GPPlayer.m
//  GPPlayer
//
//  Created by apple on 15/7/14.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import "GPPlayer.h"
#import "GPAudioManager.h"
#import "GPLog.h"
#import "GPDecoder.h"
#import "GPDecoderRenderView.h"
#include <pthread.h>

NSString *const GPCurrBufferedDuaration = @"GPCurrBufferedDuaration";

#define kDefaultMinBufferedDuration         2
#define kDefaultMaxBufferedDuration         5

@interface GPPlayer () {
    NSMutableArray      *_videoFrames;
    NSMutableArray      *_audioFrames;
    NSMutableArray      *_subTitleFrames;

    GPDecoder           *_decoder;
    dispatch_queue_t    _controlQueue;
    dispatch_queue_t    _playQueue;
    
    CGFloat             _moviePosition;
    NSTimeInterval      _tickCorrectionTime;
    NSTimeInterval      _tickCorrectionPosition;
    
    pthread_mutex_t     _mutexPkt;
    pthread_cond_t      _condPkt;
}

@property (nonatomic,weak) UIView *targetView;

@property (nonatomic,strong) GPDecoderRenderView *renderView;

@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) BOOL decoding;
@property (nonatomic, assign) BOOL ready;

@end

@implementation GPPlayer ( State )

- (void)updateState:(GPPlayerState)state withParams:(NSDictionary *)params{
    if ( [[NSThread currentThread] isMainThread] ) {
        [self performState:state withParams:params];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performState:state withParams:params];
        });
    }
}

- (void)performState:(GPPlayerState)state withParams:(NSDictionary *)params{
    self.state = state;
    if ( [self.delegate respondsToSelector:@selector(player:stateDidChanged:withParams:)] ) {
        [self.delegate player:self stateDidChanged:state withParams:params];
    }
}

@end

@implementation GPPlayer

- (void)dealloc{
    pthread_cond_destroy(&_condPkt);
    pthread_mutex_destroy(&_mutexPkt);
}

- (instancetype)initWithURLString:(NSString *)urlString targetView:(UIView *)targetView{
    if ( self = [super init] ) {
        _urlString = urlString;
        self.targetView = targetView;
        [self setUp];
    }
    return self;
}

- (void)setUp{
    _videoFrames = [NSMutableArray array];
    _audioFrames = [NSMutableArray array];
    _subTitleFrames = [NSMutableArray array];
    
    _maxBufferedDuration = kDefaultMaxBufferedDuration;
    _minBufferedDuration = kDefaultMinBufferedDuration;
    
    _controlQueue = dispatch_queue_create("player_control_queue", DISPATCH_QUEUE_SERIAL);
    _playQueue = dispatch_queue_create("player_render_queue", DISPATCH_QUEUE_SERIAL);
    _decoder = [[GPDecoder alloc] init];
    
    pthread_mutex_init(&_mutexPkt, NULL);
    pthread_cond_init(&_condPkt, NULL);
}

- (void)prepare{
    if ( ![[GPAudioManager audioManager] activateAudioSession] ) {
        GPLogWarn(@"active audio session fail");
        [self performState:GPPlayerStateInialFail withParams:nil];
        return;
    }
    dispatch_async(_controlQueue, ^{
        if ( ![_decoder openURLString:self.urlString error:NULL] ) {
            [self performState:GPPlayerStateInialFail withParams:nil];
        } else {
            [self asyncDecoderFrames];
            dispatch_async(dispatch_get_main_queue(), ^{
               [self initialRenderView];
                pthread_mutex_lock(&_mutexPkt);
                pthread_cond_signal(&_condPkt);
                pthread_mutex_unlock(&_mutexPkt);
            });
        }
    });
}

- (void)initialRenderView{
    for (UIView *subView in self.targetView.subviews) {
        if ( [subView isKindOfClass:[GPDecoderRenderView class]] ) {
            [subView removeFromSuperview];
        }
    }
    
    GPDecoderRenderView *renderView = [[GPDecoderRenderView alloc] initWithFrame:self.targetView.bounds decoder:_decoder];
    [self.targetView addSubview:renderView];
    self.renderView = renderView;
}

- (void)play{
    if ( _decoder.isEOF ) {
        GPLogStream(@"stream is end....");
        [self performState:GPPlayerStateStreamEnd withParams:nil];
        self.playing = NO;
        return;
    }
    
    if ( self.playing ) return;
    
    if ( !_decoder.validVideo || !_decoder.validAudio ) {
        GPLogStream(@"decoder is not prepared");
        return;
    }
    self.playing = YES;
    
    [self startRender];
}

- (void)startRender{
    dispatch_async(_playQueue, ^{
        
        while ( YES ) {
            [self presentFrame];
            [NSThread sleepForTimeInterval:0.5];
        }
        
//        CGFloat interval = [self presentFrame];
//        
//        
//        const NSTimeInterval correction = [self tickCorrection];
//        const NSTimeInterval time = MAX(interval + correction, 0.01);
//        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
//        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
//            [self startRender];
//        });
    });
}

- (CGFloat) presentFrame
{
    CGFloat interval = 0;
    
    if (_decoder.validVideo) {
        
        GPVideoFrame *frame;
        
        @synchronized(_videoFrames) {
            
            if (_videoFrames.count > 0) {
                
                frame = _videoFrames[0];
                [_videoFrames removeObjectAtIndex:0];
                _bufferedDuration -= frame.duration;
            }
        }
        
        if (frame)
            interval = [self presentFrame:frame];
        
    } else if (_decoder.validAudio) {
        
        //interval = _bufferedDuration * 0.5;
        
//        if (self.artworkFrame) {
//            
//            _imageView.image = [self.artworkFrame asImage];
//            self.artworkFrame = nil;
//        }
    }
    
//    if (_decoder.validSubtitles)
//        [self presentSubtitles];
    
    return interval;
}

- (CGFloat) tickCorrection{
    
    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    
    if (!_tickCorrectionTime) {
        
        _tickCorrectionTime = now;
        _tickCorrectionPosition = _moviePosition;
        return 0;
    }
    
    NSTimeInterval dPosition = _moviePosition - _tickCorrectionPosition;
    NSTimeInterval dTime = now - _tickCorrectionTime;
    NSTimeInterval correction = dPosition - dTime;
    
    //if ((_tickCounter % 200) == 0)
    //    LoggerStream(1, @"tick correction %.4f", correction);
    
    if (correction > 1.f || correction < -1.f) {
        GPLogStream(@"tick correction reset %.2f", correction);
        correction = 0;
        _tickCorrectionTime = 0;
    }
    
    return correction;
}

- (CGFloat)presentFrame:(GPVideoFrame *)frame{
    if ( self.renderView ) {
        NSLog(@"frame -- %@",frame);
        dispatch_async(dispatch_get_main_queue(), ^{
           [self.renderView render:frame];
        });
    } else {
        NSAssert(NO, @"render is not inialize");
    }
    _moviePosition = frame.position;
    return _moviePosition;
}

- (void)asyncDecoderFrames{
    if ( self.decoding ) {
        return;
    }
    
    const CGFloat duration = _decoder.isNetWorkPath ? 0.0f : 0.1f;
    self.decoding = YES;
    
    __weak typeof(self) wself = self;
    __weak typeof(_decoder) wdecoder = _decoder;
    
    dispatch_async(_controlQueue, ^{
        
        __strong GPPlayer *sself = wself;
    
        [self performState:GPPlayerStateBuffering withParams:nil];
    
        BOOL good = YES;
        while ( good ) {
            good = NO;
            @autoreleasepool {
                
                __strong GPDecoder *sdecoder = wdecoder;
                if ( sdecoder && ( sdecoder.validAudio || sdecoder.validVideo ) ) {
                    
                    NSArray *frames = [sdecoder decodeFrames:duration];
                    __strong GPPlayer *strongSelf = wself;
                    if ( frames.count && strongSelf ) {
                        good = [sself addFrames:frames];
                    }
                    
                }
            }
        }
        
        {
            __strong GPPlayer *strongSelf = wself;
            if (strongSelf) strongSelf.decoding = NO;
        }
        NSLog(@"buffered completed bufferedDuration = %lf",_bufferedDuration);
        [self performState:GPPlayerStateBufferCompleted withParams:@{GPCurrBufferedDuaration: @(_bufferedDuration)}];
        
        if ( !sself.ready ) {
            sself.ready = YES;
            if ( sself.renderView == nil ) {
                pthread_mutex_lock(&_mutexPkt);
                pthread_cond_wait(&_condPkt, &_mutexPkt);
                pthread_mutex_unlock(&_mutexPkt);
            }
            [self performState:GPPlayerStatePrepared withParams:nil];
        }
    });
}

- (BOOL)addFrames:(NSArray *)frames{
    
    if ( _decoder.validVideo ) {
        
        @synchronized( _videoFrames ) {
            
            for (GPFrame *item in frames) {
                if ( item.type == GPFrameTypeVideo ) {
                    [_videoFrames addObject:item];
                    _bufferedDuration += item.duration;
                }
            }
        }
    }
    
    if ( _decoder.validAudio ) {
        
        for (GPFrame *item in frames) {
            if ( item.type == GPFrameTypeAudio ) {
                [_videoFrames addObject:item];
                
                if ( !_decoder.validVideo ) _bufferedDuration += item.duration;
            }
        }
    }
    
    if ( _decoder.validSubtitles ) {
        
        for (GPFrame *item in frames) {
            if ( item.type == GPFrameTypeSubtitle ) {
                [_subTitleFrames addObject:item];
            }
        }
    }
    
    return _bufferedDuration < _maxBufferedDuration;
}

@end


