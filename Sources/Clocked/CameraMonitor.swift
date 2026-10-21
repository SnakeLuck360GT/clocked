import AVFoundation
import CoreImage
import CoreML
import Vision

/// What one camera frame showed. This is all that leaves the analysis queue: the frame itself is dropped immediately.
struct CameraSample: Equatable {
    var facePresent = false
    /// Head pitch in radians (only meaningful relative to a baseline).
    var pitch: Double?
    /// Highest "phone" confidence found in the frame (0...1).
    var phoneConfidence: Float = 0
    /// The phone overlaps a detected hand, i.e. it's being held.
    var phoneInHand = false
    /// The phone sits entirely in the bottom strip of the frame (probably lying on the desk).
    var phoneLowInFrame = false
    var handCount = 0
    /// Head/shoulder posture numbers (nil when nobody is in view).
    var posture: PostureFeatures?
    /// Mouth shape, for spotting a smile (nil when no face).
    var expression: ExpressionFeatures?
    /// The frame and everything found in it, only while the Developer View is open.
    var debug: DebugFrame?
}

/// What the detector saw in one frame, for the Developer View. All geometry is in Vision's normalised image
/// coordinates (0…1, origin at the bottom left). Kept in memory only; the previous one is dropped.
final class DebugFrame: Equatable {
    struct Phone { var confidence: Float; var box: CGRect; var zoomed: Bool }
    let image: CGImage
    var faceBox: CGRect?
    var pitch: Double?
    var yaw: Double?
    var eyes: [[CGPoint]] = []
    var pupils: [CGPoint] = []
    var lips: [CGPoint] = []
    var joints: [String: CGPoint] = [:]
    var hands: [[CGPoint]] = []
    var phones: [Phone] = []
    var zoomRegion: CGRect = .zero

    init(image: CGImage) { self.image = image }
    static func == (a: DebugFrame, b: DebugFrame) -> Bool { a === b }
}

enum CameraError: LocalizedError {
    case noCamera, cannotConfigure
    var errorDescription: String? {
        switch self {
        case .noCamera: return "No camera found"
        case .cannotConfigure: return "Couldn't start the camera"
        }
    }
}

/// Runs the camera only while started, and analyses at most one low-res frame every `sampleInterval` seconds,
/// entirely on-device with Apple's Vision framework. Nothing is recorded or written to disk.
final class CameraMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onSample: ((CameraSample) -> Void)?
    var sampleInterval: TimeInterval = 1
    /// Set while the Developer View is open: also hand over the frame and the detected geometry.
    var debugCapture = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.analysis", qos: .utility)
    private var lastAnalysis = Date.distantPast
    private lazy var phoneDetector: VNCoreMLRequest? = Self.loadPhoneDetector()
    /// The same detector run again on the lower 60% of the frame, where a phone held at chest height or in
    /// the lap shows up small and is easy to miss at full-frame scale.
    private lazy var zoomedPhoneDetector: VNCoreMLRequest? = {
        let request = Self.loadPhoneDetector()
        request?.regionOfInterest = Self.zoomRegion
        return request
    }()
    private static let zoomRegion = CGRect(x: 0, y: 0, width: 1, height: 0.6)

    /// True when the bundled object detector is available (more accurate than the generic image classifier).
    var hasObjectDetector: Bool { Bundle.main.url(forResource: "YOLOv3Tiny", withExtension: "mlmodelc") != nil }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                try configure()
                lastAnalysis = .distantPast
                session.startRunning()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Stops capture and releases the camera (the green light turns off).
    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
        }
    }

    private func configure() throws {
        if !session.inputs.isEmpty && !session.outputs.isEmpty { return }
        // Half-configured from an earlier failure: start clean.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        // Prefer the Mac's own camera so we never pick an iPhone via Continuity Camera.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? discovery.devices.first
                ?? AVCaptureDevice.default(for: .video) else { throw CameraError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        else if session.canSetSessionPreset(.low) { session.sessionPreset = .low }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotConfigure }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.cannotConfigure }
        session.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= sampleInterval,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        let sample = analyze(pixels)
        onSample?(sample)
        // `pixels` goes out of scope here; nothing is retained.
    }

    private func analyze(_ pixels: CVPixelBuffer) -> CameraSample {
        let faceRequest = VNDetectFaceRectanglesRequest()
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3 // includes head pitch
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2
        let classifyRequest = VNClassifyImageRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()

        var requests: [VNRequest] = [faceRequest, handRequest, bodyRequest, landmarksRequest]
        if let phoneDetector {
            requests.append(phoneDetector)
            if let zoomedPhoneDetector { requests.append(zoomedPhoneDetector) }
        } else {
            requests.append(classifyRequest)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        try? handler.perform(requests)

        var sample = CameraSample()

        let face = faceRequest.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) })
        if let face {
            sample.facePresent = true
            sample.pitch = face.pitch?.doubleValue
        }
        sample.posture = Self.posture(body: bodyRequest.results?.first, face: face)
        if let landmarks = landmarksRequest.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) })?.landmarks {
            let openness = [landmarks.leftEye, landmarks.rightEye].compactMap { eye -> Double? in
                guard let points = eye?.normalizedPoints, points.count >= 4 else { return nil }
                let xs = points.map(\.x), ys = points.map(\.y)
                let width = xs.max()! - xs.min()!
                return width > 0 ? Double((ys.max()! - ys.min()!) / width) : nil
            }
            if !openness.isEmpty { sample.posture?.eyeOpen = openness.reduce(0, +) / Double(openness.count) }
            sample.posture?.gazeY = Self.gaze(landmarks)
            sample.expression = Self.expression(outer: landmarks.outerLips, inner: landmarks.innerLips)
        }

        let handBoxes: [CGRect] = (handRequest.results ?? []).compactMap { hand in
            guard let points = try? hand.recognizedPoints(.all).values.filter({ $0.confidence > 0.3 }),
                  !points.isEmpty else { return nil }
            let xs = points.map(\.location.x), ys = points.map(\.location.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .insetBy(dx: -0.06, dy: -0.06)
        }
        sample.handCount = handBoxes.count

        if phoneDetector != nil {
            func phones(_ request: VNCoreMLRequest?, region: CGRect) -> [(Float, CGRect)] {
                (request?.results as? [VNRecognizedObjectObservation] ?? []).compactMap { obs in
                    guard let label = obs.labels.first(where: { $0.identifier == "cell phone" }) else { return nil }
                    // Boxes from a region request are relative to that region; map back to the full frame.
                    let b = obs.boundingBox
                    let box = CGRect(x: region.minX + b.minX * region.width, y: region.minY + b.minY * region.height,
                                     width: b.width * region.width, height: b.height * region.height)
                    return (label.confidence, box)
                }
            }
            let full = phones(phoneDetector, region: CGRect(x: 0, y: 0, width: 1, height: 1))
            let zoomed = phones(zoomedPhoneDetector, region: Self.zoomRegion)
            let phones = full + zoomed
            debugPhones = full.map { DebugFrame.Phone(confidence: $0.0, box: $0.1, zoomed: false) }
                + zoomed.map { DebugFrame.Phone(confidence: $0.0, box: $0.1, zoomed: true) }
            if let best = phones.max(by: { $0.0 < $1.0 }) {
                sample.phoneConfidence = best.0
                sample.phoneInHand = handBoxes.contains { $0.intersects(best.1) }
                sample.phoneLowInFrame = best.1.maxY < 0.3
            }
        } else if let phone = classifyRequest.results?.first(where: { $0.identifier == "phone" }) {
            sample.phoneConfidence = phone.confidence
            sample.phoneInHand = sample.handCount > 0
        }

        if debugCapture, let image = ciContext.createCGImage(CIImage(cvPixelBuffer: pixels), from: CIImage(cvPixelBuffer: pixels).extent) {
            let frame = DebugFrame(image: image)
            frame.faceBox = face?.boundingBox
            frame.pitch = face?.pitch?.doubleValue
            frame.yaw = face?.yaw?.doubleValue
            if let observation = landmarksRequest.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) }),
               let landmarks = observation.landmarks {
                let box = observation.boundingBox
                func toImage(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                    (region?.normalizedPoints ?? []).map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
                }
                frame.eyes = [toImage(landmarks.leftEye), toImage(landmarks.rightEye)].filter { !$0.isEmpty }
                frame.pupils = toImage(landmarks.leftPupil) + toImage(landmarks.rightPupil)
                frame.lips = toImage(landmarks.outerLips)
            }
            if let body = bodyRequest.results?.first, let points = try? body.recognizedPoints(.all) {
                for (joint, point) in points where point.confidence > 0.2 {
                    frame.joints[joint.rawValue.rawValue] = point.location
                }
            }
            frame.hands = (handRequest.results ?? []).compactMap { hand in
                (try? hand.recognizedPoints(.all).values.filter { $0.confidence > 0.3 }.map(\.location))
            }
            frame.phones = debugPhones
            frame.zoomRegion = phoneDetector != nil ? Self.zoomRegion : .zero
            sample.debug = frame
        }
        debugPhones = []
        return sample
    }

    private var debugPhones: [DebugFrame.Phone] = []

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// Where the pupils sit vertically inside the eye outlines: about 0.5 looking ahead, lower when looking down.
    /// Catches looking down at a phone even when the head barely tilts.
    private static func gaze(_ landmarks: VNFaceLandmarks2D) -> Double? {
        let pairs: [(VNFaceLandmarkRegion2D?, VNFaceLandmarkRegion2D?)] = [(landmarks.leftEye, landmarks.leftPupil),
                                                                             (landmarks.rightEye, landmarks.rightPupil)]
        let values = pairs.compactMap { eye, pupil -> Double? in
            guard let outline = eye?.normalizedPoints, outline.count >= 4, let p = pupil?.normalizedPoints.first else { return nil }
            let ys = outline.map(\.y)
            let height = ys.max()! - ys.min()!
            guard height > 0.01 else { return nil } // eye nearly closed: no reliable reading
            return Double((p.y - ys.min()!) / height)
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func expression(outer: VNFaceLandmarkRegion2D?, inner: VNFaceLandmarkRegion2D?) -> ExpressionFeatures? {
        guard let points = outer?.normalizedPoints, points.count >= 6 else { return nil }
        guard let left = points.min(by: { $0.x < $1.x }), let right = points.max(by: { $0.x < $1.x }) else { return nil }
        let width = Double(right.x - left.x)
        guard width > 0.05 else { return nil }
        let ys = points.map { Double($0.y) }
        let middle = (ys.max()! + ys.min()!) / 2
        let corners = Double(left.y + right.y) / 2
        var open = 0.0
        if let innerPoints = inner?.normalizedPoints, innerPoints.count >= 4 {
            let iy = innerPoints.map { Double($0.y) }
            open = (iy.max()! - iy.min()!) / width
        }
        return ExpressionFeatures(mouthCurve: (corners - middle) / width, mouthWidth: width, mouthOpen: open)
    }

    private static func posture(body: VNHumanBodyPoseObservation?, face: VNFaceObservation?) -> PostureFeatures? {
        var f = PostureFeatures(faceVisible: face == nil ? 0 : 1)
        if let face {
            f.faceY = face.boundingBox.midY
            f.pitch = face.pitch?.doubleValue
            f.yaw = face.yaw?.doubleValue
        }
        if let body, let points = try? body.recognizedPoints(.all) {
            func p(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let point = points[joint], point.confidence > 0.2 else { return nil }
                return point.location
            }
            func mid(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
                switch (a, b) {
                case let (a?, b?): return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                default: return a ?? b
                }
            }
            let ls = p(.leftShoulder), rs = p(.rightShoulder)
            let eyes = mid(p(.leftEye), p(.rightEye)), ears = mid(p(.leftEar), p(.rightEar)), nose = p(.nose)
            if let shoulders = mid(ls, rs) { f.shoulderY = shoulders.y }
            // Normalise by shoulder width (or eye spacing × 3 if shoulders are out of view).
            var scale: Double?
            if let ls, let rs { scale = hypot(ls.x - rs.x, ls.y - rs.y) }
            else if let l = p(.leftEye), let r = p(.rightEye) { scale = hypot(l.x - r.x, l.y - r.y) * 3 }
            if let scale, scale > 0.01 {
                if let eyes, let ears { f.eyeEar = (eyes.y - ears.y) / scale }
                if let nose, let shoulders = mid(ls, rs), ls != nil || rs != nil { f.noseShoulder = (nose.y - shoulders.y) / scale }
            }
        }
        return f.hasPerson ? f : nil
    }

    private static func loadPhoneDetector() -> VNCoreMLRequest? {
        guard let url = Bundle.main.url(forResource: "YOLOv3Tiny", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url),
              let vnModel = try? VNCoreMLModel(for: model) else { return nil }
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
        return request
    }
}
