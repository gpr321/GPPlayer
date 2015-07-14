//
//  ViewController.m
//  GPPlayer
//
//  Created by mac on 15/6/21.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import "ViewController.h"
#import "GPPlayer.h"


@interface ViewController () <GPPlayerDelegate>

@property (nonatomic,strong) GPPlayer *player;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *urlString = @"http://118.26.135.133:80/media/hls/DvbR1tvdsdxe.m3u8";
    GPPlayer *player = [[GPPlayer alloc] initWithURLString:urlString targetView:self.view];
    self.player = player;
    player.delegate = self;
}

- (void)viewDidAppear:(BOOL)animated{
    [super viewDidAppear:animated];
    [self.player prepare];
}

#pragma mark - GPPlayerDelegate
- (void)player:(GPPlayer *)player stateDidChanged:(GPPlayerState)state withParams:(NSDictionary *)params{
    switch ( state ) {
        case GPPlayerStatePrepared:
            [player play];
            break;
            
        default:
            break;
    }
}

@end
