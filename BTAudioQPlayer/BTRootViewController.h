//
//  BTRootViewController.h
//  BTAudioQPlayer
//
//  Created by Gary on 12-10-7.
//  Copyright (c) 2012年 Gary. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface BTRootViewController : UIViewController<UITableViewDataSource,UITableViewDelegate> {
    NSMutableArray *_musicList;
}

@end
