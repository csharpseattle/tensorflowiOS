
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <CoreVideo/CoreVideo.h>


@interface TensorflowGraph : NSObject

- (id) init;
- (void)runModelOnPixelBuffer:(CVPixelBufferRef) pixelBuf orientation: (UIDeviceOrientation) orientation;

@end
