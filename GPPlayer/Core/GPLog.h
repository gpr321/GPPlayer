//
//  GPLog.h
//  GPPlayer
//
//  Created by mac on 15/6/21.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#ifndef GPPlayer_GPLog_h
#define GPPlayer_GPLog_h

#define GPStreamLog(...) NSLog(@"Stream")


//#    define GPLogStream(level, ...)   LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Stream", level, __VA_ARGS__)
//#    define GPLogVideo(level, ...)    LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Video",  level, __VA_ARGS__)
//#    define GPLogAudio(level, ...)    LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Audio",  level, __VA_ARGS__)

#define GPLogStream(...) NSLog(@"Stream Log %s %d %s %@",__FILE__,__LINE__,__FUNCTION__,[NSString stringWithFormat:__VA_ARGS__])
#define GPLogVideo(...) NSLog(@"Video Log %s %d %s %@",__FILE__,__LINE__,__FUNCTION__,[NSString stringWithFormat:__VA_ARGS__])
#define GPLogAudio(...) NSLog(@"Audio Log %s %d %s %@",__FILE__,__LINE__,__FUNCTION__,[NSString stringWithFormat:__VA_ARGS__])
#define GPLogWarn(...) NSLog(@"WARN!!!! Log %s %d %s %@",__FILE__,__LINE__,__FUNCTION__,[NSString stringWithFormat:__VA_ARGS__])


//#ifdef USE_NSLOGGER
//
//#    import "NSLogger.h"
//#    define GPLogStream(level, ...)   LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Stream", level, __VA_ARGS__)
//#    define GPLogVideo(level, ...)    LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Video",  level, __VA_ARGS__)
//#    define GPLogAudio(level, ...)    LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Audio",  level, __VA_ARGS__)
//
//#else
//
//#    define GPLogStream(level, ...)
//#    define GPLogVideo(level, ...)
//#    define GPLogAudio(level, ...)
//
//#endif
//#else
//
//#    define LoggerStream(...)          while(0) {}
//#    define LoggerVideo(...)           while(0) {}
//#    define LoggerAudio(...)           while(0) {}



#endif
