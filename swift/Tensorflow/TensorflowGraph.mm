
#import "TensorflowGraph.h"
#import <CoreImage/CoreImage.h>
#import "TensorflowUtils.h"
#import "TensorflowPrediction.h"
#include <time.h>
#import "tensorflow/core/public/session.h"
#import "tensorflow/core/util/memmapped_file_system.h"
#include "string_int_label_map.pb.h"


const int kGraphChannels         = 3;    // BGR.
const int kGraphImageWidth       = 299;  // The width of the pixels going into the graph.
const int kGraphImageHeight      = 299;  // the height of the pixels going into the graph.
const float kPredictionThreshold = 0.65; // Prediction percentages lower than this will be discarded.
const int kGraphMaxPredictions   = 10;   // After this many predictions we move on.
const int kAverageEveryXFrames   = 50;   // Output average processing time every X frames

@interface TensorflowGraph()
{
    std::unique_ptr<tensorflow::Session>        tfSession;
    object_detection::protos::StringIntLabelMap labelMap;
}

//
// processingTime and framesProcessed are used for keeping an average time to make predictions.
//
@property (nonatomic) double processingTime;
@property (nonatomic) int    framesProcessed;

// Keep a load status - if loading fails we don't want to attempt to run
// anything through a non-existent graph.
@property (nonatomic) tensorflow::Status loadStatus;
@property (nonatomic) tensorflow::Status labelStatus;
@property (nonatomic) BOOL isProcessingFrame;

@end


@implementation TensorflowGraph

- (id) init
{
    self = [super init];
    if (self)
    {
        // change model name here to use one of the other models.
        NSString *model = @"frozen_inference_graph";
        NSString *label = @"mscoco_label_map";
        
        if (![self loadModelWithFileName:model modelFileType:@"pb"])
        {
            NSLog(@"Failed to load model");
        }
        
        if (![self loadLabelsWithFileName:label labelsFileType:@"txt"])
        {
            NSLog(@"Failed to load labels");
        }
    }
    return self;
}

- (BOOL)loadModelWithFileName:(NSString *)modelFileName modelFileType:(NSString *)modelFileType
{
    self.loadStatus = loadModel(modelFileName, modelFileType, &tfSession);
    return self.loadStatus.ok();
}

- (BOOL)loadLabelsWithFileName:(NSString *)labelsFileName labelsFileType:(NSString *)labelsFileType
{
    //
    // load the labels from the file.  labelMap is populated by calling loadLabels.
    self.labelStatus = loadLabels(labelsFileName, labelsFileType, &labelMap);
    return self.labelStatus.ok();
}

- (BOOL) canProcessFrame
{
    return (!self.isProcessingFrame);
}

//
// PixelBufferToCGImage
// pixelBuffer --- the pixel buffer obtained from the device camera
// orientation --- the orientation of the device.
//
// This method retains the CVPixelBuffer, copies it, and applies rotations and scaling
// necessary before feeding the image data into the Tensorflow Graph.
//
- (CGImageRef) pixelBufferToCGImage: (CVImageBufferRef) pixelBuffer orientation: (UIDeviceOrientation) orientation
{
    CFRetain(pixelBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    //
    // alloc a CIImage with the pixel buffer.
    //
    CIImage* ciImage = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffer];

    //
    // figure the angle of rotation and the scaling of the pixel buffer
    // based on the current orientation of the device.
    //
    const int pixelBufHeight   = (int) CVPixelBufferGetHeight(pixelBuffer);
    const int pixelBufWidth    = (int) CVPixelBufferGetWidth(pixelBuffer);
    CGAffineTransform transform = CGAffineTransformIdentity;
    CGFloat angle = 0.0;
    switch (orientation)
    {
        case UIDeviceOrientationPortrait:
        {
            angle = -M_PI_2;
            transform = CGAffineTransformScale(transform, float(kGraphImageHeight)/pixelBufHeight, float(kGraphImageWidth)/pixelBufWidth);
        }
            break;
        case UIDeviceOrientationPortraitUpsideDown:
        {
            angle = M_PI_2;
            transform = CGAffineTransformScale(transform, float(kGraphImageHeight)/pixelBufHeight, float(kGraphImageWidth)/pixelBufWidth);
        }
            break;
        case UIDeviceOrientationLandscapeLeft:
        {
            angle = -M_PI;
            transform = CGAffineTransformScale(transform, float(kGraphImageWidth)/pixelBufWidth, float(kGraphImageHeight)/pixelBufHeight);
        }
            break;
        case UIDeviceOrientationLandscapeRight:
        {
            angle = 0.0;
            transform = CGAffineTransformScale(transform, float(kGraphImageWidth)/pixelBufWidth, float(kGraphImageHeight)/pixelBufHeight);
        }
            break;
        case UIDeviceOrientationUnknown:
        case UIDeviceOrientationFaceUp:
        case UIDeviceOrientationFaceDown:
        default:
            angle = 0.0;
            transform = CGAffineTransformScale(transform, float(kGraphImageWidth)/pixelBufWidth, float(kGraphImageHeight)/pixelBufHeight);
            break;
    }

    //
    // Apply the transforms
    //
    transform = CGAffineTransformRotate(transform, angle);
    CIImage* resized = [ciImage imageByApplyingTransform:transform];
    
    //
    // Create a cgImage from the frame pixels
    //
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:resized fromRect:resized.extent];

    //
    // We are done with the pixel buffer, release it.
    //
    CFRelease(pixelBuffer);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    //
    // This cgImage is released after using it to populate the Tensor
    //
    return cgImage;
}


//
// createDebugImage
// srcData -- pointer to image pixel data.
// width   -- pixel width of the image.
// height  -- pixel height of the image.
//
// This method is useful for debuging the image data immediately before going into
// the TF graph.  Given a pointer to the pixel data this method will add an alpha
// channel and convert the raw image data into a UIImage.  The UIImage will be
// broadcast to any listeners for easy display in a UIView.
//
- (void) createDebugImage: (unsigned char*) srcData width: (size_t) width height: (size_t) height
{
    //
    // Create a destination array for the cgImage pixel data
    //
    const size_t srcChannels = kGraphChannels;
    const size_t dstChannels = 4;
    const size_t numBytes = width * height * dstChannels;
    unsigned char pixelData[numBytes];
    unsigned char * destPixels = pixelData;

    //
    // Copy into the destination array, adding the alpha channel.
    // Since the raw image data comes as BGR and we want RGB we
    // flip the blue and red channels.  Alpha is added as opaque.
    //
    size_t i = 0;
    while (i < (width * height * srcChannels))
    {
        *destPixels++ = srcData[i+2];
        *destPixels++ = srcData[i+1];
        *destPixels++ = srcData[i];
        *destPixels++ = UINT8_MAX;
        i += srcChannels;
    }
    
    //
    // Create the bitmap context
    //
    const size_t BitsPerComponent = 8;
    const size_t BytesPerRow = width * dstChannels;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef cxt = CGBitmapContextCreate(&pixelData[0], width, height, BitsPerComponent, BytesPerRow, colorSpace, kCGImageAlphaNoneSkipLast);
    
    //
    // create the CGImage and UIImage from the context
    //
    CGImageRef cgImage = CGBitmapContextCreateImage(cxt);
    UIImage * uiImage = [[UIImage alloc] initWithCGImage:cgImage];

    //
    // Clean up
    //
    CFRelease(cxt);
    CFRelease(colorSpace);
    CGImageRelease(cgImage);
    
    //
    // Notify that a new image is going to be fed to the graph.
    //
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kDebugImageUpdated" object:nil userInfo:@{@"debugImage" : uiImage}];
    });
}


//
// Takes a pixel buffer coming from the Camera preview session and obtains predictions w/bounding boxes from
// a tensorflow graph.
//
- (void)runModelOnPixelBuffer:(CVPixelBufferRef) pixelBuffer orientation: (UIDeviceOrientation) orientation
{
    //
    // if the graph hasn't loaded we can't do anything yet.
    //
    if (!self.loadStatus.ok() || self.isProcessingFrame)
    {
        return;
    }

    //
    // mark the graph as busy
    //
    self.isProcessingFrame = YES;

    //
    // Retain the pixel buffer, copy and make a CGImage out of it.  pixelBufferToCGImage will
    // rotate the pixel buffer if necessary and scale the image down to the width and height
    // desired for inference. pixelBufferToCGImage will also release the CVPixelBuffer.
    //
    CGImageRef cgImage = [self pixelBufferToCGImage:pixelBuffer orientation:orientation];

    //
    // Gather needed dimensions of the CGImage
    //
    const int srcHeight   = (int) CGImageGetHeight(cgImage);
    const int srcWidth    = (int) CGImageGetWidth(cgImage);
    const int bytesPerRow = (int) CGImageGetBytesPerRow(cgImage);
    const int srcChannels = (int) bytesPerRow / srcWidth;
    
    //
    // Create a tensor for running through the graph.
    //
    tensorflow::Tensor imageTensor(tensorflow::DT_UINT8, tensorflow::TensorShape({1, kGraphImageHeight, kGraphImageWidth, kGraphChannels}));
    auto imageTensorDimensioned = imageTensor.tensor<tensorflow::uint8, 4>();
    
    //
    // Get a pointer to the pixel data in the cgImage.  This is our starting
    // address of the source pixel buffer data.
    //
    CFDataRef pixelData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    unsigned char *srcStartAddress  = (unsigned char*) CFDataGetBytePtr(pixelData);
    
    //
    // Scale the pixel data down to the expected width and height, drop the alpha channel,
    // and populate the image_tensor.
    // The source pointer iterates through the pixel data and copies the data
    // into the reshaped Tensorflow image tensor.  Changing the GraphInputWidth and Height
    // may increase (or decrease) speed and/or accuracy.
    //
    unsigned char *destStartAddress = imageTensorDimensioned.data();
    for (int row = 0; row < srcHeight; ++row)
    {
        unsigned char *destRow = destStartAddress + (row * srcWidth * kGraphChannels);
        for (int col = 0; col < srcWidth; ++col)
        {
            unsigned char* srcPixel  = srcStartAddress + (row * bytesPerRow) + (col * srcChannels);
            unsigned char* destPixel = destRow + (col * kGraphChannels);
            for (int c = 0; c < kGraphChannels; ++c)
            {
                destPixel[c] = srcPixel[c];
            }
        }
    }
    
    // we are done with the CFDataRef
    CFRelease(pixelData);
    
    //
    // Move the tensorflow processing to another thread.  Not only are there limited pixelBuffers
    // but if the thread running the videoPreview gets blocked we will get Late Frame warninigs.
    // Running the graph on a background thread keeps things moving.
    //
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        //
        // Get a start time.  We will clock the tensorflow processing time.
        //
        struct timespec ts_start;
        clock_gettime(CLOCK_MONOTONIC, &ts_start);
        
        if (self->tfSession.get())
        {
            // Run through the graph.
            std::vector<tensorflow::Tensor> outputs;
            tensorflow::Status runStatus = self->tfSession->Run({{"image_tensor", imageTensor}}, {"detection_boxes", "detection_scores", "detection_classes", "num_detections"}, {}, &outputs);
            
            if (!runStatus.ok())
            {
                LOG(FATAL) << "Error: " << runStatus;
            }
            else
            {
                //
                // Calculate the amount of time it took to run the image through
                // the model.
                //
                struct timespec ts_end;
                clock_gettime(CLOCK_MONOTONIC, &ts_end);
                struct timespec elapsed = diff(ts_start, ts_end);
                
                //
                // Calculate an average time and output every X frames.
                //
                self.processingTime += elapsed.tv_sec;
                self.processingTime += (elapsed.tv_nsec / 1000000000.0f);
                self.framesProcessed += 1;
                if (self.framesProcessed % kAverageEveryXFrames == 0)
                {
                    printf("Avg. prediction time: %f\n", self.processingTime / self.framesProcessed);
                }
                
                //
                // Generate our list of predictions and bounding boxes
                //
                auto boundingBoxesFlat = outputs[0].flat<float>();
                tensorflow::TTypes<float>::Flat scores_flat = outputs[1].flat<float>();
                tensorflow::TTypes<float>::Flat indices_flat = outputs[2].flat<float>();
                
                NSMutableArray * predictions = [[NSMutableArray alloc] init];
                for (int i = 0; i < kGraphMaxPredictions; ++i)
                {
                    //
                    // once the prediction score falls below our threshold don't bother
                    // processing any more predictions.
                    //
                    const float score = scores_flat(i);
                    if (score < kPredictionThreshold)
                    {
                        break;
                    }
                    
                    //
                    // Keep an array of predictions
                    //
                    TensorflowPrediction * prediction = [[TensorflowPrediction alloc] init];
                    prediction.score  = score;
                    const int label_index = (tensorflow::int32)indices_flat(i);
                    prediction.label  = [NSString stringWithUTF8String:GetDisplayName(&self->labelMap, label_index).c_str()];
                    prediction.top    = boundingBoxesFlat(i * 4 + 0);
                    prediction.left   = boundingBoxesFlat(i * 4 + 1);
                    prediction.bottom = boundingBoxesFlat(i * 4 + 2);
                    prediction.right  = boundingBoxesFlat(i * 4 + 3);
                    
                    printf("Prediction: %s --- Score: %f\n", [prediction.label cStringUsingEncoding:NSASCIIStringEncoding], prediction.score);

                    //
                    // Crop the pixels out of the bounding box and put the cropped
                    // image into the prediction object. Prediction values are
                    // normalized so we multiply by the image dimensions to get
                    // back to pixel values.
                    //
                    const int x = srcWidth  * prediction.left;
                    const int y = srcHeight * prediction.top;
                    const int w = srcWidth  * (prediction.right - prediction.left);
                    const int h = srcHeight * (prediction.bottom - prediction.top);
                    
                    CGRect croppedArea = CGRectMake(x, y, w, h);
                    CGImageRef cropped = CGImageCreateWithImageInRect(cgImage, croppedArea);
                    prediction.image = [UIImage imageWithCGImage:cropped];
                    CGImageRelease(cropped);
                    
                    [predictions addObject:prediction];
                }
                
                //
                // Notify the UI that we have new predictions. Another class will receive this
                // and use the data to draw bounding boxes.
                //
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"kPredictionsUpdated" object:nil userInfo:@{@"predictions" : predictions}];
                });
                
            }
            
            CGImageRelease(cgImage);
            
            self.isProcessingFrame = NO;
        }  // end --- if (tfSession.get)
    });   // end --- dispatch_async
}   // end --- runModelOnPixelBuffer()

@end
