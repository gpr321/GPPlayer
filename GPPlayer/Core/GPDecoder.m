//
//  GPDecoder.m
//  GPPlayer
//
//  Created by mac on 15/6/21.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import "GPDecoder.h"
#import <Accelerate/Accelerate.h>
#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/pixdesc.h"
#include "libavutil/error.h"
#import "GPLog.h"
#import "GPAudioManager.h"


@interface GPFrame ()
@property (nonatomic, assign) GPFrameType type;
@property (nonatomic, assign) CGFloat position;
@property (nonatomic, assign) CGFloat duration;
@end

@implementation GPFrame

- (void)dealloc{
    GPLogStream(@"--------%@ - dealloc", [self class]);
}

@end

@interface GPAudioFrame ()
@property (nonatomic,strong) NSData *samples;
@end

@implementation GPAudioFrame
- (GPFrameType)type { return GPFrameTypeAudio; }
@end

@interface GPVideoFrame ()
@property (nonatomic, assign) GPVideoFrameFormat format;
@property (nonatomic, assign) CGFloat height;
@property (nonatomic, assign) CGFloat width;
@end

@implementation GPVideoFrame
- (GPFrameType)type { return GPFrameTypeVideo; }
@end

@implementation GPVideoFrameRGB
- (GPVideoFrameFormat)format { return GPVideoFrameFormatRGB; }
- (UIImage *)asImage{
    UIImage *image  = nil;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)_rgb);
    if ( provider ) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if ( colorSpace ) {
             CGImageRef imageRef = CGImageCreate(self.width, self.height, 8, 24, self.linesize, colorSpace, kCGBitmapByteOrderDefault, provider, NULL, YES, kCGRenderingIntentDefault);
            if ( imageRef ) {
                image = [[UIImage alloc] initWithCGImage:imageRef];
                CFRelease(imageRef);
            }
            CFRelease(colorSpace);
        }
        CFRelease(provider);
    }
    return image;
}
@end

@interface GPVideoFrameYUV ()
@property (nonatomic, strong) NSData *luma;
@property (nonatomic, strong) NSData *chromaB;
@property (nonatomic, strong) NSData *chromaR;
@end

@implementation GPVideoFrameYUV
- (GPVideoFrameFormat)format { return GPVideoFrameFormatYUV; }
@end

@interface GPArtworkFrame ()
@property (nonatomic, strong) NSData *picture;
@end

@implementation GPArtworkFrame
- (GPFrameType)type { return GPFrameTypeArtwork; }
- (UIImage *) asImage
{
    UIImage *image = nil;
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)(_picture));
    if (provider) {
        
        CGImageRef imageRef = CGImageCreateWithJPEGDataProvider(provider,
                                                                NULL,
                                                                YES,
                                                                kCGRenderingIntentDefault);
        if (imageRef) {
            
            image = [UIImage imageWithCGImage:imageRef];
            CGImageRelease(imageRef);
        }
        CGDataProviderRelease(provider);
    }
    
    return image;
}
@end

@interface GPSubtitleFrame ()
@property (readwrite, nonatomic, strong) NSString *text;
@end

@implementation GPSubtitleFrame
- (GPFrameType)type { return GPFrameTypeSubtitle; }
@end

@implementation GPSubtitleASSParser

+ (NSArray *) parseEvents: (NSString *) events
{
    NSRange r = [events rangeOfString:@"[Events]"];
    if (r.location != NSNotFound) {
        
        NSUInteger pos = r.location + r.length;
        
        r = [events rangeOfString:@"Format:"
                          options:0
                            range:NSMakeRange(pos, events.length - pos)];
        
        if (r.location != NSNotFound) {
            
            pos = r.location + r.length;
            r = [events rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]
                                        options:0
                                          range:NSMakeRange(pos, events.length - pos)];
            
            if (r.location != NSNotFound) {
                
                NSString *format = [events substringWithRange:NSMakeRange(pos, r.location - pos)];
                NSArray *fields = [format componentsSeparatedByString:@","];
                if (fields.count > 0) {
                    
                    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
                    NSMutableArray *ma = [NSMutableArray array];
                    for (NSString *s in fields) {
                        [ma addObject:[s stringByTrimmingCharactersInSet:ws]];
                    }
                    return ma;
                }
            }
        }
    }
    
    return nil;
}

+ (NSArray *) parseDialogue: (NSString *) dialogue
                  numFields: (NSUInteger) numFields
{
    if ([dialogue hasPrefix:@"Dialogue:"]) {
        
        NSMutableArray *ma = [NSMutableArray array];
        
        NSRange r = {@"Dialogue:".length, 0};
        NSUInteger n = 0;
        
        while (r.location != NSNotFound && n++ < numFields) {
            
            const NSUInteger pos = r.location + r.length;
            
            r = [dialogue rangeOfString:@","
                                options:0
                                  range:NSMakeRange(pos, dialogue.length - pos)];
            
            const NSUInteger len = r.location == NSNotFound ? dialogue.length - pos : r.location - pos;
            NSString *p = [dialogue substringWithRange:NSMakeRange(pos, len)];
            p = [p stringByReplacingOccurrencesOfString:@"\\N" withString:@"\n"];
            [ma addObject: p];
        }
        
        return ma;
    }
    
    return nil;
}

+ (NSString *) removeCommandsFromEventText: (NSString *) text
{
    NSMutableString *ms = [NSMutableString string];
    
    NSScanner *scanner = [NSScanner scannerWithString:text];
    while (!scanner.isAtEnd) {
        
        NSString *s;
        if ([scanner scanUpToString:@"{\\" intoString:&s]) {
            
            [ms appendString:s];
        }
        
        if (!([scanner scanString:@"{\\" intoString:nil] &&
              [scanner scanUpToString:@"}" intoString:nil] &&
              [scanner scanString:@"}" intoString:nil])) {
            
            break;
        }
    }
    
    return ms;
}


@end

NSString *GPDecoderErrorDomain = @"com.oupai.gpr";

static int          interrupt_callback(void *ctx);
static void         FFLog(void* context, int level, const char* format, va_list args);
static NSError *    GPDecpderError (NSInteger code, id info);
static NSString *   errorMessage(GPDecoderErrorCode errorCode);
static NSArray *    collectionStream(AVFormatContext *fmtContext, enum AVMediaType codecType);
static void         avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase);
static BOOL audioCodecIsSupported(AVCodecContext *audio);
static NSData * copyFrameData(UInt8 *src, int linesize, int width, int height);

@interface GPDecoder () {
    AVFormatContext             *_formatContext;
    CGFloat                     _position;
    
    NSInteger                   _videoStream;
    AVCodecContext              *_videoCodeConctx;
    NSArray                     *_videoStreams;
    AVFrame                     *_videoFrame;
    CGFloat                     _videoTimeBase;
    BOOL                        _pictureValid;
    AVPicture                   _picture;
    struct SwsContext           *_swsContext;
    GPVideoFrameFormat          _videoFormat;
    
    NSUInteger                  _artworkStream;
    
    NSInteger                   _audioStream;
    AVCodecContext              *_audioCodecContext;
    NSArray                     *_audioStreams;
    AVFrame                     *_audioFrame;
    SwrContext                  *_swrContext;
    CGFloat                     _audioTimeBase;
    void                        *_swrBuffer;
    NSUInteger                  _swrBufferSize;
    
    NSInteger                   _subtitleStream;
    AVCodecContext              *_subTitleContext;
    NSArray                     *_subTitleStreams;
    NSInteger                   _subtitleASSEvents;
}
@end

@implementation GPDecoder

@dynamic subtitleStreamsCount;
@dynamic selectedSubtitleStream;
@dynamic validVideo;
@dynamic validAudio;
@dynamic validSubtitles;

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
    [self closeAudeoStream];
    [self closeVideStream];
    [self closeSubTitleStream];
    
    _audioStreams = nil;
    _videoStreams = nil;
    _subTitleStreams = nil;
    
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
    self.isNetWorkPath = isNetWorkPath;
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
    
    _subtitleStream = -1;
    
    if ( videoError != GPDecoderErrorNone && audioError != GPDecoderErrorNone ) {
        [self closeStream];
        errorCode = videoError;
    } else {
        _subTitleStreams = collectionStream(_formatContext, AVMEDIA_TYPE_DATA);
    }
    
    if ( errorCode != GPDecoderErrorNone ) {
        NSString *streamErrorMessage = errorMessage(errorCode);
        GPLogStream(@"%@", streamErrorMessage);
        NSError *streamError = GPDecpderError(errorCode, streamErrorMessage);
        if ( error ) {
            *error = streamError;
        }
        return NO;
    }
    
    return YES;
}

#pragma mark - SubTitleStream
- (GPDecoderErrorCode)openSubTitleStream:(NSInteger)subtitleStream{
    AVCodecContext *codecContext = _formatContext->streams[subtitleStream]->codec;
    AVCodec *codec = avcodec_find_decoder(codecContext->codec_id);
    if ( !codec ) {
        return GPDecoderErrorCodecNotFound;
    }
    
    const AVCodecDescriptor *codecDesc = avcodec_descriptor_get(codecContext->codec_id);
    if (codecDesc && (codecDesc->props & AV_CODEC_PROP_BITMAP_SUB)) {
        // Only text based subtitles supported
        return GPDecoderErrorUnsupport;
    }
    
    if ( avcodec_open2(codecContext, codec, NULL) < 0 ) return GPDecoderErrorOpenDecodec;
    
    _subtitleStream = subtitleStream;
    _subTitleContext = codecContext;

    GPLogStream(@"subtitle codec: '%s' mode: %d enc: %s",
                codecDesc->name,
                codecContext->sub_charenc_mode,
                codecContext->sub_charenc);
    
    _subtitleASSEvents = -1;
    
    if ( codecContext->subtitle_header_size ) {
        NSString *s = [[NSString alloc] initWithBytes:codecContext->subtitle_header length:codecContext->subtitle_header_size encoding:NSASCIIStringEncoding];
        if ( s.length ) {
            NSArray *fields = [GPSubtitleASSParser parseEvents:s];
            if (fields.count && [fields.lastObject isEqualToString:@"Text"]) {
                _subtitleASSEvents = fields.count;
                GPLogStream(@"subtitle ass events: %@", [fields componentsJoinedByString:@","]);
            }
        }
    }
    
    return GPDecoderErrorNone;
}

- (void)closeSubTitleStream{
    _subtitleStream = -1;
    if ( _subTitleContext ) {
        avcodec_close(_subTitleContext);
        _subTitleContext = NULL;
    }
}

- (NSUInteger)subtitleStreamsCount{
    return [_subTitleStreams count];
}

- (NSInteger)selectedSubtitleStream{
    if ( _subtitleStream == -1 ) return -1;
    return [_subTitleStreams indexOfObject:@(_subtitleStream)];
}

- (void)setSelectedSubtitleStream:(NSInteger)selectedSubtitleStream{
    [self closeSubTitleStream];
    if ( selectedSubtitleStream == -1 ) {
        _subtitleStream = -1;
    } else {
        NSInteger subtitleStream = [_subTitleStreams[selectedSubtitleStream] integerValue];
        GPDecoderErrorCode errorCode = [self openSubTitleStream:subtitleStream];
        if ( GPDecoderErrorNone != errorCode ) {
            GPLogStream(@"%@",errorMessage(errorCode));
        }
    }
}

- (GPSubtitleFrame *) handleSubtitle: (AVSubtitle *)pSubtitle
{
    NSMutableString *ms = [NSMutableString string];
    
    for (NSUInteger i = 0; i < pSubtitle->num_rects; ++i) {
        
        AVSubtitleRect *rect = pSubtitle->rects[i];
        if (rect) {
            
            if (rect->text) { // rect->type == SUBTITLE_TEXT
                
                NSString *s = [NSString stringWithUTF8String:rect->text];
                if (s.length) [ms appendString:s];
                
            } else if (rect->ass && _subtitleASSEvents != -1) {
                
                NSString *s = [NSString stringWithUTF8String:rect->ass];
                if (s.length) {
                    
                    NSArray *fields = [GPSubtitleASSParser parseDialogue:s numFields:_subtitleASSEvents];
                    if (fields.count && [fields.lastObject length]) {
                        
                        s = [GPSubtitleASSParser removeCommandsFromEventText: fields.lastObject];
                        if (s.length) [ms appendString:s];
                    }
                }
            }
        }
    }
    
    if (!ms.length)
        return nil;
    
    GPSubtitleFrame *frame = [[GPSubtitleFrame alloc] init];
    frame.text = [ms copy];
    frame.position = pSubtitle->pts / AV_TIME_BASE + pSubtitle->start_display_time;
    frame.duration = (CGFloat)(pSubtitle->end_display_time - pSubtitle->start_display_time) / 1000.f;
    
    GPLogStream(@"SUB: %.4f %.4f | %@",
                frame.position,
                frame.duration,
                frame.text);
    
    return frame;
}

- (BOOL)validSubtitles{
    return _subtitleStream != -1;
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
        
//        swr_alloc_set_opts(NULL, av_get_default_channel_layout(audioManager.numOutputChannels), AV_SAMPLE_FMT_S16, audioManager.samplingRate, av_get_default_channel_layout(codecContex->channels), codecContex->sample_fmt, codecContex->sample_rate, 0, NULL);
        
        swrContext = swr_alloc_set_opts(NULL,
                                        av_get_default_channel_layout(audioManager.numOutputChannels),
                                        AV_SAMPLE_FMT_S16,
                                        audioManager.samplingRate,
                                        av_get_default_channel_layout(codecContex->channels),
                                        codecContex->sample_fmt,
                                        codecContex->sample_rate,
                                        0,
                                        NULL);

        
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

- (void)closeAudeoStream{
    _audioStream = -1;
    
    if ( _swrBuffer ) {
        free(_swrBuffer);
        _swrBuffer = NULL;
        _swrBufferSize = 0;
    }
    
    if ( _swrContext ) {
        free(_swrContext);
        _swrContext = NULL;
    }
    
    if ( _audioFrame ) {
        av_free(_audioFrame);
        _audioFrame = NULL;
    }
    
    if ( _audioCodecContext ) {
        avcodec_close(_audioCodecContext);
        _audioCodecContext = NULL;
    }
}

- (GPAudioFrame *)handleAudioFrame{
    if ( !_audioFrame->data[0] ) return nil;
    
    id<GPAudioManager> audioManager = [GPAudioManager audioManager];
    
    const NSUInteger numChanels = audioManager.numOutputChannels;
    NSInteger numFrames;
    void *audioData;
    
    if ( _swrContext ) {
        const NSUInteger ratio = MAX(1, audioManager.samplingRate / _audioCodecContext->sample_rate) *
                                MAX(1, audioManager.numOutputChannels / _audioCodecContext->channels) * 2;
        
        const int bufSize = av_samples_get_buffer_size(NULL, audioManager.numOutputChannels, _audioFrame->nb_samples * ratio, AV_SAMPLE_FMT_S16, 1);
        
        if (!_swrBuffer || _swrBufferSize < bufSize) {
            _swrBufferSize = bufSize;
            _swrBuffer = realloc(_swrBuffer, _swrBufferSize);
        }
        Byte *outbuf[2] = { _swrBuffer, 0 };
        
        numFrames = swr_convert(_swrContext,
                                outbuf,
                                _audioFrame->nb_samples * ratio,
                                (const uint8_t **)_audioFrame->data,
                                _audioFrame->nb_samples);
        
        if (numFrames < 0) {
            GPLogAudio(@"fail resample audio");
            return nil;
        }
        audioData = _swrBuffer;
        
    } else {
        if (_audioCodecContext->sample_fmt != AV_SAMPLE_FMT_S16) {
            NSAssert(false, @"bucheck, audio format is invalid");
            return nil;
        }
        
        audioData = _audioFrame->data[0];
        numFrames = _audioFrame->nb_samples;
    }
    
    const NSUInteger numElements = numFrames * numChanels;
    NSMutableData *data = [NSMutableData dataWithLength:numElements * sizeof(float)];
    
    float scale = 1.0 / (float)INT16_MAX ;
    vDSP_vflt16((SInt16 *)audioData, 1, data.mutableBytes, 1, numElements);
    vDSP_vsmul(data.mutableBytes, 1, &scale, data.mutableBytes, 1, numElements);
    
    GPAudioFrame *frame = [[GPAudioFrame alloc] init];
    frame.position = av_frame_get_best_effort_timestamp(_audioFrame) * _audioTimeBase;
    frame.duration = av_frame_get_pkt_duration(_audioFrame) * _audioTimeBase;
    frame.samples = data;
    
    if ( frame.duration == 0 ) {
        // sometimes ffmpeg can't determine the duration of audio frame
        // especially of wma/wmv format
        // so in this case must compute duration
        frame.duration = frame.samples.length / (sizeof(float) * numChanels * audioManager.samplingRate);
    }
    
    GPLogAudio(@"AFD: %.4f %.4f | %.4f ",
               frame.position,
               frame.duration,
               frame.samples.length / (8.0 * 44100.0));
    
    return frame;
}

- (BOOL)validAudio{
    return _audioStream != -1;
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

- (BOOL)validVideo{
    return _videoStream != -1;
}

- (void)closeVideStream{
    _videoStream = -1;
    [self closeScaler];
    if ( _videoFrame ) {
        av_free(_videoFrame);
        _videoFrame = NULL;
    }
    
    if ( _videoCodeConctx ) {
        avcodec_close(_videoCodeConctx);
        _videoCodeConctx = NULL;
    }
}

- (void)closeScaler{
    if ( _swrContext ) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    
    if ( _pictureValid ) {
        avpicture_free(&_picture);
        _pictureValid = NO;
    }
}

- (BOOL)setUpScaler{
    [self closeScaler];
    _pictureValid = avpicture_alloc(&_picture,
                                    AV_PIX_FMT_RGB24,
                                    _videoCodeConctx->width,
                                    _videoCodeConctx->height);
    if ( !_pictureValid ) return NO;
    
    _swsContext = sws_getCachedContext(_swsContext,
                                       _videoCodeConctx->width,
                                       _videoCodeConctx->height,
                                       _videoCodeConctx->pix_fmt,
                                       _videoCodeConctx->width,
                                       _videoCodeConctx->height,
                                       PIX_FMT_RGB24,
                                       SWS_FAST_BILINEAR,
                                       NULL, NULL, NULL);
    
    return _swsContext != NULL;
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

- (BOOL)setVideoFormat:(GPVideoFrameFormat)videoFormat{
    if ( videoFormat == GPVideoFrameFormatYUV &&
        _videoCodeConctx &&
        ( _videoCodeConctx->pix_fmt == AV_PIX_FMT_YUV420P || _videoCodeConctx->pix_fmt == AV_PIX_FMT_YUVJ420P )
        ) {
        _videoFormat = videoFormat;
        return YES;
    }
    
    _videoFormat = GPVideoFrameFormatRGB;
    return _videoFormat == videoFormat;
}

- (GPVideoFrame *)handleVideoFrame{
    if ( !_videoFrame->data[0] ) return nil;
    
    GPVideoFrame *frame = nil;
    
    if ( _videoFormat == GPVideoFrameFormatYUV ) {
        GPVideoFrameYUV *yuvFrame = [[GPVideoFrameYUV alloc] init];
        
        yuvFrame.luma = copyFrameData(_videoFrame->data[0],
                                      _videoFrame->linesize[0],
                                      _videoCodeConctx->width,
                                      _videoCodeConctx->height);
        
        yuvFrame.chromaB = copyFrameData(_videoFrame->data[1],
                                         _videoFrame->linesize[1],
                                         _videoCodeConctx->width / 2,
                                         _videoCodeConctx->height / 2);
        
        yuvFrame.chromaR = copyFrameData(_videoFrame->data[2],
                                         _videoFrame->linesize[2],
                                         _videoCodeConctx->width / 2,
                                         _videoCodeConctx->height / 2);
        frame = yuvFrame;
    } else {
        if ( !_swsContext && ![self setUpScaler] ) {
            GPLogVideo(@"fail setup video scaler");
            return nil;
        }
        
        sws_scale(_swsContext,
                  (const uint8_t **)_videoFrame->data,
                  _videoFrame->linesize,
                  0,
                  _videoCodeConctx->height,
                  _picture.data,
                  _picture.linesize);
        GPVideoFrameRGB *rgbFrame = [[GPVideoFrameRGB alloc] init];
        rgbFrame.linesize = _picture.linesize[0];
        rgbFrame.rgb = [NSData dataWithBytes:_picture.data[0] length:rgbFrame.linesize * _videoCodeConctx->height];
        frame = rgbFrame;
    }
    frame.width = _videoCodeConctx->width;
    frame.height = _videoCodeConctx->height;
    frame.position = av_frame_get_best_effort_timestamp(_videoFrame) * _videoTimeBase;
    
    const int64_t frameDuration = av_frame_get_pkt_duration(_videoFrame) * _videoTimeBase;
    
    if ( frameDuration ) {
        frame.duration = frameDuration * _videoTimeBase;
        // ???
        frame.duration += _videoFrame->repeat_pict * _videoTimeBase * 0.5;
    } else {
        
        // sometimes, ffmpeg unable to determine a frame duration
        // as example yuvj420p stream from web camera
        frame.duration = 1.0 / _fps;
    }
    
    GPLogVideo(@"VFD: %.4f %.4f | %lld ",
               frame.position,
               frame.duration,
               av_frame_get_pkt_pos(_videoFrame));
    
    return frame;
}

#pragma mark - public method
- (NSArray *)decodeFrames:(CGFloat)minDuration{
    if ( _videoStream == -1 && _audioStream == -1 ) return nil;
    NSMutableArray *result = [NSMutableArray array];
    
    AVPacket packet;
    CGFloat decodedDuration = 0;
    BOOL finished = NO;
    
    while ( !finished ) {
        if ( av_read_frame(_formatContext, &packet) < 0 ) {
            _isEOF = YES;
            break;
        }
        
        if ( packet.stream_index == _videoStream ) {
            
            int pktSize = packet.size;
            
            while ( pktSize > 0 ) {
                int gotFrame = 0;
                int len = avcodec_decode_video2(_videoCodeConctx, _videoFrame, &gotFrame, &packet);
                if ( len < 0 ) {
                    GPLogWarn(@"videoStream -> decode video error, skip packet");
                    break;
                }
                
                if ( gotFrame ) {
                    
                    if ( !_disableDeinterlacing &&
                       _videoFrame->interlaced_frame ) {
                        // 适配老的视频格式
                        avpicture_deinterlace((AVPicture*)_videoFrame,
                                              (AVPicture*)_videoFrame,
                                              _videoCodeConctx->pix_fmt,
                                              _videoCodeConctx->width,
                                              _videoCodeConctx->height);
                    }
                    
                    GPFrame *frame = [self handleVideoFrame];
                    
                    if ( frame ) {
                        [result addObject:frame];
                        _position = frame.position;
                        decodedDuration += frame.duration;
                        
                        if ( decodedDuration > minDuration ) {
                            finished = YES;
                        }
                        
                    }
                    if ( 0 == len ) break;
                    pktSize -= len;
                    
                }
                
            }
            
        } else if ( packet.stream_index == _audioStream ) {
            int pktSize = packet.size;
            
            while ( pktSize > 0 ) {
                
                int gotframe = 0;
                int len = avcodec_decode_audio4(_audioCodecContext,
                                                _audioFrame,
                                                &gotframe,
                                                &packet);
                
                if (len < 0) {
                    GPLogWarn(@"audioStream -> decode audio error, skip packet");
                    break;
                }
                    
                if ( gotframe ) {
                    GPAudioFrame *frame = [self handleAudioFrame];
                    if (frame) {
                        [result addObject:frame];
                        
                        if (_videoStream == -1) {
                            
                            _position = frame.position;
                            decodedDuration += frame.duration;
                            if (decodedDuration > minDuration)
                                finished = YES;
                        }
                        
                    }
                }
                
                if (0 == len)
                    break;
                
                pktSize -= len;
                
            }
            
        } else if ( packet.stream_index == _artworkStream ) {
            
            if (packet.size) {
                GPArtworkFrame *frame = [[GPArtworkFrame alloc] init];
                frame.picture = [NSData dataWithBytes:packet.data length:packet.size];
                [result addObject:frame];
            }
            
        } else if (packet.stream_index == _subtitleStream) {
            
            int pktSize = packet.size;
            
            while (pktSize > 0) {
                
                AVSubtitle subtitle;
                int gotsubtitle = 0;
                int len = avcodec_decode_subtitle2(_subTitleContext,
                                                   &subtitle,
                                                   &gotsubtitle,
                                                   &packet);
                
                if (len < 0) {
                    GPLogWarn(@"subtitleStream -> decode subtitle error, skip packet");
                    break;
                }
                
                if (gotsubtitle) {
                    
                    GPSubtitleFrame *frame = [self handleSubtitle: &subtitle];
                    if (frame) {
                        [result addObject:frame];
                    }
                    avsubtitle_free(&subtitle);
                }
                
                if (0 == len)
                    break;
                
                pktSize -= len;
            }
        }
        
        av_free_packet(&packet);
    }
    
    return result;
}

@end

#pragma mark - static Function
static NSData * copyFrameData(UInt8 *src, int linesize, int width, int height)
{
    width = MIN(linesize, width);
    NSMutableData *md = [NSMutableData dataWithLength: width * height];
    Byte *dst = md.mutableBytes;
    for (NSUInteger i = 0; i < height; ++i) {
        memcpy(dst, src, width);
        dst += width;
        src += linesize;
    }
    return md;
}

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
//    GPLogStream(@"DEBUG: INTERRUPT_CALLBACK!");
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
