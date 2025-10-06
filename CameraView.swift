//
//  CameraView.swift
//  Baseball Tracker
//
//  Supports live camera + processing of existing video files with YOLO tracking
//  iOS 26 safe: uses async track loading and AVURLAsset
//

import SwiftUI
import AVFoundation
import Vision
import CoreML
import Photos

struct CameraView: UIViewControllerRepresentable {
    var onVideoSaved: ((URL) -> Void)? = nil
    var videoURL: URL? = nil // Optional: process existing video
    @Binding var isRecordingLive: Bool
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onVideoSaved = onVideoSaved
        vc.videoURL = videoURL
        vc.onRecordingStateChanged = { value in
            DispatchQueue.main.async {
                self.isRecordingLive = value
            }
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

class CameraViewController: UIViewController {
    // MARK: - Camera & Capture
    private let captureSession = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput!
    private var videoOutput: AVCaptureVideoDataOutput!
    private var previewLayer: CALayer! // AVCaptureVideoPreviewLayer or AVPlayerLayer
    
    // Player retained for video file preview
    private var player: AVPlayer?
    
    // MARK: - Recording
    private var isRecording = false
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: CMTime?
    
    // MARK: - Rendering / Vision state
    private let ciContext = CIContext()
    private var visionModel: VNCoreMLModel!
    private var lastObservations: [VNRecognizedObjectObservation] = []
    private var ballTrailNormalized: [CGPoint] = [] // points in Vision normalized coords (origin bottom-left)
    
    var onVideoSaved: ((URL) -> Void)?
    
    var onRecordingStateChanged: ((Bool) -> Void)?
    // Export button shown when processing a pre-recorded video
    private var exportButton: UIButton!
    
    // MARK: - CoreML / YOLO
    private var requests = [VNRequest]()
    private let allowedClasses = ["sports ball", "baseball bat", "baseball glove"]
    
    // MARK: - Overlay
    private var overlayLayer = CALayer()
    // Processing overlay UI
    private var processingOverlay: UIView?
    private var processingLabel: UILabel?
    private var processingSpinner: UIActivityIndicatorView?
    
    // Ball Trail
    private var ballTrail: [CGPoint] = []
    private let maxTrailLength = 15
    
    // Record Button
    private var recordButton: UIButton!
    
    // MARK: - Video file
    var videoURL: URL? = nil
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("CameraViewController loaded. videoURL=\(String(describing: videoURL))")
        view.backgroundColor = .black
        onRecordingStateChanged?(false)
        
        setupOverlay()
        setupModel()
        setupRecordButton()
        
        if let url = videoURL {
            processVideoFile(url)
        } else {
            setupCamera()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        overlayLayer.frame = view.bounds
        processingOverlay?.frame = view.bounds
    }
    
    // MARK: - Camera Setup
    private func setupCamera() {
        print("setupCamera (live capture) starting")
        captureSession.beginConfiguration()
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        
        // Select format with highest FPS
        if let bestFormat = device.formats.max(by: { format1, format2 in
            let max1 = format1.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let max2 = format2.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            return max1 < max2
        }) {

            do {
                try device.lockForConfiguration()
                if let maxRange = bestFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                    device.activeFormat = bestFormat
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxRange.maxFrameRate))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(maxRange.maxFrameRate))
                }
                device.unlockForConfiguration()
            } catch {
                print("Error locking camera configuration: \(error)")
            }
        }
        
        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: device)
            captureSession.addInput(videoDeviceInput)
        } catch {
            print("Error adding camera input: \(error)")
            return
        }
        
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        captureSession.addOutput(videoOutput)
        
        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        previewLayer = preview
        view.layer.insertSublayer(previewLayer, at: 0)
        
        captureSession.commitConfiguration()
        captureSession.startRunning()
    }
    
    // MARK: - Video File Processing
    private func processVideoFile(_ url: URL) {
        print("processVideoFile called with URL: \(url)")
        let asset = AVURLAsset(url: url)
        self.showProcessingOverlay(message: "Processing…")
        
        // Preview with AVPlayer
        self.player = AVPlayer(url: url)
        let playerLayer = AVPlayerLayer(player: self.player)
        playerLayer.frame = view.bounds
        playerLayer.videoGravity = .resizeAspectFill
        previewLayer = playerLayer
        view.layer.insertSublayer(previewLayer, at: 0)
        self.player?.play()
        
        // Async track loading (iOS 26)
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    await MainActor.run { self.hideProcessingOverlay() }
                    return
                }
                await MainActor.run { self.updateProcessingMessage("Analyzing & Exporting…") }
                // Continue showing live overlay analysis on screen
                self.processVideoAsset(asset, track: track)
                // Also export an annotated copy in the background
                await self.exportAnnotatedVideo(asset: asset, track: track)
            } catch {
                await MainActor.run { self.hideProcessingOverlay() }
                print("Error loading video tracks: \(error)")
            }
        }
    }
    
    private func processVideoAsset(_ asset: AVAsset, track: AVAssetTrack) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let reader = try AVAssetReader(asset: asset)
                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
                let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                reader.add(readerOutput)
                reader.startReading()
                
                while reader.status == .reading {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                       let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                        try? handler.perform(self.requests)
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                }
            } catch {
                print("Error reading video: \(error)")
            }
        }
    }
    
    // MARK: - Overlay
    private func setupOverlay() {
        overlayLayer.frame = view.bounds
        view.layer.addSublayer(overlayLayer)
    }
    
    private func showProcessingOverlay(message: String = "Processing…") {
        if processingOverlay == nil {
            let overlay = UIView(frame: view.bounds)
            overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)

            let spinner = UIActivityIndicatorView(style: .large)
            spinner.color = .white
            spinner.startAnimating()

            let label = UILabel()
            label.textColor = .white
            label.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
            label.textAlignment = .center
            label.text = message
            label.numberOfLines = 2
            label.sizeToFit()

            overlay.addSubview(spinner)
            overlay.addSubview(label)

            // Center subviews
            spinner.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),

                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor)
            ])

            view.addSubview(overlay)
            view.bringSubviewToFront(overlay)

            processingOverlay = overlay
            processingLabel = label
            processingSpinner = spinner
        } else {
            processingLabel?.text = message
            processingLabel?.sizeToFit()
        }
    }

    private func updateProcessingMessage(_ text: String) {
        processingLabel?.text = text
        processingLabel?.sizeToFit()
    }

    private func hideProcessingOverlay() {
        processingSpinner?.stopAnimating()
        processingOverlay?.removeFromSuperview()
        processingOverlay = nil
        processingLabel = nil
        processingSpinner = nil
    }
    
    private func setupModel() {
        guard let mlmodel = try? yolov8n(configuration: MLModelConfiguration()).model,
              let visionModel = try? VNCoreMLModel(for: mlmodel) else {
            fatalError("Could not load YOLOv8n model")
        }
        self.visionModel = visionModel

        let request = VNCoreMLRequest(model: visionModel) { [weak self] request, _ in
            guard let self = self else { return }
            let results = (request.results as? [VNRecognizedObjectObservation]) ?? []
            // Keep observations for recording/export compositing
            self.lastObservations = results

            // Update trail using normalized centers for the sports ball
            for obs in results {
                let label = obs.labels.first?.identifier ?? ""
                if label == "sports ball" {
                    let center = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
                    self.ballTrailNormalized.append(center)
                    if self.ballTrailNormalized.count > self.maxTrailLength { self.ballTrailNormalized.removeFirst() }
                }
            }

            // Draw UI overlays on main thread
            DispatchQueue.main.async {
                self.overlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
                for obs in results {
                    let label = obs.labels.first?.identifier ?? ""
                    if self.allowedClasses.contains(label) {
                        self.drawBoundingBox(obs.boundingBox, label: label)
                    }
                }
                self.drawBallTrail()
            }
        }
        request.imageCropAndScaleOption = .scaleFill
        self.requests = [request]
    }
    
    private func drawBoundingBox(_ rect: CGRect, label: String) {
        let x = rect.origin.x * view.bounds.width
        let y = (1 - rect.origin.y - rect.height) * view.bounds.height
        let width = rect.width * view.bounds.width
        let height = rect.height * view.bounds.height
        
        let boxLayer = CAShapeLayer()
        boxLayer.frame = CGRect(x: x, y: y, width: width, height: height)
        boxLayer.borderWidth = 2
        boxLayer.borderColor = colorForLabel(label).cgColor
        
        let textLayer = CATextLayer()
        textLayer.string = label
        textLayer.foregroundColor = colorForLabel(label).cgColor
        textLayer.fontSize = 14
        textLayer.frame = CGRect(x: 0, y: -18, width: width, height: 18)
        textLayer.contentsScale = view.traitCollection.displayScale
        boxLayer.addSublayer(textLayer)
        
        overlayLayer.addSublayer(boxLayer)
        
        if label == "sports ball" {
            let center = CGPoint(x: x + width/2, y: y + height/2)
            ballTrail.append(center)
            if ballTrail.count > maxTrailLength { ballTrail.removeFirst() }
        }
    }
    
    private func drawBallTrail() {
        guard !ballTrailNormalized.isEmpty else { return }
        let trailLayer = CALayer()
        trailLayer.frame = view.bounds

        for (i, p) in ballTrailNormalized.enumerated() {
            let x = p.x * view.bounds.width
            let y = (1 - p.y) * view.bounds.height
            let dot = CAShapeLayer()
            let radius: CGFloat = 5
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            dot.path = UIBezierPath(ovalIn: rect).cgPath
            dot.fillColor = UIColor.red.withAlphaComponent(CGFloat(i) / CGFloat(maxTrailLength)).cgColor
            trailLayer.addSublayer(dot)
        }
        overlayLayer.addSublayer(trailLayer)
    }
    
    private func colorForLabel(_ label: String) -> UIColor {
        switch label {
        case "sports ball": return .red
        case "baseball bat": return .blue
        case "baseball glove": return .green
        default: return .white
        }
    }
    
    // MARK: - Record Button
    private func setupRecordButton() {
        let size: CGFloat = 70
        recordButton = UIButton(frame: CGRect(x: view.bounds.width - size - 20,
                                              y: view.bounds.height - size - 50,
                                              width: size, height: size))
        recordButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
        recordButton.layer.cornerRadius = size / 2
        recordButton.setTitle("●", for: .normal)
        recordButton.titleLabel?.font = UIFont.systemFont(ofSize: 32)
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        view.addSubview(recordButton)
    }
    
    @objc private func toggleRecording() {
        isRecording.toggle()
        recordButton.backgroundColor = isRecording ? UIColor.systemRed : UIColor.systemRed.withAlphaComponent(0.8)
        if isRecording { startRecording() } else { stopRecording() }
        onRecordingStateChanged?(isRecording)
    }
    
    private func startRecording() {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("trackedVideo.mp4")
        try? FileManager.default.removeItem(at: outputURL)
        
        videoWriter = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(view.bounds.width),
            AVVideoHeightKey: Int(view.bounds.height)
        ]
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true
        
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(view.bounds.width),
            kCVPixelBufferHeightKey as String: Int(view.bounds.height)
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput!,
                                                                  sourcePixelBufferAttributes: attributes)
        if let writer = videoWriter, let input = videoWriterInput {
            writer.add(input)
            writer.startWriting()
            recordingStartTime = CMTime.zero
            writer.startSession(atSourceTime: recordingStartTime!)
        }
    }
    
    private func stopRecording() {
        videoWriterInput?.markAsFinished()
        videoWriter?.finishWriting { [weak self] in
            guard let self = self else { return }
            if let url = self.videoWriter?.outputURL {
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        if success { self.onVideoSaved?(url) }
                        else { print("Error saving video: \(String(describing: error))") }
                    }
                }
            }
        }
    }
    
    // MARK: - Overlay Rendering Helpers
    private func makeAnnotatedPixelBuffer(from pixelBuffer: CVPixelBuffer, observations: [VNRecognizedObjectObservation], pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)

        let baseImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let overlayCG = drawOverlayCGImage(size: size, observations: observations) else { return nil }
        let overlayCI = CIImage(cgImage: overlayCG)
        let composed = overlayCI.composited(over: baseImage)

        var outputBuffer: CVPixelBuffer?
        if let pool = pool {
            var outBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard status == kCVReturnSuccess, let out = outBuffer else { return nil }
            outputBuffer = out
        } else {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height
            ]
            var out: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
            guard status == kCVReturnSuccess, let o = out else { return nil }
            outputBuffer = o
        }

        guard let output = outputBuffer else { return nil }
        ciContext.render(composed, to: output)
        return output
    }

    private func drawOverlayCGImage(size: CGSize, observations: [VNRecognizedObjectObservation]) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Draw detections
        for obs in observations {
            let label = obs.labels.first?.identifier ?? ""
            if !allowedClasses.contains(label) { continue }

            let rect = obs.boundingBox
            let x = rect.origin.x * size.width
            let y = (1 - rect.origin.y - rect.height) * size.height
            let w = rect.width * size.width
            let h = rect.height * size.height

            ctx.setLineWidth(2)
            ctx.setStrokeColor(colorForLabel(label).cgColor)
            ctx.stroke(CGRect(x: x, y: y, width: w, height: h))

            // Label text (simple)
            let text = label as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: colorForLabel(label)
            ]
            let textSize = text.size(withAttributes: attributes)
            UIGraphicsPushContext(ctx)
            text.draw(in: CGRect(x: x, y: max(y - textSize.height, 0), width: w, height: textSize.height), withAttributes: attributes)
            UIGraphicsPopContext()
        }

        // Draw trail
        if !ballTrailNormalized.isEmpty {
            for (i, p) in ballTrailNormalized.enumerated() {
                let px = p.x * size.width
                let py = (1 - p.y) * size.height
                let radius: CGFloat = 5
                let alpha = CGFloat(i) / CGFloat(maxTrailLength)
                ctx.setFillColor(UIColor.red.withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2))
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Export Annotated Copy for Video File
    private func exportAnnotatedVideo(asset: AVAsset, track: AVAssetTrack) async {
        do {
            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(readerOutput)

            // Writer setup (async property loading)
            let naturalSize = try await track.load(.naturalSize)
            let width = Int(abs(naturalSize.width))
            let height = Int(abs(naturalSize.height))

            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("annotatedVideo.mp4")
            try? FileManager.default.removeItem(at: outputURL)

            guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return }
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
            let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            writerInput.expectsMediaDataInRealTime = false
            let preferredTransform = try await track.load(.preferredTransform)
            writerInput.transform = preferredTransform
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])

            guard writer.canAdd(writerInput) else { return }
            writer.add(writerInput)

            reader.startReading()
            writer.startWriting()

            if let sample = readerOutput.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                writer.startSession(atSourceTime: pts)
                // push back the first sample into processing by handling it below
                CMSampleBufferInvalidate(sample)
                reader.cancelReading()

                // Restart reader to process from the beginning
                let reader2 = try AVAssetReader(asset: asset)
                let readerOutput2 = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                reader2.add(readerOutput2)
                reader2.startReading()

                self.ballTrailNormalized.removeAll()

                while reader2.status == .reading {
                    guard let sbuf = readerOutput2.copyNextSampleBuffer(),
                          let px = CMSampleBufferGetImageBuffer(sbuf) else {
                        break
                    }

                    autoreleasepool {
                        // Run detection synchronously for export
                        let req = VNCoreMLRequest(model: self.visionModel)
                        let handler = VNImageRequestHandler(cvPixelBuffer: px, options: [:])
                        try? handler.perform([req])
                        let results = (req.results as? [VNRecognizedObjectObservation]) ?? []

                        // Update trail from results
                        for obs in results {
                            let label = obs.labels.first?.identifier ?? ""
                            if label == "sports ball" {
                                let c = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
                                self.ballTrailNormalized.append(c)
                                if self.ballTrailNormalized.count > self.maxTrailLength { self.ballTrailNormalized.removeFirst() }
                            }
                        }

                        // Compose annotated frame
                        let time = CMSampleBufferGetPresentationTimeStamp(sbuf)

                        // Ensure writer is ready
                        while !writerInput.isReadyForMoreMediaData { usleep(1000) }

                        if let annotated = self.makeAnnotatedPixelBuffer(from: px, observations: results, pool: adaptor.pixelBufferPool) {
                            _ = adaptor.append(annotated, withPresentationTime: time)
                        } else {
                            _ = adaptor.append(px, withPresentationTime: time)
                        }
                    }
                }

                writerInput.markAsFinished()
                await writer.finishWriting()
                if writer.status == .completed {
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                        }
                        print("Annotated video saved to Photos: \(outputURL)")
                        await MainActor.run { self.hideProcessingOverlay() }
                    } catch {
                        await MainActor.run { self.hideProcessingOverlay() }
                        print("Error saving annotated video: \(error)")
                    }
                } else if writer.status == .failed {
                    await MainActor.run { self.hideProcessingOverlay() }
                    print("Writer failed: \(String(describing: writer.error))")
                }
            }
        } catch {
            await MainActor.run { self.hideProcessingOverlay() }
            print("Error exporting annotated video: \(error)")
        }
    }
}

// MARK: - Video Frame Capture (Live Camera)
extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard videoURL == nil else { return } // Skip if processing video file
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform(self.requests)

        if isRecording,
           let input = videoWriterInput,
           input.isReadyForMoreMediaData {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let annotated = makeAnnotatedPixelBuffer(from: pixelBuffer, observations: lastObservations, pool: pixelBufferAdaptor?.pixelBufferPool) {
                pixelBufferAdaptor?.append(annotated, withPresentationTime: time)
            } else {
                // Fallback to raw frame if annotation fails
                pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: time)
            }
        }
    }
}

