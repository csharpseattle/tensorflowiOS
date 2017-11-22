
#import <UIKit/UIKit.h>

@class AVCaptureSession;

@interface CameraPreviewView : UIView
@property (nonatomic, readonly) AVCaptureVideoPreviewLayer *videoPreviewLayer;

- (void) configureSession;
- (void) startSessionWithDelegate: (id<AVCaptureVideoDataOutputSampleBufferDelegate>) delegate;
- (void) stopSession;
@end
