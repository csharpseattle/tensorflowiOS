#import <AVFoundation/AVFoundation.h>
#import "ViewController.h"
#import "CameraPreviewView.h"
#import "TensorflowGraph.h"
#import "constants.h"
#import "TensorflowPrediction.h"
#import "BoundingBoxView.h"
#import "tensorflowUtils.h"

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>

//    The view of what the camera is currently capturing
@property (nonatomic, weak) IBOutlet CameraPreviewView *cameraPreviewView;

//    the transparent UIView where we draw the bounding boxes.  This view
// sits on top of the CameraPreview
@property (nonatomic, weak) IBOutlet BoundingBoxView   *boundingBoxView;

//    the tensorflow graph that will do the recognizing.
@property (nonatomic) TensorflowGraph                  *tensorflowGraph;

//    Label to alert the user if the camera is unavailable.
@property (nonatomic, weak) IBOutlet UILabel           *cameraUnavailableLabel;

// processingTime and framesProcessed are used for keeping an average time to make predictions.
@property (nonatomic) double processingTime;
@property (nonatomic) int    framesProcessed;

@end


@implementation ViewController


#pragma mark View Controller Life Cycle

- (void)viewDidLoad
{
	[super viewDidLoad];

    //
    // Configure the video preview.  We will grab frames
    // from the video preview and feed them into the tensorflow graph.
    // Then bounding boxes can be rendered onto the boundingBoxView.
    //
    [self.cameraPreviewView configureSession];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];

    //
    // Listen for the start of the AVSession.  This will signal the start
    // of the delivery of video frames and will trigger the
    // initialization of the tensorflow graph
    //
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(OnAVSessionStarted:) name:kAVSessionStarted object:nil];

    //
    // Also Listen for Session initialization failure or for when
    // the user doesn't authorize the use of the camera
    //
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(OnSetupResultCameraNotAuthorized:) name:kSetupResultCameraNotAuthorized object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(OnSetupResultSessionConfigurationFailed:) name:kSetupResultSessionConfigurationFailed object:nil];

    //
    // Respond to the tensorflow graph's update of predictions.  This will
    // trigger the redrawing of the bounding boxes.
    //
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(OnPredictionsUpdated:) name:kPredictionsUpdated object:nil];

    //
    // Start the AV Session. This will prompt the user for
    // permission to use the camera to present a video preview.
    //
    [self.cameraPreviewView startSessionWithDelegate:self];
 }

//
// when the view disappears we shut down the session.  It will be restarted in ViewWillAppear
//
- (void)viewDidDisappear:(BOOL)animated
{
    [self.cameraPreviewView stopSession];
	[super viewDidDisappear:animated];
}

//
// Yes, please autorotate, but we will have to change the orientation of the pixel buffer when we run the graph.
//
- (BOOL)shouldAutorotate
{
    return YES;
}

//
// Supporting only landscape.
//
- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskLandscape;
}


//
// Override viewWillTransitionToSize so that we can update the videoPreviewLayer with the new orientation.
//
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    //
    // call super so the coordinator can be passed on.
    //
	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

    //
    // ignore everything but landscape orientation changes.
    //
	UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
	if ( UIDeviceOrientationIsLandscape(deviceOrientation) )
    {
		self.cameraPreviewView.videoPreviewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)deviceOrientation;
	}
}

#pragma mark - Video Preview delegate


//
// Delegate function from the AVSession.  Here we capture frames from
// the video preview and feed them to tensorflow.
//
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    // If the graph is ready, run the frame through tensorflow
    if (self.tensorflowGraph)
    {
        //
        // if it is not busy pass the pixel buffer off to the tensorflow graph
        //
        if ([self.tensorflowGraph canProcessFrame])
        {
            //
            // Grab the pixel buffer.  We pass it to the tf graph which will retain, copy and release
            //
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            [self.tensorflowGraph runModelOnPixelBuffer:pixelBuffer orientation:[UIDevice currentDevice].orientation];
        }
     }
}

//
// Will be called when frames are dropped by the Video Output delegate.
//
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    //CFTypeRef droppedFrameReason = CMGetAttachment(sampleBuffer, kCMSampleBufferAttachmentKey_DroppedFrameReason, NULL);
    //NSLog(@"dropped frame, reason: %@", droppedFrameReason);
}


#pragma mark - NS_NOTIFICATIONS

//
// Notification that the AV Session has started.  Since we now have a camera session
// it is safe to alloc a tensorflowGraph object.
//
- (void) OnAVSessionStarted: (NSNotification*) notification
{
    // Now that the user has granted permission to the camera
    // and we have a video session we can initialize our graph.
    if (!self.tensorflowGraph)
    {
        self.tensorflowGraph = [[TensorflowGraph alloc] init];
    }
}

//
// The tensorflow graph has analyzed the pixel buffer coming out of the CameraPreview
// and resulted in new predictions and bounding boxes. We notify the boundingBoxView to
// draw the boxes over the CameraPreview.
//
- (void) OnPredictionsUpdated: (NSNotification*) notification
{
    NSDictionary * dict = [notification userInfo];
    if (dict)
    {
        // Update the Bounding boxes and labels from the
        // new predictions coming out of the graph.
        NSArray * predictions = dict[@"predictions"];
        if (predictions)
        {
            [self.boundingBoxView updateBoundingBoxes:predictions];
        }
    }
}


//
// Notification that the camera has not been authorized.  Without camera permissions
// we will not have a preview and won't alloc a Tensorflow graph. Post an alertBox
// and give the user a short cut to the settings app.
//
- (void) OnSetupResultCameraNotAuthorized: (NSNotification *) notification
{
    dispatch_async( dispatch_get_main_queue(), ^{
        NSString *message = NSLocalizedString( @"In order to display a video preview we need to use the camera, please change privacy settings", @"Alert message when the user has denied access to the camera" );
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"tensorflowiOS" message:message preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
        [alertController addAction:cancelAction];
        // Provide quick access to Settings.
        UIAlertAction *settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"Settings", @"Alert button to open Settings" ) style:UIAlertActionStyleDefault handler:^( UIAlertAction *action ) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
        }];
        [alertController addAction:settingsAction];
        [self presentViewController:alertController animated:YES completion:nil];
    } );
}

//
// Configuration of the AV session failed.  For some reason the AVSession has failed to
// initialize.  Post an alert.
//
- (void) OnSetupResultSessionConfigurationFailed: (NSNotification *) notification
{
    dispatch_async( dispatch_get_main_queue(), ^{
        NSString *message = NSLocalizedString( @"Unable to capture media", @"Alert message when something goes wrong during capture session configuration" );
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"tensorflowiOS" message:message preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
        [alertController addAction:cancelAction];
        [self presentViewController:alertController animated:YES completion:nil];
    } );
}
@end
