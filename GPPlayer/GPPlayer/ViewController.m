//
//  ViewController.m
//  GPPlayer
//
//  Created by mac on 15/6/21.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import "ViewController.h"
#import "GPDecoder.h"
#import "GPAudioManager.h"

@interface ViewController ()

@property (nonatomic,strong) GPDecoder *decoder;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    GPDecoder *decoder = [[GPDecoder alloc] init];
    self.decoder = decoder;
    [[GPAudioManager audioManager] activateAudioSession];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [decoder openURLString:@"http://118.26.135.134/media/test/out.m3u8" error:NULL];
    });
}



@end
