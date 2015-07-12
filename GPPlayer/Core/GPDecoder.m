//
//  GPDecoder.m
//  GPPlayer
//
//  Created by mac on 15/6/21.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import "GPDecoder.h"
#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/pixdesc.h"
#include "libavutil/error.h"
#import "GPLog.h"
#import "GPAudioManager.h"

NSString *GPDecoderErrorDomain = @"com.oupai.gpr";

static int          interrupt_callback(void *ctx);
static void         FFLog(void* context, int level, const char* format, va_list args);
static NSError *    GPDecpderError (NSInteger code, id info);
static NSString *   errorMessage(GPDecoderErrorCode errorCode);
static NSArray *    collectionStream(AVFormatContext *fmtContext, enum AVMediaType codecType);
static void         avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase);
static BOOL audioCodecIsSupported(AVCodecContext *audio);

@interface GPDecoder () {
    AVFormatContext             *_formatContext;
    
    NSInteger                   _videoStream;
    AVCodecContext              *_videoCodeConctx;
    NSUInteger                  _artworkStream;
    NSArray                     *_videoStreams;
    AVFrame                     *_videoFrame;
    CGFloat                     _videoTimeBase;
    
    NSInteger                   _audioStream;
    AVCodecContext              *_audioCodecContext;
    NSArray                     *_audioStreams;
    AVFrame                     *_audioFrame;
    SwrContext                  *_swrContext;
    CGFloat                     _audioTimeBase;
}
@end

@implementation GPDecoder

- (void)dealloc{
    [self closeStream];
}

+ (void)initialize{
    av_log_set_callback(FFLog);
    av_register_all();
}

- (NSUInteger)frameWidth{
    return _videoCodeConctx ? _videoCodeConctx->width : 0;
}

- (NSUInteger)frameHeight{
    return _videoCodeConctx ? _videoCodeConctx->height : 0;
}

- (void)closeStream{
    avformat_network_deinit();
    if ( _formatContext ) {
        _formatContext->interrupt_callback.opaque = NULL;
        _formatContext->interrupt_callback.callback = NULL;
        avformat_close_input(&_formatContext);
        avformat_free_context(_formatContext);
    }
    
}

- (BOOL)openURLString:(NSString *)urlString error:(NSError **)error{
    NSAssert(urlString, @"nil path");
    NSAssert(!_formatContext, @"already open");
    BOOL isNetWorkPath = [self isNetWorkURLString:urlString];
    static BOOL isNetWorkNeedToInit = YES;
    if ( isNetWorkNeedToInit && isNetWorkPath ) {
        isNetWorkNeedToInit = NO;
        avformat_network_init();
    }
    
    if ( !isNetWorkPath ) {
        GPLogStream(@"url %@ is not formart",urlString);
    }
    
    GPDecoderErrorCode errorCode = [self openInput:urlString];
    if ( errorCode != GPDecoderErrorNone ) {
        GPLogStream(@"%@ %@",errorMessage(errorCode), urlString.lastPathComponent);
        [self closeStream];
        return NO;
    }
    
    GPDecoderErrorCode videoError = [self openVideoStream];
    GPDecoderErrorCode audioError = [self openAudioStream];
    
    if ( videoError != GPDecoderErrorNone && audioError != GPDecoderErrorNone ) {
        [self closeStream];
        errorCode = videoError;
    }
    
    if ( errorCode != GPDecoderErrorNone ) {
        NSString *streamErrorMessage = errorMessage(errorCode);
        GPLogStream(@"%@", streamErrorMessage);
        NSError *streamError = GPDecpderError(errorCode, streamErrorMessage);
        *error = streamError;
        return NO;
    }
    
    return YES;
}

#pragma mark - AudioStream
- (GPDecoderErrorCode)openAudioStream{
    GPDecoderErrorCode errorCode = GPDecoderErrorStreamNotFound;
    _audioStream = -1;
    _audioStreams = collectionStream(_formatContext, AVMEDIA_TYPE_AUDIO);
    for (NSNumber *n in _audioStreams) {
        if ( ( errorCode = [self openAudioStream:n.integerValue] ) == GPDecoderErrorNone )
            break;
    }
    return errorCode;
}

- (GPDecoderErrorCode)openAudioStream:(NSInteger)audioStream{
    AVCodecContext *codecContex = _formatContext->streams[audioStream]->codec;
    SwrContext *swrContext = NULL;
    
    AVCodec *codec = avcodec_find_decoder(codecContex->codec_id);
    if ( !codec )
        return GPDecoderErrorCodecNotFound;
    
    if ( avcodec_open2(codecContex, codec, NULL) < 0 )
        return GPDecoderErrorOpenDecodec;
    
    if ( !audioCodecIsSupported(codecContex) ) {
        id<GPAudioManager> audioManager = [GPAudioManager audioManager];
        swr_alloc_set_opts(NULL, av_get_default_channel_layout(audioManager.numOutputChannels), AV_SAMPLE_FMT_S16, audioManager.samplingRate, av_get_default_channel_layout(codecContex->channels), codecContex->sample_fmt, codecContex->sample_rate, 0, NULL);
        
        if ( !swrContext || swr_init(swrContext) ) {
            if ( swrContext ) {
                swr_free(&swrContext);
            }
            avcodec_close(codecContex);
            return GPDecoderErrorReSampler;
        }
    }
    
    _audioFrame = av_frame_alloc();
    
    if ( !_audioFrame ) {
        if ( swrContext ) {
            swr_free(&swrContext);
        }
        avcodec_close(codecContex);
        return GPDecoderErrorAllocateFrame;
    }
    
    _audioStream = audioStream;
    _audioCodecContext = codecContex;
    _swrContext = swrContext;
    
    AVStream *st = _formatContext->streams[audioStream];
    
    avStreamFPSTimeBase(st, 0.025, 0, &_audioTimeBase);
    GPLogAudio(@"audio codec smr: %.d fmt: %d chn: %d tb: %f %@",
               _audioCodecContext->sample_rate,
               _audioCodecContext->sample_fmt,
               _audioCodecContext->channels,
               _audioTimeBase,
               _swrContext ? @"resample" : @"");
    return GPDecoderErrorNone;
}

#pragma mark - VideoStream
- (GPDecoderErrorCode)openVideoStream{
    GPDecoderErrorCode errorCode = GPDecoderErrorStreamNotFound;
    _artworkStream = -1;
    _videoStream = -1;
    _videoStreams = collectionStream(_formatContext, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        const NSUInteger iStream = n.integerValue;
        if ( 0 == (_formatContext->streams[iStream]->disposition & AV_DISPOSITION_ATTACHED_PIC) ) {
            errorCode = [self openVideoStream:iStream];
            if ( errorCode == GPDecoderErrorNone )
                break;
        } else {
            _artworkStream = iStream;
        }
    }
    return errorCode;
}

- (GPDecoderErrorCode)openVideoStream:(NSInteger)videoStream{
    AVCodecContext *codecConctx = _formatContext->streams[videoStream]->codec;
    
    AVCodec *codec = avcodec_find_decoder(codecConctx->codec_id);
    if ( !codec ) {
        GPLogVideo(@"%ld not found decoder", videoStream);
        return GPDecoderErrorCodecNotFound;
    }
    
    if ( avcodec_open2(codecConctx, codec, NULL) < 0 ) {
        GPLogVideo(@"%ld open decoder fail", videoStream);
        return GPDecoderErrorOpenDecodec;
        
    }
    
    _videoFrame = av_frame_alloc();
    if ( !_videoFrame ) {
        GPLogVideo(@"%ld av_frame_alloc fail", videoStream);
        return GPDecoderErrorAllocateFrame;
    }
    
    _videoStream = videoStream;
    _videoCodeConctx = codecConctx;
    
    AVStream *st = _formatContext->streams[videoStream];
    avStreamFPSTimeBase(st, 0.04, &_fps, &_videoTimeBase);
    
    GPLogVideo(@"video codec size:w = %tu,h = %tu fps:%f tb:%f",self.frameWidth, self.frameHeight, _fps, _videoTimeBase);
    GPLogVideo(@"start time %lld  disposition %d",st->start_time, st->disposition);
    
    return GPDecoderErrorNone;
}

- (void) openInputStream: (NSString *) path
{
    AVFormatContext *formatCtx = NULL;
    
        
    formatCtx = avformat_alloc_context();
    if (!formatCtx)
        return ;
    
    AVIOInterruptCB cb = {interrupt_callback, (__bridge void *)(self)};
    formatCtx->interrupt_callback = cb;

    
    if (avformat_open_input(&formatCtx, [path cStringUsingEncoding: NSUTF8StringEncoding], NULL, NULL) < 0) {
        
        if (formatCtx)
            avformat_free_context(formatCtx);
        return ;
    }
    
    if (avformat_find_stream_info(formatCtx, NULL) < 0) {
        
        avformat_close_input(&formatCtx);
        return ;
    }
    
    av_dump_format(formatCtx, 0, [path.lastPathComponent cStringUsingEncoding: NSUTF8StringEncoding], false);
    
}

- (GPDecoderErrorCode)openInput:(NSString *)urlString{
    AVFormatContext *formatContext = NULL;
    formatContext = avformat_alloc_context();
    if ( !formatContext ) return GPDecoderErrorOpenFile;
    
    AVIOInterruptCB callBack = {interrupt_callback, (__bridge void *)(self)};
    formatContext->interrupt_callback = callBack;
    int resultCode = avformat_open_input(&formatContext, [urlString cStringUsingEncoding: NSUTF8StringEncoding], NULL, NULL) ;
    if ( resultCode < 0 ) {
        if ( formatContext ) {
            avformat_free_context(formatContext);
            formatContext = NULL;
        }
        return GPDecoderErrorOpenFile;
    }
    
    if ( avformat_find_stream_info(formatContext, NULL) < 0 ) {
        if ( formatContext ) {
            avformat_close_input(&formatContext);
            avformat_free_context(formatContext);
            return GPDecoderErrorStreamInfoNotFound;
        }
    }
    
    av_dump_format(formatContext, 0, [urlString cStringUsingEncoding:NSUTF8StringEncoding], false);
    
    _formatContext = formatContext;
    GPLogStream(@"open stream from %@ success", urlString);
    return GPDecoderErrorNone;
}

- (BOOL)isNetWorkURLString:(NSString *)urlString{
    NSRange r = [urlString rangeOfString:@":"];
    if ( r.location == NSNotFound ) return NO;
    NSString *scheme = [urlString substringToIndex:r.length];
    if ( [scheme isEqualToString:@"file"] ) return NO;
    return YES;
}

@end

#pragma mark - static Function
static BOOL audioCodecIsSupported(AVCodecContext *audio){
    if ( audio->sample_fmt == AV_SAMPLE_FMT_S16 ) {
        id<GPAudioManager> audioManager = [GPAudioManager audioManager];
        return audioManager.samplingRate == audio->sample_fmt &&
                audioManager.numOutputChannels == audio->channels;
    }
    return NO;
}

static int interrupt_callback(void *ctx)
{
    if (!ctx)
        return 0;
//    __unsafe_unretained GPDecoder *p = (__bridge GPDecoder *)ctx;
    GPLogStream(@"DEBUG: INTERRUPT_CALLBACK!");
    return 0;
}

static void avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase){
    CGFloat fps = 0, timeBase = defaultTimeBase;
    
    if ( st == NULL ) {
        return;
    }
    
    if ( st->time_base.num && st->time_base.den )
        timeBase = av_q2d(st->time_base);
    else if ( st->codec->time_base.num && st->codec->time_base.den )
        timeBase = av_q2d(st->codec->time_base);
    
    if ( st->codec->ticks_per_frame != 1 ) {
        GPLogWarn(@"st.codec.ticks_per_frame=%d", st->codec->ticks_per_frame);
    }
    
    if ( st->avg_frame_rate.num && st->avg_frame_rate.den )
        fps = av_q2d(st->avg_frame_rate);
    else if ( st->r_frame_rate.num && st->r_frame_rate.den )
        fps = av_q2d(st->r_frame_rate);
    else
        fps = 1.0 / timeBase;
    
    if ( pFPS )
        *pFPS = fps;
    if ( pTimeBase )
        *pTimeBase = timeBase;
    
}

static NSError * GPDecpderError (NSInteger code, id info)
{
    NSDictionary *userInfo = nil;
    
    if ([info isKindOfClass: [NSDictionary class]]) {
        
        userInfo = info;
        
    } else if ([info isKindOfClass: [NSString class]]) {
        
        userInfo = @{ NSLocalizedDescriptionKey : info };
    }
    
    return [NSError errorWithDomain:GPDecoderErrorDomain
                               code:code
                           userInfo:userInfo];
}

static NSString *errorMessage(GPDecoderErrorCode errorCode){
    switch ( errorCode ) {
        case GPDecoderErrorOpenFile:
            return NSLocalizedString(@"Unable to open file", nil);
            break;
        case GPDecoderErrorStreamInfoNotFound:
            return NSLocalizedString(@"Unable to find stream information", nil);
            break;
        case GPDecoderErrorCodecNotFound:
            return NSLocalizedString(@"can not find decoder", nil);
            break;
        case GPDecoderErrorOpenDecodec:
            return NSLocalizedString(@"can not fopen decoder", nil);
            break;
        case GPDecoderErrorAllocateFrame:
            return NSLocalizedString(@"av_frame_alloc fail", nil);
            break;
        default:
            break;
    }
    return @"";
}

static NSArray * collectionStream(AVFormatContext *fmtContext, enum AVMediaType codecType){
    NSMutableArray *ma = [NSMutableArray arrayWithCapacity:fmtContext->nb_streams];
    for (NSInteger i = 0; i < fmtContext->nb_streams; ++i) {
        if ( codecType == fmtContext->streams[i]->codec->codec_type ) {
            [ma addObject:@(i)];
        }
    }
    return [ma copy];
}

static void FFLog(void* context, int level, const char* format, va_list args) {
    @autoreleasepool {
        //Trim time at the beginning and new line at the end
        NSString* message = [[NSString alloc] initWithFormat: [NSString stringWithUTF8String: format] arguments: args];
        switch (level) {
            case 0:
            case 1:
                GPLogStream(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                break;
            case 2:
                GPLogStream(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                break;
            case 3:
            case 4:
                GPLogStream(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                break;
            default:
                GPLogStream(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                break;
        }
    }
}
