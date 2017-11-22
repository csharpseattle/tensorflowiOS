//
//  BoundingBoxView.h
//  tensorflowiOS
//
//  Created by Sharp, Chris T on 10/9/17.
//  Copyright © 2017 Apple. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface BoundingBoxView : UIView

@property (nonatomic) NSMutableArray* labels;

- (void) updateBoundingBoxes: (NSArray*) boxes;

@end
