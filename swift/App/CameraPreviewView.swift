//
//  CameraPreviewView.swift
//  tensorflowiOS
//
//  Created by Chris Sharp on 11/11/17.
//  Copyright © 2017 Chris Sharp. All rights reserved.
//

import UIKit
import AVFoundation

class CameraPreviewView: UIView
{
    private enum SessionSetupResult
    {
        case success
        case notAuthorized
        case configurationFailed
    }
    
    private var cameraSetupResult: SessionSetupResult = .success
    private let avSession = AVCaptureSession()
    private var isSessionRunning = false
    
    // Communicate with the session and other session objects on this queue.
    private let previewSessionQueue = DispatchQueue(label: "PreviewSessionQueue")
    
    // We use a serial queue for the video frames so that they are dispatched in the order that they are captured
    private let videoSessionQueue = DispatchQueue(label: "VideoFrameQueue")
    
    private let videoOutput:AVCaptureVideoDataOutput = AVCaptureVideoDataOutput()
    
    private var keyValueObservations = [NSKeyValueObservation]()
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        setupSession()
    }
    
    ////////////////////////////////////////
    // MARK: - Video Session Setup and Configuration

    func setupSession()
    {
        self.videoPreviewLayer.session = avSession
        
        switch AVCaptureDevice.authorizationStatus(for: .video)
        {
            case .authorized:
            // The user has previously granted access to the camera.
            break
            
            case .notDetermined:
            /*
             The user has not yet been presented with the option to grant
             video access. We suspend the session queue to delay session
             setup until the access request has completed.
             */
            previewSessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted
                {
                    self.cameraSetupResult = .notAuthorized
                }
                self.previewSessionQueue.resume()
            })
            
            default:
                // The user has previously denied access.
                cameraSetupResult = .notAuthorized
        }
    }
    

    func configureSession(delegate:AVCaptureVideoDataOutputSampleBufferDelegate )
    {
        previewSessionQueue.async {
            
            if (self.cameraSetupResult != .success)
            {
                return
            }
            
            self.avSession.beginConfiguration()
        
            // Add video input.
            do
            {
                var defaultVideoDevice: AVCaptureDevice?
                
                // Choose the back dual camera if available, otherwise default to a wide angle camera.
                if let dualCameraDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
                {
                    defaultVideoDevice = dualCameraDevice
                }
                else if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                {
                    // If the back dual camera is not available, default to the back wide angle camera.
                    defaultVideoDevice = backCameraDevice
                }
                else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                {
                    /*
                     In some cases where users break their phones, the back wide angle camera is not available.
                     In this case, we should default to the front wide angle camera.
                     */
                    defaultVideoDevice = frontCameraDevice
                }
                
                let videoDeviceInput = try AVCaptureDeviceInput(device: defaultVideoDevice!)
                
                if self.avSession.canAddInput(videoDeviceInput)
                {
                    self.avSession.addInput(videoDeviceInput)
                    
                    DispatchQueue.main.async {
                        // Dispatching this to the main queue because a UIView (CameraPreviewView) can only be
                        // changed on the main thread.
                        let statusBarOrientation = UIApplication.shared.statusBarOrientation
                        var initialVideoOrientation: AVCaptureVideoOrientation = .portrait
                        if (statusBarOrientation != .unknown)
                        {
                            if let videoOrientation = AVCaptureVideoOrientation(interfaceOrientation: statusBarOrientation) {
                                initialVideoOrientation = videoOrientation
                            }
                        }
                        
                        self.videoPreviewLayer.connection?.videoOrientation = initialVideoOrientation
                    }
                }
                else
                {
                    print("Could not add video device input to the session")
                    self.cameraSetupResult = .configurationFailed
                    self.avSession.commitConfiguration()
                    return
                }
            }
            catch
            {
                print("Could not create video device input: \(error)")
                self.cameraSetupResult = .configurationFailed
                self.avSession.commitConfiguration()
                return
            }

            //
            // let's not forget that we need video output too.
            //
            self.addVideoOutput(delegate)
            
            self.avSession.commitConfiguration()
        } // previewSessionQueue.async()
    }
    
    private func addVideoOutput(_ delegate:AVCaptureVideoDataOutputSampleBufferDelegate)
    {
        //
        // We use the 32 bit BGRA pixel format type.  That way we can just pass the data to
        // Tensorflow without pre-processing.
        //
        let newSettings = [String(kCVPixelBufferPixelFormatTypeKey) : kCVPixelFormatType_32BGRA]
        videoOutput.videoSettings = newSettings;
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegate, queue: videoSessionQueue)
    
        //
        // Add the videoOutput to our AVSession
        //
        if avSession.canAddOutput(videoOutput)
        {
            avSession.beginConfiguration()
            avSession.addOutput(videoOutput)
            avSession.sessionPreset = AVCaptureSession.Preset.high;
            let connection:AVCaptureConnection = videoOutput.connection(with: AVMediaType.video)!
            if ( connection.isVideoStabilizationSupported )
            {
                connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationMode.auto
            }
            
            avSession.commitConfiguration()
        }
    }

    ///////////////////////////////////////////////////////////////////////
    // MARK: - UIView and Session life cycle
    var videoPreviewLayer: AVCaptureVideoPreviewLayer
    {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected `AVCaptureVideoPreviewLayer` type for layer. Check PreviewView.layerClass implementation.")
        }
            
        return layer
    }
        
    var session: AVCaptureSession? {
        get {
            return videoPreviewLayer.session
        }
        set {
            videoPreviewLayer.session = newValue
        }
    }
        
    override class var layerClass: AnyClass
    {
        return AVCaptureVideoPreviewLayer.self
    }
    
    private func addObservers()
    {
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(notification:)),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: avSession)
    }
    
    private func removeObservers()
    {
        NotificationCenter.default.removeObserver(self)
        
        for keyValueObservation in keyValueObservations
        {
            keyValueObservation.invalidate()
        }
        keyValueObservations.removeAll()
    }
    
    func startSession()
    {
        previewSessionQueue.async {
            switch ( self.cameraSetupResult )
            {
                case SessionSetupResult.success:
                    // if setup succeeded we can add Observers and the frame delegate and run the session.
                    self.addObservers()
    
                    self.avSession.startRunning()
                    self.isSessionRunning = self.avSession.isRunning;
    
                    // Let everyone know we have a session.
                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: kAVSessionStarted), object:nil)

                case .notAuthorized:
                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: kSetupResultCameraNotAuthorized), object: nil)

                case .configurationFailed:
                    NotificationCenter.default.post(name: NSNotification.Name(rawValue: kSetupResultSessionConfigurationFailed), object: nil)
            }
        }
    }
    
    func stopSession()
    {
        previewSessionQueue.async {
            if ( self.cameraSetupResult == .success )
            {
                self.avSession.stopRunning()
                self.removeObservers()
            }            
        }
    }


    @objc func sessionRuntimeError(notification: NSNotification)
    {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        
        print("Capture session runtime error: \(error)")
        
        /*
         Automatically try to restart the session running if media services were
         reset and the last start running succeeded. Otherwise, enable the user
         to try to resume the session running.
         */
        if error.code == .mediaServicesWereReset
        {
            previewSessionQueue.async {
                if self.isSessionRunning
                {
                    self.avSession.startRunning()
                    self.isSessionRunning = self.avSession.isRunning
                }
            }
        }
    }
}

