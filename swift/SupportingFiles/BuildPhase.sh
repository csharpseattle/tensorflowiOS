#!/bin/bash

#
# Grab the proto definition file from the tensorflow models repository
#
echo "Downloading proto definition from models repo"
curl -s -o /${TMPDIR}/string_int_label_map.proto https://raw.githubusercontent.com/tensorflow/models/master/research/object_detection/protos/string_int_label_map.proto

#
# Test for existence of the protobuf compiler in the tensorflow repo.
#
if [ ! -f $TENSORFLOW_ROOT/tensorflow/contrib/makefile/gen/protobuf-host/bin/protoc ]; then
    echo "protoc not found in Tensorflow repo at tensorflow/contrib/makefile/gen/protobuf-host/bin.  Did you set TENSORFLOW_ROOT in tensorflow.xcconfig?"
    return 1
fi

#
# Generate the string_int_label_map.cc and .h file
#


if [ $? == 0 ]; then
    echo "Generating string_int_label_map.  Output to '$SRCROOT'"
    $TENSORFLOW_ROOT/tensorflow/contrib/makefile/gen/protobuf-host/bin/protoc --proto_path=${TMPDIR} --cpp_out=${SRCROOT}/Tensorflow/ string_int_label_map.proto
else
    exit 1
fi

return $?
