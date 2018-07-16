//
//  BoundingBoxView.m
//  tensorflowiOS
//
//  Created by Sharp, Chris T on 10/9/17.
//  Copyright © 2017 Apple. All rights reserved.
//

#import "BoundingBoxView.h"
#import "TensorflowPrediction.h"

const CGFloat BoundingBoxLineWidth = 3.5f;

@interface BoundingBoxView()
@property (nonatomic) NSArray *boxesToBeErased;
@property (nonatomic) NSArray *boxesToBeDrawn;
@end

@implementation BoundingBoxView

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self)
    {
        //
        // Maintain a list of UILabels for easy removal from superView.
        //
        self.labels = [[NSMutableArray alloc] init];
    }
    return self;
}


//
// in drawRect we have a clear UIView that we draw green bounding boxes on.
// As a new list of boundingboxes comes in we erase the old boxes and draw the new ones.
// Since this view is just a layer over the videoPreview the bounding boxes could be a few
// frames behind and the box will not align with the object underneath it.  This will likely
// be an issue until Tensorflow processing is as fast as the video preview's frame capture.
//
- (void)drawRect:(CGRect)rect
{
    //
    // Our drawing context
    //
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    //
    // The width of the bounding box lines.
    //
    CGContextSetLineWidth(context, BoundingBoxLineWidth);
    
    //
    // The fill color of the bounding box is always clear
    //
    CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 0.0);

    //
    // Erase boxes from the previous frame
    //
    if (self.boxesToBeErased)
    {
        for (TensorflowPrediction* pred in self.boxesToBeErased)
        {
            // Erase the previous bounding box by using a clear stroke color
            CGContextSetRGBStrokeColor(context, 1.0, 1.0, 1.0, 0.0);

            // Calculate box dimensions of box to be erased.
            CGFloat x = pred.left    * self.frame.size.width;
            CGFloat y = pred.top     * self.frame.size.height;
            CGFloat w = (pred.right  * self.frame.size.width)  - x;
            CGFloat h = (pred.bottom * self.frame.size.height) - y;
            CGRect rectangle = CGRectMake(x, y, w, h);

            //Erase it. (draw clear pixels over the green)
            CGContextFillRect(context, rectangle);
            CGContextStrokeRect(context, rectangle);
        }
        
        //
        // Remove existing labels too.
        //
        for (UILabel * label in self.labels)
        {
            [label removeFromSuperview];
        }
        [self.labels removeAllObjects];
        self.boxesToBeErased = nil;
    }

    //
    // Draw newly predicted boxes
    //
    for (TensorflowPrediction* pred in self.boxesToBeDrawn)
    {
        //
        // Calculate the box dimensions.  The box dimensions are given
        // as normalized values. Because this view has the same dimensions
        // as the original image multiplying by width and height gives the
        // correct location for the bounding box.
        //
        CGFloat x = pred.left    * self.frame.size.width;
        CGFloat y = pred.top     * self.frame.size.height;
        CGFloat w = (pred.right  * self.frame.size.width)  - x;
        CGFloat h = (pred.bottom * self.frame.size.height) - y;
        CGRect rectangle = CGRectMake(x, y, w, h);

        // Draw with a green stroke.
        CGContextSetRGBStrokeColor(context, 0.0, 1.0, 0.0, 0.75);
        CGContextFillRect(context, rectangle);
        CGContextStrokeRect(context, rectangle);
        
        // Add the label to the upper left of the bounding box
        UILabel * label = [[UILabel alloc] initWithFrame:CGRectMake(x, y, 75, 35)];
        [label setBackgroundColor:[UIColor whiteColor]];
        [label setTextColor:[UIColor orangeColor]];
        [label setText:[NSString stringWithFormat:@"%@ %.1f%%", pred.label, pred.score * 100]];
        [label sizeToFit];
        [self addSubview:label];
        
        //
        // Keep a list of labels so we can easily remove from superview.
        //
        [self.labels addObject:label];
    }
}

- (void) updateBoundingBoxes: (NSArray*) boxes
{
    //
    // flag the old boxes to be erased and flag the new to be drawn.
    //
    self.boxesToBeErased = self.boxesToBeDrawn;
    self.boxesToBeDrawn = boxes;

    //
    // trigger a drawRect call next frame
    //
    [self setNeedsDisplay];
}

@end
