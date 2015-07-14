//
//  GPPlayerController.h
//  GPPlayer
//
//  Created by apple on 15/7/13.
//  Copyright (c) 2015年 gpr. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface GPPlayerController : UIViewController

@property (nonatomic,copy) NSString *urlString;

- (instancetype)initWithURLString:(NSString *)urlString;

@end
