//
//  GPAudioManager.m
//  GPPlayer
//
//  Created by mac on 15/6/27.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import "GPAudioManager.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>
#import <TargetConditionals.h>
#import <AudioToolbox/AudioSession.h>
#import "GPLog.h"

#define MAX_FRAME_SIZE 4096
#define MAX_CHAN       2

#define MAX_SAMPLE_DUMPED 5

#pragma mark - private

// Debug: dump the current frame data. Limited to 20 samples.

#define dumpAudioSamples(prefix, dataBuffer, samplePrintFormat, sampleCount, channelCount) \
{ \
NSMutableString *dump = [NSMutableString stringWithFormat:prefix]; \
for (int i = 0; i < MIN(MAX_SAMPLE_DUMPED, sampleCount); i++) \
{ \
    for (int j = 0; j < channelCount; j++) \
    { \
        [dump appendFormat:samplePrintFormat, dataBuffer[j + i * channelCount]]; \
    } \
    [dump appendFormat:@"\n"]; \
    } \
    GPLogAudio(@"%@", dump); \
}

#define dumpAudioSamplesNonInterleaved(prefix, dataBuffer, samplePrintFormat, sampleCount, channelCount) \
{ \
    NSMutableString *dump = [NSMutableString stringWithFormat:prefix]; \
    for (int i = 0; i < MIN(MAX_SAMPLE_DUMPED, sampleCount); i++) \
    { \
        for (int j = 0; j < channelCount; j++) \
        { \
            [dump appendFormat:samplePrintFormat, dataBuffer[j][i]]; \
        } \
        [dump appendFormat:@"\n"]; \
    } \
    GPLogAudio(@"%@", dump); \
}


static BOOL checkError(OSStatus error, const char *operation);
static void sessoionPropertyListener ( void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void * inData);
static OSStatus renderCallback (void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *nTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *oData);

static void sessionInteruptionListener(void *inClientData, UInt32 inInterruptionState);

@interface GPAudioManagerImpl : GPAudioManager<GPAudioManager>
{
    float                                           *_outData;
    AudioUnit                                       _audioUnit;
    AudioStreamBasicDescription                     _outputFormat;
    
    BOOL                                            _active;
    BOOL                                            _inialized;
}

@property (readonly, nonatomic) UInt32              numOutputChannels;
@property (readonly, nonatomic) Float64             samplingRate;
@property (readonly, nonatomic) UInt32              numBytesPerSample;
@property (assign, nonatomic) Float32               outputVolume;
@property (readonly, nonatomic) BOOL                playing;
@property (readonly, strong) NSString               *audioRoute;
@property (assign, nonatomic) BOOL                  playAfterSessionEndInterruption;

@property (readwrite, copy) GPAudioManagerOutputBlock outputBlock;

- (BOOL) activateAudioSession;
- (void) deactivateAudioSession;
- (BOOL) play;
- (void) pause;

- (BOOL)checkAudioRoute;
- (BOOL) renderFrames: (UInt32) numFrames
               ioData: (AudioBufferList *) ioData;

@end

@implementation GPAudioManagerImpl

- (BOOL)checkAudioRoute{
    UInt32 propertySize = sizeof(CFStringRef);
    CFStringRef route;
    if ( checkError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &propertySize, &route), "Couldn't check the audio route") ) return NO;
    
    _audioRoute = CFBridgingRelease(route);
    GPLogAudio(@"AudioRoute: %@", _audioRoute);
    return YES;
}

- (BOOL)setUpAudio{
    // --- Audio Session Setup ---
    UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
    
    if ( checkError(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(sessionCategory), &sessionCategory), "Couldn't set audio category") ) {
        return NO;
    }
    
    if ( checkError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, sessoionPropertyListener, (__bridge void *)(self)), "Couldn't add audio session property listener") ) {
        // just warning
        return NO;
    }
    
    if ( checkError(AudioSessionAddPropertyListener(kAudioSessionProperty_CurrentHardwareOutputVolume,
                                                   sessoionPropertyListener,
                                                   (__bridge void *)(self)),
                   "Couldn't add audio session property listener") )
    {
        // just warning
    }
    
    // Set the buffer size, this will affect the number of samples that get rendered every time the audio callback is fired
    // A small number will get you lower latency audio, but will make your processor work harder
    
#if !TARGET_IPHONE_SIMULATOR
    Float32 preferredBufferSize = 0.0232;
    if (checkError(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration,
                                           sizeof(preferredBufferSize),
                                           &preferredBufferSize),
                   "Couldn't set the preferred buffer duration")) {
        
        // just warning
    }
#endif
    
    if (checkError(AudioSessionSetActive(YES),
                   "Couldn't activate the audio session"))
        return NO;
    [self checkProperties];
    
    // ----- Audio Unit Setup -----
    
    // Describe the output unit.
    AudioComponentDescription description = {0};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_RemoteIO;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Get component
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if ( checkError( AudioComponentInstanceNew(component, &_audioUnit) , "Couldn't create the output audio unit") ) {
        return NO;
    }
    
    // Check the output stream format
    UInt32 size = sizeof(AudioStreamBasicDescription);
    if ( checkError(AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputFormat, &size), "Couldn't get the hardware output stream format") ) {
        return NO;
    }
    
    _outputFormat.mSampleRate = _samplingRate;
    
    if ( checkError(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputFormat, size), "Couldn't set the hardware output stream format") ) {
        // just warning
    }
    
    _numBytesPerSample = _outputFormat.mBitsPerChannel / 8;
    _numOutputChannels = _outputFormat.mChannelsPerFrame;
    
    GPLogAudio(@"Current output bytes per sample: %u", (unsigned int)_numBytesPerSample);
    GPLogAudio(@"Current output num channels: %u", (unsigned int)_numOutputChannels);
    
    AURenderCallbackStruct callBackStruct;
    callBackStruct.inputProc = renderCallback;
    callBackStruct.inputProcRefCon = (__bridge void *)(self);
    
    if ( checkError(AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callBackStruct, sizeof(callBackStruct)), "Couldn't set the render callback on the audio unit") ) {
        return NO;
    }
    
    // Couldn't initialize the audio unit
    if ( checkError(AudioUnitInitialize(_audioUnit), "Couldn't initialize the audio unit") ) {
        return NO;
    }
    
    return YES;
}

- (BOOL)activateAudioSession{
    if ( !_active ) {
        if ( !_inialized ) {
            if ( checkError(AudioSessionInitialize(NULL, kCFRunLoopDefaultMode, sessionInteruptionListener, (__bridge void *)(self)), "could not inialized audio session") ) return NO;
            _inialized = YES;
            
            if ( [self checkAudioRoute] && [self setUpAudio] ) {
                _active = YES;
            }
        }
    }
    return _active;
}

- (void)deactivateAudioSession{
    if ( _active ) {
        [self pause];
        
        checkError(AudioUnitUninitialize(_audioUnit), "Couldn't uninitialize the audio unit");
        
        /*
         fails with error (-10851) ?
         
         checkError(AudioUnitSetProperty(_audioUnit,
                     kAudioUnitProperty_SetRenderCallback,
                     kAudioUnitScope_Input,
                     0,
                     NULL,
                     0),
                     "Couldn't clear the render callback on the audio unit");
         */
        
        checkError(AudioComponentInstanceDispose(_audioUnit), "Couldn't dispose the output audio unit");
        
        checkError(AudioSessionSetActive(NO), "Couldn't deactivate the audio session");
        
        checkError(AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange,
                   sessoionPropertyListener,
                   (__bridge void *)(self)),
                   "Couldn't remove audio session property listener");
        
        checkError(AudioSessionRemovePropertyListenerWithUserData   (kAudioSessionProperty_CurrentHardwareOutputVolume,
                   sessoionPropertyListener,
                    (__bridge void *)(self)),
                   "Couldn't remove audio session property listener");
        
        _active = NO;
    }
}

- (BOOL)play{
    if ( _playing ) {
        if ( [self activateAudioSession] ) {
            _playing = !checkError(AudioOutputUnitStart(_audioUnit), "Couldn't start the output unit");
        }
    }
    return _playing;
}

- (void)pause{
    if ( _playing ) {
        _playing = checkError(AudioOutputUnitStop(_audioUnit), "Couldn't stop the output unit");
    }
}

- (BOOL)renderFrames:(UInt32)numFrames ioData:(AudioBufferList *)ioData{
    for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }

    if ( _playing && _outputBlock ) {
        _outputBlock(_outData, numFrames, _numOutputChannels);
    }
    
    // http://www.filibeto.org/unix/macos/lib/dev/documentation/Performance/Reference/vDSP_Vector_Scalar_Arithmetic_Ops_Ref/vDSP_Vector_Scalar_Arithmetic_Ops_Ref.pdf
    if ( _numBytesPerSample == 4 ) {
        float zero = 0.0;
        for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers ; ++iBuffer) {
            int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
            
            for (int iChannel = 0; iChannel < thisNumChannels ; ++iChannel) {
                //
                vDSP_vsadd(_outData+iChannel, _numOutputChannels, &zero, (float *)ioData->mBuffers[iBuffer].mData, thisNumChannels, numFrames);
            }
        }
    } else if ( _numBytesPerSample == 2 ) { // then we need to convert SInt16 -> Float (and also scale)
        float scale = (float)INT16_MAX;
        vDSP_vsmul(_outData, 1, &scale, _outData, 1, numFrames*_numOutputChannels);
#ifdef DUMP_AUDIO_DATA
        GPLogAudio(@"Buffer %u - Output Channels %u - Samples %u",
                   (uint)ioData->mNumberBuffers, (uint)ioData->mBuffers[0].mNumberChannels, (uint)numFrames);
#endif
        
        for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
            int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
            
            for (int iChannel = 0; iChannel < thisNumChannels; ++iChannel) {
                vDSP_vfix16(_outData + iChannel, _numOutputChannels, (SInt16 *)ioData->mBuffers[iBuffer].mData, thisNumChannels, numFrames);
            }
            
#ifdef DUMP_AUDIO_DATA
            dumpAudioSamples(@"Audio frames decoded by FFmpeg and reformatted:\n",
                             ((SInt16 *)ioData->mBuffers[iBuffer].mData),
                             @"% 8d ", numFrames, thisNumChannels);
#endif
        }
    }
    
    return noErr;
}

- (BOOL)checkProperties{
    [self checkAudioRoute];
    
    // Check the number of output channels.
    UInt32 newNumChannels;
    UInt32 size = sizeof(newNumChannels);
    if ( checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputNumberChannels, &size, &newNumChannels), "Checking number of output channels") ) {
        return NO;
    }
    GPLogAudio(@"We've got %u output channels", (unsigned int)newNumChannels);
    
    size = sizeof(_samplingRate);
    if ( checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &_samplingRate), "Checking hardware sampling rate") ) {
        return NO;
    }
    GPLogAudio(@"Current sampling rate: %f", _samplingRate);
    
    size = sizeof(_outputVolume);
    if ( checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputVolume, &size, &_outputVolume), "Checking current hardware output volume") ) {
        return NO;
    }
    GPLogAudio(@"Current output volume: %f", _outputVolume);
    return YES;
}

- (instancetype)init{
    if ( self = [super init] ) {
        _outData = (float *)calloc(MAX_FRAME_SIZE * MAX_CHAN, sizeof(float));
        _outputVolume = 0.5;
    }
    return self;
}

- (void)dealloc{
    if ( _outData ) {
        free(_outData);
        _outData = NULL;
    }
}

@end

@implementation GPAudioManager

+ (id<GPAudioManager>)audioManager{
    static GPAudioManagerImpl *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GPAudioManagerImpl alloc] init];
    });
    return instance;
}

@end

static OSStatus renderCallback (void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *nTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *oData) {
    GPAudioManagerImpl *instance = (__bridge GPAudioManagerImpl *)(inRefCon);
    return [instance renderFrames:inNumberFrames ioData:oData];
}

static void sessoionPropertyListener ( void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void * inData){
    GPAudioManagerImpl *instance = (__bridge GPAudioManagerImpl *)(inClientData);
    if ( inID == kAudioSessionProperty_AudioRouteChange ) {
        if ( [instance checkAudioRoute] ) {
            [instance checkProperties];
        }
    } else if ( inID == kAudioSessionProperty_CurrentHardwareOutputVolume ) {
        if ( inData && inDataSize == 4 ) {
            instance.outputVolume = *((float *)inData);
        }
    }
}

static void sessionInteruptionListener(void *inClientData, UInt32 inInterruptionState) {
    GPAudioManagerImpl *instance = (__bridge GPAudioManagerImpl *)(inClientData);
    if ( inInterruptionState == kAudioSessionBeginInterruption ) {
        GPLogAudio(@"Begin interuption");
        instance.playAfterSessionEndInterruption = instance.playing;
        [instance pause];
    } else if ( inInterruptionState == kAudioSessionEndInterruption ) {
        GPLogAudio(@"End interuption");
        if ( instance.playAfterSessionEndInterruption ) {
            instance.playAfterSessionEndInterruption = NO;
            [instance play];
        }
    }
}

static BOOL checkError(OSStatus error, const char *operation) {
    if ( error == noErr ) return NO;
    char str[20] = {0};
    // see if it appears to be a 4-char-code
    *(UInt32 *)(str + 1) = CFSwapInt32HostToBig(error);
    if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
        str[0] = str[5] = '\'';
        str[6] = '\0';
    } else
        // no, format it as an integer
        sprintf(str, "%d", (int)error);
    GPLogAudio(@"Error: %s (%s)\n", operation, str);
    
    //exit(1);
    
    return YES;
}
