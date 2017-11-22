
#ifndef tensorflowUtils_h
#define tensorflowUtils_h

#include "tensorflow/core/public/session.h"
#include "tensorflow/core/util/memmapped_file_system.h"
#include "third_party/eigen3/unsupported/Eigen/CXX11/Tensor"
namespace object_detection
{
    namespace protos
    {
        class StringIntLabelMap;
    }
}

// Reads a serialized GraphDef protobuf file from the bundle, typically
// created with the freeze_graph script. Populates the session argument with a
// Session object that has the model loaded.
tensorflow::Status loadModel(NSString* file_name,
                             NSString* file_type,
                             std::unique_ptr<tensorflow::Session>* session);

// Loads a model from a file that has been created using the
// convert_graphdef_memmapped_format tool. This bundles together a GraphDef
// proto together with a file that can be memory-mapped, containing the weight
// parameters for the model. This is useful because it reduces the overall
// memory pressure, since the read-only parameter regions can be easily paged
// out and don't count toward memory limits on iOS.
tensorflow::Status loadMemoryMappedModel(NSString* file_name,
                                         NSString* file_type,
                                         std::unique_ptr<tensorflow::Session>* session,
                                         std::unique_ptr<tensorflow::MemmappedEnv>* memmapped_env);

// Loads a text file of a label map in mscoco style. 
tensorflow::Status loadLabels(NSString *fileName, NSString *fileType, object_detection::protos::StringIntLabelMap *labelMap);

// Takes a label Map and an index into it.  Returns the 'DisplayName' field in the protobuf
std::string GetDisplayName(const object_detection::protos::StringIntLabelMap* labels, int index);
timespec diff(timespec start, timespec end);
#endif /* tensorflowUtils_h */
