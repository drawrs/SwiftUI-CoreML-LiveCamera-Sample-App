import AVFoundation
import CoreML
import CoreImage
import UIKit
import os.log

class Camera: NSObject {
    private let captureSession = AVCaptureSession()
    private var isCaptureSessionConfigured = false
    private var deviceInput: AVCaptureDeviceInput?
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var sessionQueue = DispatchQueue(label: "session queue")
    
    // CoreML model
    private lazy var coreMLModel: Resnet50? = {
        do {
            let configuration = MLModelConfiguration()
            return try Resnet50(configuration: configuration)
        } catch {
            logger.error("Failed to initialize Resnet50 model: \(error.localizedDescription)")
            return nil
        }
    }()
    
    var predictionsResult: String = ""
    
    /// Only support back camera
    var exifOrientationFromDeviceOrientation: Int32 {
        let exifOrientation: DeviceOrientation
        enum DeviceOrientation: Int32 {
            case top0ColLeft = 1
            case top0ColRight = 2
            case bottom0ColRight = 3
            case bottom0ColLeft = 4
            case left0ColTop = 5
            case right0ColTop = 6
            case right0ColBottom = 7
            case left0ColBottom = 8
        }
        switch UIDevice.current.orientation {
        case .portraitUpsideDown:
            exifOrientation = .left0ColBottom
        case .landscapeLeft:
            exifOrientation = .top0ColLeft
        case .landscapeRight:
            exifOrientation = .bottom0ColRight
        default:
            exifOrientation = .right0ColTop
        }
        return exifOrientation.rawValue
    }
    
    private var allCaptureDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInWideAngleCamera, .builtInUltraWideCamera], mediaType: .video, position: .unspecified).devices
    }
    
    private var frontCaptureDevices: [AVCaptureDevice] {
        allCaptureDevices.filter { $0.position == .front }
    }
    
    private var backCaptureDevices: [AVCaptureDevice] {
        allCaptureDevices.filter { $0.position == .back }
    }
    
    private var captureDevices: [AVCaptureDevice] {
        #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
        return allCaptureDevices
        #else
        return [backCaptureDevices.first, frontCaptureDevices.first].compactMap { $0 }
        #endif
    }
    
    private var availableCaptureDevices: [AVCaptureDevice] {
        captureDevices.filter { $0.isConnected && !$0.isSuspended }
    }
    
    private var captureDevice: AVCaptureDevice? {
        didSet {
            guard let captureDevice = captureDevice else { return }
            logger.debug("Using capture device: \(captureDevice.localizedName)")
            updateSessionForCaptureDevice(captureDevice)
        }
    }
    
    var isRunning: Bool {
        captureSession.isRunning
    }
    
    var isUsingFrontCaptureDevice: Bool {
        guard let captureDevice = captureDevice else { return false }
        return frontCaptureDevices.contains(captureDevice)
    }
    
    var isUsingBackCaptureDevice: Bool {
        guard let captureDevice = captureDevice else { return false }
        return backCaptureDevices.contains(captureDevice)
    }
    
    private var addToPhotoStream: ((AVCapturePhoto) -> Void)?
    private var addToPreviewStream: ((CIImage) -> Void)?
    var isPreviewPaused = false
    
    lazy var previewStream: AsyncStream<CIImage> = {
        AsyncStream { continuation in
            addToPreviewStream = { ciImage in
                if !self.isPreviewPaused {
                    continuation.yield(ciImage)
                }
            }
        }
    }()
    
    lazy var photoStream: AsyncStream<AVCapturePhoto> = {
        AsyncStream { continuation in
            addToPhotoStream = { photo in
                continuation.yield(photo)
            }
        }
    }()
    
    // MARK: CoreML code
    func handleImageBufferWithCoreML(imageBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(imageBuffer), let coreMLModel = coreMLModel else {
            return
        }
        do {
            let prediction = try coreMLModel.prediction(image: resize(pixelBuffer: pixelBuffer)!)
            if let prob = prediction.classLabelProbs[prediction.classLabel] {
                let result = "\(prediction.classLabel) \(String(describing: prob))"
                self.predictionsResult = result
                print(result)
            }
        } catch {
            logger.error("Unexpected error occurred during prediction: \(error.localizedDescription)")
        }
    }
    
    /// Resize CVPixelBuffer to (224, 224)
    func resize(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let imageSide = 224
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let transform = CGAffineTransform(scaleX: CGFloat(imageSide) / CGFloat(CVPixelBufferGetWidth(pixelBuffer)), y: CGFloat(imageSide) / CGFloat(CVPixelBufferGetHeight(pixelBuffer)))
        ciImage = ciImage.transformed(by: transform).cropped(to: CGRect(x: 0, y: 0, width: imageSide, height: imageSide))
        let ciContext = CIContext()
        var resizeBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, imageSide, imageSide, CVPixelBufferGetPixelFormatType(pixelBuffer), nil, &resizeBuffer)
        ciContext.render(ciImage, to: resizeBuffer!)
        return resizeBuffer
    }
    
    override init() {
        super.init()
        initialize()
    }
    
    private func initialize() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(updateForDeviceOrientation), name: UIDevice.orientationDidChangeNotification, object: nil)
    }
    
    private func configureCaptureSession(completionHandler: (_ success: Bool) -> Void) {
        var success = false
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
            completionHandler(success)
        }
        
        guard
            let captureDevice = captureDevice,
            let deviceInput = try? AVCaptureDeviceInput(device: captureDevice)
        else {
            logger.error("Failed to obtain video input.")
            return
        }
        
        let photoOutput = AVCapturePhotoOutput()
        let videoOutput = AVCaptureVideoDataOutput()
        
        // Necessary settings for CoreML input
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)]
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "VideoDataOutputQueue"))
  
        guard captureSession.canAddInput(deviceInput), captureSession.canAddOutput(photoOutput), captureSession.canAddOutput(videoOutput) else {
            logger.error("Unable to add input/output to capture session.")
            return
        }
        
        captureSession.addInput(deviceInput)
        captureSession.addOutput(photoOutput)
        captureSession.addOutput(videoOutput)
        
        self.deviceInput = deviceInput
        self.photoOutput = photoOutput
        self.videoOutput = videoOutput
        
        photoOutput.maxPhotoQualityPrioritization = .balanced
        
        updateMaxPhotoDimensions()
        updateVideoOutputConnection()
        
        isCaptureSessionConfigured = true
        success = true
    }
    
    private func checkAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            logger.debug("Camera access authorized.")
            return true
        case .notDetermined:
            logger.debug("Camera access not determined.")
            sessionQueue.suspend()
            let status = await AVCaptureDevice.requestAccess(for: .video)
            sessionQueue.resume()
            return status
        case .denied, .restricted:
            logger.debug("Camera access denied or restricted.")
            return false
        @unknown default:
            return false
        }
    }
    
    private func deviceInputFor(device: AVCaptureDevice?) -> AVCaptureDeviceInput? {
        guard let validDevice = device else { return nil }
        do {
            return try AVCaptureDeviceInput(device: validDevice)
        } catch {
            logger.error("Error getting capture device input: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func updateSessionForCaptureDevice(_ captureDevice: AVCaptureDevice) {
        guard isCaptureSessionConfigured else { return }
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.inputs.forEach { input in
            if let deviceInput = input as? AVCaptureDeviceInput {
                captureSession.removeInput(deviceInput)
            }
        }
        
        if let deviceInput = deviceInputFor(device: captureDevice), captureSession.canAddInput(deviceInput) {
            captureSession.addInput(deviceInput)
        }
        
        updateMaxPhotoDimensions()
        updateVideoOutputConnection()
    }
    
    private func updateVideoOutputConnection() {
        if let videoOutput = videoOutput, let videoOutputConnection = videoOutput.connection(with: .video) {
            if videoOutputConnection.isVideoMirroringSupported {
                videoOutputConnection.isVideoMirrored = isUsingFrontCaptureDevice
            }
        }
    }
    
    private func updateMaxPhotoDimensions() {
        guard let captureDevice = captureDevice, let photoOutput = photoOutput else { return }
        
        if let highestSupportedPhotoDimensions = captureDevice.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = highestSupportedPhotoDimensions
        }
    }
    
    func start() async {
        let authorized = await checkAuthorization()
        guard authorized else {
            logger.error("Camera access was not authorized.")
            return
        }
        
        if isCaptureSessionConfigured {
            if !captureSession.isRunning {
                sessionQueue.async { [self] in
                    self.captureSession.startRunning()
                }
            }
            return
        }
        
        sessionQueue.async { [self] in
            if captureDevice == nil {
                captureDevice = availableCaptureDevices.first ?? AVCaptureDevice.default(for: .video)
            }
            
            self.configureCaptureSession { success in
                guard success else { return }
                self.captureSession.startRunning()
            }
        }
    }
    
    func stop() {
        guard isCaptureSessionConfigured else { return }
        
        if captureSession.isRunning {
            sessionQueue.async {
                self.captureSession.stopRunning()
            }
        }
    }
    
    func switchCaptureDevice() {
        sessionQueue.async {
            let availableCaptureDevices = self.availableCaptureDevices
            if let captureDevice = self.captureDevice, let index = availableCaptureDevices.firstIndex(of: captureDevice) {
                let nextIndex = (index + 1) % availableCaptureDevices.count
                self.captureDevice = availableCaptureDevices[nextIndex]
            } else {
                self.captureDevice = AVCaptureDevice.default(for: .video)
            }
        }
    }
    
    @objc
    func updateForDeviceOrientation() {
        // TODO: Figure out if we need this for anything.
    }
    
    private func videoOrientationFor(_ deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
        switch deviceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }
    
    func takePhoto() {
        guard let photoOutput = self.photoOutput else { return }
        
        sessionQueue.async {
            var photoSettings = AVCapturePhotoSettings()
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }
            
            let isFlashAvailable = self.deviceInput?.device.isFlashAvailable ?? false
            photoSettings.flashMode = isFlashAvailable ? .auto : .off
            if let previewPhotoPixelFormatType = photoSettings.availablePreviewPhotoPixelFormatTypes.first {
                photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPhotoPixelFormatType]
            }
            photoSettings.photoQualityPrioritization = .balanced
            
            if let photoOutputVideoConnection = photoOutput.connection(with: .video),
               let videoOrientation = self.videoOrientationFor(.portrait),
               photoOutputVideoConnection.isVideoOrientationSupported {
                photoOutputVideoConnection.videoOrientation = videoOrientation
            }
            
            photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            logger.error("Error capturing photo: \(error.localizedDescription)")
            return
        }
        
        addToPhotoStream?(photo)
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        
        if connection.isVideoOrientationSupported,
           let videoOrientation = videoOrientationFor(.portrait) {
            connection.videoOrientation = videoOrientation
        }
        
        // CoreML code
        DispatchQueue.main.async {
            self.handleImageBufferWithCoreML(imageBuffer: sampleBuffer)
        }

        addToPreviewStream?(CIImage(cvPixelBuffer: pixelBuffer))
    }
}

fileprivate extension UIScreen {
    var orientation: UIDeviceOrientation {
        let point = coordinateSpace.convert(CGPoint.zero, to: fixedCoordinateSpace)
        if point == CGPoint.zero {
            return .portrait
        } else if point.x != 0 && point.y != 0 {
            return .portraitUpsideDown
        } else if point.x == 0 && point.y != 0 {
            return .landscapeRight
        } else if point.x != 0 && point.y == 0 {
            return .landscapeLeft
        } else {
            return .unknown
        }
    }
}

fileprivate let logger = Logger(subsystem: "com.apple.swiftplaygroundscontent.capturingphotos", category: "Camera")
