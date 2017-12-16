
#import "TensorflowGraph.h"
#import <CoreImage/CoreImage.h>
#import "TensorflowUtils.h"
#import "TensorflowPrediction.h"
#include <time.h>
#import "tensorflow/core/public/session.h"
#import "tensorflow/core/util/memmapped_file_system.h"
#include "string_int_label_map.pb.h"


const int kGraphChannels         = 3;    // BGR.
const int kGraphImageWidth       = 480;  // The width of the pixels going into the graph.
const int kGraphImageHeight      = 270;  // the height of the pixels going into the graph.
const float kPredictionThreshold = 0.50; // Prediction percentages lower than this will be discarded.
const int kGraphMaxPredictions   = 15;   // After this many predictions we move on.
const int kAverageEveryXFrames   = 50;   // Output average processing time every X frames

@interface TensorflowGraph()
{
    std::unique_ptr<tensorflow::Session>        tfSession;
    object_detection::protos::StringIntLabelMap labelMap;
}

// processingTime and framesProcessed are used for keeping an average time to make predictions.
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
        NSString *model = @"op_inference_graph";
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


- (CGImageRef) copyPixelBuffer: (CVImageBufferRef) pixelBuffer
{
    //
    // alloc a CIImage with the pixel buffer.
    CIImage* ciImage = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffer];
    
    const int pixelBufHeight   = (int) CVPixelBufferGetHeight(pixelBuffer);
    const int pixelBufWidth    = (int) CVPixelBufferGetWidth(pixelBuffer);
    CGAffineTransform scale = CGAffineTransformMakeScale(float(kGraphImageWidth)/pixelBufWidth,
                                                         float(kGraphImageHeight)/pixelBufHeight);
    CIImage* resized = [ciImage imageByApplyingTransform:scale];
    
    //
    // Create a cgImage from the frame pixels
    //
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:resized fromRect:resized.extent];
    
    return cgImage;
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
    // Retain the pixel buffer, copy and make a CGImage out of it.
    //
    CFRetain(pixelBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    CGImageRef cgImage = [self copyPixelBuffer:pixelBuffer];
    CFRelease(pixelBuffer);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    //
    // mark the graph as busy
    //
    self.isProcessingFrame = YES;
    
    //
    // Create a tensor for running through the graph.
    //
    tensorflow::Tensor imageTensor(tensorflow::DT_UINT8, tensorflow::TensorShape({1, kGraphImageHeight, kGraphImageWidth, kGraphChannels}));
    auto imageTensorDimensioned = imageTensor.tensor<tensorflow::uint8, 4>();

    //
    // Gather needed dimensions of the CGImage
    //
    const int srcHeight   = (int) CGImageGetHeight(cgImage);
    const int srcWidth    = (int) CGImageGetWidth(cgImage);
    const int bytesPerRow = (int) CGImageGetBytesPerRow(cgImage);
    const int srcChannels = (int) bytesPerRow / srcWidth;
    
    //
    // Scale the pixel data down, drop the alpha channel, and populate the image_tensor.
    // The source pointer iterates through the pixelBuffer and the destination pointer
    // writes pixel data into the reshaped image tensor.  Changing the GraphInputWidth and Height
    // may increase (or decrease) speed and/or accuracy.
    //
    CFDataRef pixelData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    unsigned char *srcStartAddress  = (unsigned char*) CFDataGetBytePtr(pixelData);
    
    //
    // if the orientation is landscape-right the source pixels start at the end of the pixel buffer
    // and read backwards.  dest pixel still ends up in the same row, col.
    //
    if (orientation == UIDeviceOrientationLandscapeRight)
    {
        srcStartAddress += (bytesPerRow * srcHeight);
    }
    
    //
    // Scale the buffer down to the expected size and shape of the input tensor for the TF graph
    // also, drop the alpha component as the pixel format going in is BGA.
    //
    unsigned char *destStartAddress = imageTensorDimensioned.data();
    for (int row = 0; row < kGraphImageHeight; ++row)
    {
        unsigned char *destRow = destStartAddress + (row * kGraphImageWidth * kGraphChannels);
        for (int col = 0; col < kGraphImageWidth; ++col)
        {
            const int srcRow = (int) (row * (srcHeight / kGraphImageHeight));
            const int srcCol = (int) (col * (srcWidth  / kGraphImageWidth));
            unsigned char* srcPixel;
            
            if (orientation == UIDeviceOrientationLandscapeRight)
            {
                // landscape right - we start at the end of the buffer and read backwards
                srcPixel  = srcStartAddress - (srcRow * bytesPerRow) - (srcCol * srcChannels);
            }
            else
            {
                // landscape left - we start at the beginning of the buffer and read forward
                srcPixel  = srcStartAddress + (srcRow * bytesPerRow) + (srcCol * srcChannels);
            }
            
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
        
        if (tfSession.get())
        {
            // Run through the graph.
            std::vector<tensorflow::Tensor> outputs;
            tensorflow::Status runStatus = tfSession->Run({{"image_tensor", imageTensor}}, {"detection_boxes", "detection_scores", "detection_classes", "num_detections"}, {}, &outputs);
            
            if (!runStatus.ok())
            {
                LOG(FATAL) << "Error: " << runStatus;
            }
            else
            {
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
                    prediction.label  = [NSString stringWithUTF8String:GetDisplayName(&labelMap, label_index).c_str()];
                    prediction.top    = boundingBoxesFlat(i * 4 + 0);
                    prediction.left   = boundingBoxesFlat(i * 4 + 1);
                    prediction.bottom = boundingBoxesFlat(i * 4 + 2);
                    prediction.right  = boundingBoxesFlat(i * 4 + 3);


                    //
                    // Crop the pixels out of the bounding box and put the cropped
                    // image into the prediction object. Prediction values are
                    // normalized so we multiply by the image dimensions to get
                    // back to pixel values.
                    //
                    const int w = srcWidth  * (prediction.right - prediction.left);
                    const int h = srcHeight * (prediction.bottom - prediction.top);
                    
                    int x, y;
                    if (orientation == UIDeviceOrientationLandscapeRight)
                    {
                        x = srcWidth  * (1 - prediction.left - (prediction.right - prediction.left));
                        y = srcHeight * (1 - prediction.top - (prediction.bottom - prediction.top));
                    }
                    else
                    {
                        x = srcWidth  * prediction.left;
                        y = srcHeight * prediction.top;
                    }
                    CGRect croppedArea = CGRectMake(x, y, w, h);
                    CGImageRef cropped = CGImageCreateWithImageInRect(cgImage, croppedArea);
                    prediction.image = [UIImage imageWithCGImage:cropped];
                    CGImageRelease(cropped);
                    
                    [predictions addObject:prediction];
                }
                
                //
                // Now that predictions are done calculate the amount of time elapsed since the start of processing.
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
                // Notify the UI that we have new predictions. Another class will receive this
                // and use the data to draw bounding boxes.
                //
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"kPredictionsUpdated" object:nil userInfo:@{@"predictions" : predictions}];
                });
                
                CGImageRelease(cgImage);
            }
            
            self.isProcessingFrame = NO;
        }  // end --- if (tfSession.get)
    });   // end --- dispatch_async
}   // end --- runModelOnPixelBuffer()

@end
