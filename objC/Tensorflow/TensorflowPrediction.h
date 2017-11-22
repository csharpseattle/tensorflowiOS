//
//  TensorflowPrediction.h
//  tensorflowiOS
//
//  Created by Sharp, Chris T on 10/9/17.
//  Copyright © 2017 Apple. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface TensorflowPrediction : NSObject
@property (nonatomic) NSString *label;
@property (nonatomic) UIImage *image;
@property (nonatomic) float score;
@property (nonatomic) float top;
@property (nonatomic) float left;
@property (nonatomic) float right;
@property (nonatomic) float bottom;
@end
