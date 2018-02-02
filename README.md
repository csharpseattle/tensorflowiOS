# Tensorflow iOS Object Detection

An Object Detection application on iOS using Tensorflow and pre-trained COCO dataset models.  Video frames are captured and inference is done locally using one of the 3 provided models: ssd_mobilenet_v1_coco, ssd_inception_v2_coco, and faster_rcnn_resnet101_coco.  Both Swift and Objective-C projects.

![cat image](images/cat.png)

## Building

* Make sure you have automake and libtool.  Using homebrew:

`brew install automake libtool`


* Clone the tensorflow source repo on GitHub

`git clone https://github.com/tensorflow/tensorflow`


* `cd` into the tensorflow repo and checkout the `v1.5.0` tag.  This release has the Makefile support for the following `ANDROID_TYPES` environment variable

`git checkout v1.5.0`


* We need to build the tensorflow components with ANDROID_TYPES_FULL.  In the terminal type:

`export ANDROID_TYPES="-D__ANDROID_TYPES_FULL__"`


* Build the tensorflow libraries for iOS.  Go to the root of your newly downloaded tensorflow repo and run:

`tensorflow/contrib/makefile/build_all_ios.sh`

Go get a coffee. This can take a while.  On my macBook it took almost 2 hours.


* Open either the Swift of Objective-C project in this repo and edit the **tensorflow.xconfig** file to point to the folder where you cloned the tensorflow repo

`TENSORFLOW_ROOT=/Users/username/Development/tensorflow`


* Compile the xcode project and run. Since we need a camera this will only run on a device.
