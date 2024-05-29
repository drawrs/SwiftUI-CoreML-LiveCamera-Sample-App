import AVFoundation
import SwiftUI
import os.log

final class ScanViewModel: ObservableObject {
    let camera = Camera()
    
    @Published var viewfinderImage: Image?
    @Published var thumbnailImage: Image?
    @Published var predictionLabel: String?
    
    var isPhotosLoaded = false
    
    init() {
        Task {
            await handleCameraPreviews()
        }
    }
    
    func handleCameraPreviews() async {
        let imageStream = camera.previewStream
            .map { $0.image }
        
        for await image in imageStream {
            Task { @MainActor in
                viewfinderImage = image
            }
        }
    }
    
}

fileprivate extension CIImage {
    var image: Image? {
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(self, from: self.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}

fileprivate extension Image.Orientation {

    init(_ cgImageOrientation: CGImagePropertyOrientation) {
        switch cgImageOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        }
    }
}

fileprivate let logger = Logger(subsystem: "com.apple.swiftplaygroundscontent.capturingphotos", 
                                category: "ScanViewModel")
