
#import <Foundation/Foundation.h>

#include "TensorflowUtils.h"
#include <fstream>
#include <google/protobuf/text_format.h>
#include <google/protobuf/io/zero_copy_stream_impl.h>
#include "string_int_label_map.pb.h"


// Helper class borrowed from some utils that loads protobufs efficiently.
namespace
{
    class IfstreamInputStream : public ::google::protobuf::io::CopyingInputStream
    {
    public:
        explicit IfstreamInputStream(const std::string& file_name) : ifs_(file_name.c_str(), std::ios::in | std::ios::binary) {}
        ~IfstreamInputStream() { ifs_.close(); }
        
        int Read(void *buffer, int size)
        {
            if (!ifs_)
            {
                return -1;
            }
            ifs_.read(static_cast<char*>(buffer), size);
            return (int)ifs_.gcount();
        }
        
    private:
        std::ifstream ifs_;
    };
}

#pragma mark - Private

NSString *filePathForResourceName(NSString *name, NSString *extension)
{
    NSString *filePath = [[NSBundle mainBundle] pathForResource:name ofType:extension];
    
    if (filePath == NULL)
    {
        LOG(FATAL) << "Couldn't find '" << [name UTF8String] << "." << [extension UTF8String] << "' in bundle.";
        return nullptr;
    }
    return filePath;
}

bool PortableReadFileToProto(const std::string& fileName, ::google::protobuf::MessageLite *proto)
{
    ::google::protobuf::io::CopyingInputStreamAdaptor stream(new IfstreamInputStream(fileName));
    stream.SetOwnsCopyingStream(true);
    ::google::protobuf::io::CodedInputStream codedStream(&stream);
    
    // Total bytes hard limit / warning limit are set to 1GB and 512MB
    // respectively.
    codedStream.SetTotalBytesLimit(1024LL << 20, 512LL << 20);
    return proto->ParseFromCodedStream(&codedStream);
}

#pragma mark - Public

tensorflow::Status loadModel(NSString *fileName, NSString *fileType, std::unique_ptr<tensorflow::Session> *session)
{
    tensorflow::SessionOptions options;
    
    tensorflow::Session *sessionPointer = nullptr;
    tensorflow::Status sessionStatus = tensorflow::NewSession(options, &sessionPointer);
    
    if (!sessionStatus.ok())
    {
        LOG(ERROR) << "Could not create TensorFlow Session: " << sessionStatus;
        return sessionStatus;
    }
    session->reset(sessionPointer);
    
    tensorflow::GraphDef tensorflowGraph;
    
    NSString *modelPath = filePathForResourceName(fileName, fileType);
    
    if (!modelPath)
    {
        LOG(ERROR) << "Failed to find model proto at" << [fileName UTF8String] << [fileType UTF8String];
        return tensorflow::errors::NotFound([fileName UTF8String], [fileType UTF8String]);
    }
    
    const bool readProtoSucceeded = PortableReadFileToProto([modelPath UTF8String], &tensorflowGraph);
    
    if (!readProtoSucceeded)
    {
        LOG(ERROR) << "Failed to load model proto from" << [modelPath UTF8String];
        return tensorflow::errors::NotFound([modelPath UTF8String]);
    }
    
    tensorflow::Status create_status = (*session)->Create(tensorflowGraph);
    
    if (!create_status.ok())
    {
        LOG(ERROR) << "Could not create TensorFlow Graph: " << create_status;
        return create_status;
    }
    
    return tensorflow::Status::OK();
}

tensorflow::Status loadLabels(NSString *fileName, NSString *fileType, object_detection::protos::StringIntLabelMap *labelMap)
{
    // Read the label list
    NSString *labelsPath = filePathForResourceName(fileName, fileType);
    
    if (!labelsPath)
    {
        LOG(ERROR) << "Failed to find model proto at" << [fileName UTF8String] << [fileType UTF8String];
        return tensorflow::errors::NotFound([fileName UTF8String], [fileType UTF8String]);
    }

    int fileDescriptor = open([labelsPath UTF8String], O_RDONLY);
    if (fileDescriptor >= 0)
    {
        google::protobuf::io::FileInputStream fileInput(fileDescriptor);
        fileInput.SetCloseOnDelete( true );
    
        if (!google::protobuf::TextFormat::Parse(&fileInput, labelMap))
        {
            LOG(ERROR) << "Failed to parse label file.\n";
            return tensorflow::errors::Aborted([fileName UTF8String], [fileType UTF8String]);
        }
    }
    
    return tensorflow::Status::OK();
}

std::string GetDisplayName(const object_detection::protos::StringIntLabelMap* labels, int index)
{
    for (int i = 0; i < labels->item_size(); ++i)
    {
        const object_detection::protos::StringIntLabelMapItem& item = labels->item(i);
        if (index == item.id())
        {
            return item.display_name();
        }
    }
    
    return "";
}

//
// Calculate and return elapsed time between to struct timespecs
//
timespec diff(timespec start, timespec end)
{
    timespec temp;
    if ((end.tv_nsec-start.tv_nsec)<0)
    {
        temp.tv_sec = end.tv_sec-start.tv_sec-1;
        temp.tv_nsec = 1000000000+end.tv_nsec-start.tv_nsec;
    }
    else
    {
        temp.tv_sec = end.tv_sec-start.tv_sec;
        temp.tv_nsec = end.tv_nsec-start.tv_nsec;
    }
    return temp;
}


