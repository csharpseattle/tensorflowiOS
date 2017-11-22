#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "tensorflow/core/public/session.h"
#include "tensorflow/core/util/memmapped_file_system.h"
#include "string_int_label_map.pb.h"

#include <CoreVideo/CoreVideo.h>

@interface TensorflowGraph : NSObject
{
    std::unique_ptr<tensorflow::Session>        tfSession;
    object_detection::protos::StringIntLabelMap labelMap;
}

- (BOOL)loadLabelsWithFileName:(NSString *)labelsFileName labelsFileType:(NSString *)labelsFileType;
- (BOOL)loadModelWithFileName:(NSString *)modelFileName modelFileType:(NSString *)modelFileType;

tensorflow::Status loadLabels(NSString *fileName, NSString *fileType, object_detection::protos::StringIntLabelMap *labelStrings);

- (BOOL) canProcessFrame;
- (void)runModelOnPixelBuffer:(CVPixelBufferRef) pixelBuf orientation: (UIDeviceOrientation) orientation;

@end
