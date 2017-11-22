
#import <AVFoundation/AVFoundation.h>

#import "CameraPreviewView.h"
#import "constants.h"

static void * SessionRunningContext = &SessionRunningContext;

typedef NS_ENUM( NSInteger, CameraSetupResult )
{
    SetupResultSuccess,
    SetupResultCameraNotAuthorized,
    SetupResultSessionConfigurationFailed
};

@interface AVCaptureDeviceDiscoverySession (Utilities)

- (NSInteger)uniqueDevicePositionsCount;

@end

@implementation AVCaptureDeviceDiscoverySession (Utilities)

- (NSInteger)uniqueDevicePositionsCount
{
    NSMutableArray<NSNumber *> *uniqueDevicePositions = [NSMutableArray array];
    
    for ( AVCaptureDevice *device in self.devices )
    {
        if ( ! [uniqueDevicePositions containsObject:@(device.position)] )
        {
            [uniqueDevicePositions addObject:@(device.position)];
        }
    }
    
    return uniqueDevicePositions.count;
}

@end

@interface CameraPreviewView()
@property (nonatomic) CameraSetupResult               cameraSetupResult;
@property (nonatomic) AVCaptureSession                *avSession;
@property (nonatomic) dispatch_queue_t                sessionQueue;
@property (nonatomic) dispatch_queue_t                videoFrameSerialQueue;
@property (nonatomic, getter=isSessionRunning) BOOL   sessionRunning;
@property (nonatomic) AVCaptureDeviceInput            *videoDeviceInput;
@property (nonatomic) AVCaptureVideoDataOutput        *videoDataOutput;
@end

@implementation CameraPreviewView

+ (Class)layerClass
{
	return [AVCaptureVideoPreviewLayer class];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self)
    {
        [self setupSession];
    }
    return self;

}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        [self setupSession];
    }
    return self;
}

#pragma mark Session Management


- (AVCaptureVideoPreviewLayer *)videoPreviewLayer
{
    return (AVCaptureVideoPreviewLayer *)self.layer;
}

- (AVCaptureSession *)session
{
    return self.videoPreviewLayer.session;
}

- (void)setSession:(AVCaptureSession *)session
{
    self.videoPreviewLayer.session = session;
}

- (void) setupSession
{
    self.avSession = [[AVCaptureSession alloc] init];

    self.videoPreviewLayer.session = self.avSession;
    
    //
    // Communicate with the session and other session objects on this queue.
    //
    self.sessionQueue = dispatch_queue_create( "PreviewSessionQueue", DISPATCH_QUEUE_SERIAL );
    
    // We use a serial queue for the video frames so that
    // they are dispatched in the order that they are captured
    self.videoFrameSerialQueue = dispatch_queue_create("VideoFrameQueue", DISPATCH_QUEUE_SERIAL);
    
    self.cameraSetupResult = SetupResultSuccess;
    
    //Check video authorization status. Video access is required.
    switch ( [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] )
    {
        case AVAuthorizationStatusAuthorized:
        {
            // The user has previously granted access to the camera.
            break;
        }
        case AVAuthorizationStatusNotDetermined:
        {
            /*
             The user has not yet been presented with the option to grant
             video access. We suspend the session queue to delay session
             setup until the access request has completed.
             */
            dispatch_suspend( self.sessionQueue );
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^( BOOL granted ) {
                if ( ! granted )
                {
                    self.cameraSetupResult = SetupResultCameraNotAuthorized;
                }
                dispatch_resume( self.sessionQueue );
            }];
            break;
        }
        default:
        {
            // The user has previously denied access.
            self.cameraSetupResult = SetupResultCameraNotAuthorized;
            break;
        }
    }
}

// Call this on the session queue.
- (void)configureSession
{
    dispatch_async( self.sessionQueue, ^{
        if ( self.cameraSetupResult != SetupResultSuccess )
        {
            return;
        }
        
        [self.avSession beginConfiguration];
        self.avSession.sessionPreset = AVCaptureSessionPresetLow;
        
        // Add video input.
        
        // Choose the back dual camera if available, otherwise default to a wide angle camera.
        AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInDualCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
        if ( ! videoDevice )
        {
            // If the back dual camera is not available, default to the back wide angle camera.
            videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
            
            // In some cases where users break their phones, the back wide angle camera is not available. In this case, we should default to the front wide angle camera.
            if ( ! videoDevice )
            {
                videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront];
            }
        }

        // Set the frame rate to 15fps max on the video preview.
        [videoDevice lockForConfiguration:nil];
        [videoDevice setActiveVideoMaxFrameDuration:CMTimeMake(1,15)];
        [videoDevice unlockForConfiguration];
        
        NSError *error = nil;
        AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
        if ( ! videoDeviceInput )
        {
            NSLog( @"Could not create video device input: %@", error );
            self.cameraSetupResult = SetupResultSessionConfigurationFailed;
            [self.avSession commitConfiguration];
            return;
        }
        if ( [self.avSession canAddInput:videoDeviceInput] )
        {
            [self.avSession addInput:videoDeviceInput];
            self.videoDeviceInput = videoDeviceInput;
            
            dispatch_async( dispatch_get_main_queue(), ^{
                // Dispatching this to the main queue because a UIView (CameraPreviewView) can only be
                // changed on the main thread.
                UIInterfaceOrientation statusBarOrientation = [UIApplication sharedApplication].statusBarOrientation;
                AVCaptureVideoOrientation initialVideoOrientation = AVCaptureVideoOrientationPortrait;
                if ( statusBarOrientation != UIInterfaceOrientationUnknown )
                {
                    initialVideoOrientation = (AVCaptureVideoOrientation)statusBarOrientation;
                }
                
                self.videoPreviewLayer.connection.videoOrientation = initialVideoOrientation;
            } );
        }
        else
        {
            NSLog( @"Could not add video device input to the session" );
            self.cameraSetupResult = SetupResultSessionConfigurationFailed;
            [self.avSession commitConfiguration];
            return;
        }
        
        [self addVideoOutput];
        
        [self.avSession commitConfiguration];
    } );
}

- (void) addVideoOutput
{
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    
    //
    // We use the 32 bit BGRA pixel format type.  That way we can just pass the data to
    // Tensorflow without pre-processing.
    //
    NSDictionary *newSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    videoOutput.videoSettings = newSettings;
    videoOutput.alwaysDiscardsLateVideoFrames = YES;
    
    //
    // Add the videoOutput to our AVSession
    //
    if ( [self.avSession canAddOutput:videoOutput] )
    {
        [self.avSession beginConfiguration];
        [self.avSession addOutput:videoOutput];
        self.avSession.sessionPreset = AVCaptureSessionPresetHigh;
        AVCaptureConnection *connection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
        if ( connection.isVideoStabilizationSupported )
        {
            connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
        }
        
        [self.avSession commitConfiguration];
        
        self.videoDataOutput = videoOutput;
    }
}

- (void) startSessionWithDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>) delegate
{
    dispatch_async( self.sessionQueue, ^{
        switch ( self.cameraSetupResult )
        {
            case SetupResultSuccess:
            {
                // if setup succeeded we can add Observers and frame delegate
                // and run the session.
                [self addObservers];
                [self.videoDataOutput setSampleBufferDelegate:delegate queue:self.videoFrameSerialQueue];

                [self.avSession startRunning];
                self.sessionRunning = self.avSession.isRunning;

                // Let everyone know we have a session.
                [[NSNotificationCenter defaultCenter] postNotificationName:kAVSessionStarted object:nil];
                break;
            }
            case SetupResultCameraNotAuthorized:
            {
                [[NSNotificationCenter defaultCenter] postNotificationName:kSetupResultCameraNotAuthorized object:nil];
                 break;
            }
            case SetupResultSessionConfigurationFailed:
            {
                [[NSNotificationCenter defaultCenter] postNotificationName:kSetupResultSessionConfigurationFailed object:nil];
                break;
            }
        }
    } );
}

- (void) stopSession
{
    dispatch_async( self.sessionQueue, ^{
        if ( self.cameraSetupResult == SetupResultSuccess )
        {
            [self.avSession stopRunning];
            [self removeObservers];
        }
    } );
}

#pragma mark KVO and Notifications

- (void)addObservers
{
    [self.avSession addObserver:self forKeyPath:@"running" options:NSKeyValueObservingOptionNew context:SessionRunningContext];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self.avSession];
}

- (void)removeObservers
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self.avSession removeObserver:self forKeyPath:@"running" context:SessionRunningContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ( context == SessionRunningContext )
    {
        self.sessionRunning = [change[NSKeyValueChangeNewKey] boolValue];
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


- (void)sessionRuntimeError:(NSNotification *)notification
{
    NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
    NSLog( @"Capture session runtime error: %@", error );
    
    /*
     Automatically try to restart the session running if media services were
     reset and the last start running succeeded. Otherwise, enable the user
     to try to resume the session running.
     */
    if ( error.code == AVErrorMediaServicesWereReset )
    {
        dispatch_async( self.sessionQueue, ^{
            if ( self.isSessionRunning )
            {
                [self.avSession startRunning];
                self.sessionRunning = self.avSession.isRunning;
            }
        } );
    }
}

@end
