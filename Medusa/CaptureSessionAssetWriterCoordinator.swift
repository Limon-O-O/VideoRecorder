//
//  CaptureSessionAssetWriterCoordinator.swift
//  Medusa
//
//  Created by Limon on 2016/6/13.
//  Copyright © 2016年 Medusa. All rights reserved.
//

import AVFoundation


public func ==(lhs: RecordingStatus, rhs: RecordingStatus) -> Bool {
    return lhs.hashValue == rhs.hashValue
}

public enum RecordingStatus: Hashable {

    case Idle(error: NSError?)
    case StartingRecording
    case Recording
    case Pause
    case StoppingRecording

    public var hashValue: Int {
        switch self {
        case .Idle:
            return 10000
        case .StartingRecording:
            return 20000
        case .Recording:
            return 30000
        case .Pause:
            return 40000
        case .StoppingRecording:
            return 60000
        }
    }
}


public final class CaptureSessionAssetWriterCoordinator: CaptureSessionCoordinator {

    private let videoDataOutput: AVCaptureVideoDataOutput
    private let audioDataOutput: AVCaptureAudioDataOutput

    private var videoConnection: AVCaptureConnection!
    private var audioConnection: AVCaptureConnection!

    private var outputVideoFormatDescription: CMFormatDescriptionRef?
    private var outputAudioFormatDescription: CMFormatDescriptionRef?

    private var assetWriterCoordinator: AssetWriterCoordinator?

    private var segments = [Segment]()

    private var attributes: Attributes

    public private(set) var recordingStatus: RecordingStatus = .Idle(error: nil) {

        didSet(oldStatus) {

            let currentStatus = recordingStatus

            guard currentStatus != oldStatus else { return }

            let delegateCallbackQueue = dispatch_get_main_queue()

            if case .Idle(let error) = currentStatus where error != nil {

                dispatch_async(delegateCallbackQueue) {
                    autoreleasepool {
                        self.delegate?.coordinator(self, didFinishRecordingToOutputFileURL: nil, error: error)
                        self.assetWriterCoordinator = nil
                    }
                }

                return
            }

            switch (oldStatus, currentStatus) {

            // Click Record Action
            case (.Idle, .StartingRecording):
                dispatch_async(delegateCallbackQueue) {
                    autoreleasepool {
                        self.delegate?.coordinatorWillBeginRecording(self)
                    }
                }

            // Click Stop Record Action
            case (.Recording, .StoppingRecording):
                dispatch_async(delegateCallbackQueue) {
                    autoreleasepool {
                        self.delegate?.coordinatorWillDidFinishRecording(self)
                    }
                }

            // Start Recording
            case (.StartingRecording, .Recording):
                dispatch_async(delegateCallbackQueue) {
                    autoreleasepool {
                        self.delegate?.coordinatorDidBeginRecording(self)
                    }
                }

            // Stop Recording
            case (.StoppingRecording, .Idle):

                dispatch_async(delegateCallbackQueue) {
                    autoreleasepool {

                        let finish = {

                            self.segments.forEach {
                                NSFileManager.med_removeExistingFile(byURL: $0.URL)
                            }

                            self.segments.removeAll()

                            self.attributes._destinationURL = self.attributes.destinationURL
                            self.recordingStatus = .Idle(error: nil)
                            self.delegate?.coordinator(self, didFinishRecordingToOutputFileURL: self.attributes.destinationURL, error: nil)
                            self.assetWriterCoordinator = nil
                        }

                        if !self.segments.isEmpty {

                            // Merge segments
                            let asset = assetRepresentingSegments(self.segments)

                            if let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) {

                                exportSession.canPerformMultiplePassesOverSourceMediaData = true
                                exportSession.outputURL = self.attributes.destinationURL
                                exportSession.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration)
                                exportSession.outputFileType = self.attributes.mediaFormat.fileFormat

                                exportSession.exportAsynchronouslyWithCompletionHandler {
                                    _ in

                                    finish()
                                    
                                }
                            }

                        } else {
                            finish()
                        }

                    }
                }

            // Idle -> StoppingRecording
            case (.Idle, .StoppingRecording):
                // FIXME
                dispatch_async(delegateCallbackQueue) { [weak self] in
                    self?.recordingStatus = .Idle(error: nil)
                }

            // Click Pause
            case (.Recording, .Pause):
                dispatch_async(delegateCallbackQueue) {
                    autoreleasepool {
                        self.delegate?.coordinatorWillPauseRecording(self)
                    }
                }

            // Did Pause
            case (.Pause, .Idle):
                dispatch_async(delegateCallbackQueue) {
                    autoreleasepool {
                        self.delegate?.coordinatorDidPauseRecording(self)
                    }
                }

            default:
                print("Unknow RecordingStatus: \(oldStatus) -> \(currentStatus)")
            }

        }
    }

    public init(sessionPreset: String, attributes: Attributes, position: AVCaptureDevicePosition = .Back) throws {

        videoDataOutput = {
            $0.videoSettings = nil
            $0.alwaysDiscardsLateVideoFrames = false
            return $0
        }(AVCaptureVideoDataOutput())

        audioDataOutput = AVCaptureAudioDataOutput()

        self.attributes = attributes

        try super.init(sessionPreset: sessionPreset, position: position)

        try addOutput(videoDataOutput, toCaptureSession: captureSession)
        try addOutput(audioDataOutput, toCaptureSession: captureSession)

        (videoConnection, audioConnection) = try fetchConnections(fromVideoDataOutput: videoDataOutput, andAudioDataOutput: audioDataOutput)

        let videoDataOutputQueue = dispatch_queue_create("top.limon.capturesession.videodata", DISPATCH_QUEUE_SERIAL)
        let audioDataOutputQueue = dispatch_queue_create("top.limon.capturesession.audiodata", DISPATCH_QUEUE_SERIAL)

        dispatch_set_target_queue(videoDataOutputQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0))

        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        audioDataOutput.setSampleBufferDelegate(self, queue: audioDataOutputQueue)
    }
}


// MARK: Public Methods

extension CaptureSessionAssetWriterCoordinator {

    public func startRecording() {

        objc_sync_enter(self)
        guard case .Idle = recordingStatus else { return }
        recordingStatus = .StartingRecording
        objc_sync_exit(self)

        if !segments.isEmpty { // Resume
            let newURL = makeNewFileURL()
            let segment = Segment(URL: newURL)
            segments.append(segment)
            attributes._destinationURL = newURL
        }

        assetWriterCoordinator = AssetWriterCoordinator(URL: attributes._destinationURL, fileType: attributes.mediaFormat.fileFormat)

        if let outputVideoFormatDescription = outputVideoFormatDescription {
            assetWriterCoordinator?.addVideoTrackWithSourceFormatDescription(outputVideoFormatDescription, settings: attributes.videoCompressionSettings)
        }

        if let outputAudioFormatDescription = outputAudioFormatDescription {
            assetWriterCoordinator?.addAudioTrackWithSourceFormatDescription(outputAudioFormatDescription, settings: attributes.audioCompressionSettings)
        }

        assetWriterCoordinator?.delegate = self

        // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done
        assetWriterCoordinator?.prepareToRecord()
    }

    public func stopRecording() {

        var flag = false

        objc_sync_enter(self)
        switch recordingStatus {
        case .Idle, .Recording:
            flag = true
        default:
            flag = false
        }
        guard flag else { return }
        recordingStatus = .StoppingRecording
        objc_sync_exit(self)

        assetWriterCoordinator?.finishRecording()
    }

    public func pause() {

        objc_sync_enter(self)
        guard recordingStatus == .Recording else { return }
        recordingStatus = .Pause
        objc_sync_exit(self)

        assetWriterCoordinator?.finishRecording()
    }

//    public func resume() {
//
//        guard case .Idle = recordingStatus else { return }
//
//        let newURL = makeNewFileURL()
//        let segment = Segment(URL: newURL)
//        segments.append(segment)
//
//        attributes._destinationURL = newURL
//        startRecording()
//    }

    public override func swapCaptureDevicePosition() throws {

        try super.swapCaptureDevicePosition()

        // reset

        outputAudioFormatDescription = nil
        outputVideoFormatDescription = nil

        (videoConnection, audioConnection) = try fetchConnections(fromVideoDataOutput: videoDataOutput, andAudioDataOutput: audioDataOutput)
    }

    private func makeNewFileURL() -> NSURL {

        let suffix = "-medusa_segment\(segments.count)"

        let destinationPath = String(attributes.destinationURL.absoluteString.characters.dropLast(attributes.mediaFormat.filenameExtension.characters.count))

        let newAbsoluteString = destinationPath + suffix + attributes.mediaFormat.filenameExtension

        return  NSURL(string: newAbsoluteString)!
    }
}


// MARK: AssetWriterCoordinatorDelegate

extension CaptureSessionAssetWriterCoordinator: AssetWriterCoordinatorDelegate {

    func writerCoordinatorDidFinishPreparing(coordinator: AssetWriterCoordinator) {

        objc_sync_enter(self)
        guard recordingStatus == .StartingRecording else { return }
        recordingStatus = .Recording
        objc_sync_exit(self)
    }

    func writerCoordinator(coordinator: AssetWriterCoordinator, didFailWithError error: NSError?) {

        objc_sync_enter(self)
        recordingStatus = .Idle(error: error)
        objc_sync_exit(self)
    }

    func writerCoordinatorDidFinishRecording(coordinator: AssetWriterCoordinator) {

        // 1. 在 captureSession running 但状态为 Idle 时，停止录制
        // 2. 在状态为 Recording 时，停止录制
        if recordingStatus == .StoppingRecording {

            objc_sync_enter(self)
            recordingStatus = .Idle(error: nil)
            objc_sync_exit(self)

        } else if self.recordingStatus == .Pause {

            // Move out destination file. Prepare for next segment video.
            if segments.isEmpty {
                let newURL = makeNewFileURL()
                NSFileManager.med_moveItem(atURL: attributes.destinationURL, toURL: newURL)
                let segment = Segment(URL: newURL)
                segments.append(segment)
            }

            objc_sync_enter(self)
            recordingStatus = .Idle(error: nil)
            objc_sync_exit(self)

        }

    }
}


// MARK: SampleBufferDelegate Methods

extension CaptureSessionAssetWriterCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    public func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {

        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)

        if connection == videoConnection {

            if outputVideoFormatDescription == nil {

                // Don't render the first sample buffer.
                // This gives us one frame interval (33ms at 30fps) for setupVideoPipelineWithInputFormatDescription: to complete.
                // Ideally this would be done asynchronously to ensure frames don't back up on slower devices.

                // outputVideoFormatDescription should be updated whenever video configuration is changed (frame rate, etc.)

                outputVideoFormatDescription = formatDescription

            } else {

                outputVideoFormatDescription = formatDescription;

                if recordingStatus == .Recording {
                    assetWriterCoordinator?.appendVideoSampleBuffer(sampleBuffer)
                }

            }

        } else if connection == audioConnection {

            outputAudioFormatDescription = formatDescription

            if recordingStatus == .Recording {
                assetWriterCoordinator?.appendAudioSampleBuffer(sampleBuffer)
            }

        }
    }
}


// MARK: Private Methods

extension CaptureSessionAssetWriterCoordinator {

    private func fetchConnections(fromVideoDataOutput videoDataOutput: AVCaptureVideoDataOutput, andAudioDataOutput audioDataOutput: AVCaptureAudioDataOutput) throws -> (videoConnection: AVCaptureConnection!, audioConnection: AVCaptureConnection!) {

        guard let unwrappedVideoConnection = videoDataOutput.connectionWithMediaType(AVMediaTypeVideo) else {
            throw MedusaError.CaptureDeviceError
        }

        guard let unwrappedAudioConnection = audioDataOutput.connectionWithMediaType(AVMediaTypeAudio) else {
            throw MedusaError.AudioDeviceError
        }

        if unwrappedVideoConnection.supportsVideoStabilization {
            unwrappedVideoConnection.preferredVideoStabilizationMode = .Auto
        }

        return (videoConnection: unwrappedVideoConnection, audioConnection: unwrappedAudioConnection)

    }
}

