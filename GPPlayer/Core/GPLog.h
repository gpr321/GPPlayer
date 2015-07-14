//
//  GPLog.h
//  GPPlayer
//
//  Created by mac on 15/6/21.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#ifndef GPPlayer_GPLog_h
#define GPPlayer_GPLog_h

#ifdef DEBUG

//#define GPStreamLog(...) NSLog(@"Stream")

#define GPLogStream(...) NSLog(@"Stream Log %s %d %s %@",__FILE__,__LINE__,__FUNCTION__,[NSString stringWithFormat:__VA_ARGS__])

#define GPLogVideo(...) NSLog(@"Video Log %s %d %s %@",__FILE__,__LINE__,__FUNCTION__,[NSString stringWithFormat:__VA_ARGS__])

#define GPLogAudio(...) NSLog(@"Audio Log %s %d %s %@",__FILE__,__LINE__,__FUNCTION__,[NSString stringWithFormat:__VA_ARGS__])

#define GPLogWarn(...) NSLog(@"WARN!!!! Log %s %d %s %@",__FILE__,__LINE__,__FUNCTION__,[NSString stringWithFormat:__VA_ARGS__])

#else

#define GPStreamLog(...)

#define GPLogStream(...)

#define GPLogVideo(...)

#define GPLogAudio(...)

#define GPLogWarn(...)

#endif

#endif
