
//
//  ViewController.swift
//  tensorflowiOS
//
//  Created by Chris Sharp on 11/10/17.
//  Copyright © 2017 Chris Sharp. All rights reserved.
//

import UIKit
import AVFoundation


class ViewController:UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate
{
    @IBOutlet weak var cameraUnavailableLabel : UILabel!
    @IBOutlet weak var boundingBoxView        : BoundingBoxView!
    @IBOutlet weak var cameraPreviewView      : CameraPreviewView!
    var tensorflowGraph:TensorflowGraph? = nil

    override func viewDidLoad()
    {
        super.viewDidLoad()

        //
        // Configure the video preview.  We will grab frames
        // from the video preview and feed them into the tensorflow graph.
        // Then bounding boxes can be rendered onto the boundingBoxView.
        //
        cameraPreviewView.configureSession(delegate: self)
    }
    
    
    override func viewWillAppear(_ animated: Bool)
    {
        super.viewWillAppear(animated)

        //
        // Listen for the start of the AVSession.  This will signal the start
        // of the delivery of video frames and will trigger the
        // initialization of the tensorflow graph
        //
        NotificationCenter.default.addObserver(self, selector: #selector(OnAvSessionStarted(notification:)),
                                               name: NSNotification.Name(rawValue: kAVSessionStarted),
                                               object: nil)
    
        //
        // Also Listen for Session initialization failure or for when
        // the user doesn't authorize the use of the camera
        //
        NotificationCenter.default.addObserver(self, selector: #selector(OnSetupResultCameraNotAuthorized(notification:)),
                                               name: Notification.Name(kSetupResultCameraNotAuthorized),
                                               object:nil)

        NotificationCenter.default.addObserver(self, selector: #selector(OnSetupResultSessionConfigurationFailed(notification:)),
                                               name: Notification.Name(kSetupResultSessionConfigurationFailed),
                                               object:nil)
        
        //
        // Respond to the tensorflow graph's update of predictions.  This will
        // trigger the redrawing of the bounding boxes.
        //
        NotificationCenter.default.addObserver(self, selector: #selector(OnPredictionsUpdated(notification:)),
                                               name: Notification.Name(kPredictionsUpdated),
                                               object:nil)
        //
        // Start the AV Session. This will prompt the user for
        // permission to use the camera to present a video preview.
        //
        cameraPreviewView.startSession()
    }
    
    //
    // when the view disappears we shut down the session.  It will be restarted in ViewWillAppear
    //
    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewWillAppear(animated)
        cameraPreviewView.stopSession()        
    }
    
    //
    // Yes, please autorotate, but we will have to change the orientation of the pixel buffer when we run the graph.
    //
    override var shouldAutorotate: Bool
    {
        return true
    }
    
    //
    // Supporting only landscape.
    //
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask
    {
        return .landscape
    }
    
    //
    // Override viewWillTransitionToSize so that we can update the videoPreviewLayer with the new orientation.
    //
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator)
    {
        //
        // call super so the coordinator can be passed on.
        //
        super.viewWillTransition(to: size, with: coordinator)
        
        if let videoPreviewLayerConnection = cameraPreviewView.videoPreviewLayer.connection
        {
            //
            // ignore everything but landscape orientation changes.
            //
            let deviceOrientation = UIDevice.current.orientation
            guard let newVideoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation), deviceOrientation.isLandscape else {
                    return
            }
            
            videoPreviewLayerConnection.videoOrientation = newVideoOrientation
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection)
    {
        let pixelBuffer: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
        
        if tensorflowGraph != nil
        {
            tensorflowGraph?.runModel(on: pixelBuffer, orientation: UIDevice.current.orientation)
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection)
    {
        //do something with dropped frames here
    }
    



    
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // MARK: - Notification Handlers
    
    @objc func OnAvSessionStarted(notification: NSNotification)
    {
        // Now that the user has granted permission to the camera
        // and we have a video session we can initialize our graph.
        tensorflowGraph = TensorflowGraph()
    }

    @objc func OnSetupResultCameraNotAuthorized(notification: NSNotification)
    {
        DispatchQueue.main.async {
            let changePrivacySetting = "Please grant permission to use the camera in Settings"
            let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when we have no access to the camera")
            let alertController = UIAlertController(title: "TensorflowiOS", message: message, preferredStyle: .alert)
            
            alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                    style: .cancel,
                                                    handler: nil))
            
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Button to open Settings"),
                                                    style: .`default`,
                                                    handler: { _ in
                                                        UIApplication.shared.open(URL(string: UIApplicationOpenSettingsURLString)!, options: [:], completionHandler: nil)
            }))
            
            self.present(alertController, animated: true, completion: nil)
        }
    }

    @objc func OnSetupResultSessionConfigurationFailed(notification: NSNotification)
    {
        DispatchQueue.main.async {
            let alertMsg = "Something went wrong during capture session configuration"
            let message = NSLocalizedString("Unable to capture media", comment: alertMsg)
            let alertController = UIAlertController(title: "TensorflowiOS", message: message, preferredStyle: .alert)
            
            alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK button"),
                                                    style: .cancel,
                                                    handler: nil))
            
            self.present(alertController, animated: true, completion: nil)
        }
    }

    @objc func OnPredictionsUpdated(notification: NSNotification)
    {
        DispatchQueue.main.async {
            if let userinfo = notification.userInfo {
                if let predictions:[TensorflowPrediction] = userinfo["predictions"] as? [TensorflowPrediction] {
                    // Update the Bounding boxes and labels from the
                    // new predictions coming out of the graph.
                    self.boundingBoxView.updateBoundingBoxes(predictions)
                }
            }
        }
    }
}

////////////////////////////////////////////////////////////////////
// MARK: - AVCaptureVideoOrientation extension

extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeRight
        case .landscapeRight: self = .landscapeLeft
        default: return nil
        }
    }
    
    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}

