// Runs Clocked's detectors (Vision face, landmarks, body and hand pose, and the YOLOv3-Tiny phone model)
// over every frame of a video and writes the results as JSON for the site's Developer View section.
// Build (top-level code needs the file to be called main.swift): cp extract.swift /tmp/x/main.swift && swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk /tmp/x/main.swift -o extract
// Usage: ./extract <video> <out.json> <YOLOv3Tiny.mlmodelc> [fps=30]
import AVFoundation
import CoreML
import Foundation
import Vision

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: extract <video> <out.json> <model.mlmodelc> [fps]"); exit(1) }
let videoURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let modelURL = URL(fileURLWithPath: args[3])
let fps = args.count > 4 ? Double(args[4])! : 30

let yolo = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))

func r(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
// Vision is bottom-left; the site draws top-left.
func pt(_ p: CGPoint) -> [Double] { [r(p.x), r(1 - p.y)] }
func box(_ b: CGRect) -> [Double] { [r(b.minX), r(1 - b.maxY), r(b.width), r(b.height)] }

let asset = AVURLAsset(url: videoURL)
let track = try await asset.loadTracks(withMediaType: .video).first!
let size = try await track.load(.naturalSize)
let duration = try await asset.load(.duration).seconds
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(output)
reader.startReading()

var frames: [[String: Any]] = []
var nextT = 0.0
while let sample = output.copyNextSampleBuffer() {
  let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
  guard t + 0.0001 >= nextT, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
  nextT += 1 / fps

  let face = VNDetectFaceRectanglesRequest(); face.revision = VNDetectFaceRectanglesRequestRevision3
  let marks = VNDetectFaceLandmarksRequest()
  let body = VNDetectHumanBodyPoseRequest()
  let hands = VNDetectHumanHandPoseRequest(); hands.maximumHandCount = 2
  let phone = VNCoreMLRequest(model: yolo); phone.imageCropAndScaleOption = .scaleFill
  try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([face, marks, body, hands, phone])

  var f: [String: Any] = ["t": (t * 1000).rounded() / 1000]
  if let o = face.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
    f["face"] = box(o.boundingBox)
    if let p = o.pitch { f["pitch"] = r(CGFloat(p.doubleValue)) }
    if let y = o.yaw { f["yaw"] = r(CGFloat(y.doubleValue)) }
  }
  if let o = marks.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }), let l = o.landmarks {
    let b = o.boundingBox
    func img(_ region: VNFaceLandmarkRegion2D?) -> [[Double]] {
      (region?.normalizedPoints ?? []).map { pt(CGPoint(x: b.minX + $0.x * b.width, y: b.minY + $0.y * b.height)) }
    }
    f["eyes"] = [img(l.leftEye), img(l.rightEye)]
    f["pupils"] = img(l.leftPupil) + img(l.rightPupil)
    f["lips"] = img(l.outerLips)
  }
  if let o = body.results?.first, let pts = try? o.recognizedPoints(.all) {
    var joints: [String: [Double]] = [:]
    for (name, p) in pts where p.confidence > 0.3 { joints[name.rawValue.rawValue] = pt(p.location) }
    f["body"] = joints
  }
  f["hands"] = (hands.results ?? []).compactMap { h -> [[Double]]? in
    guard let pts = try? h.recognizedPoints(.all) else { return nil }
    let good = pts.values.filter { $0.confidence > 0.3 }
    return good.isEmpty ? nil : good.map { pt($0.location) }
  }
  f["phones"] = (phone.results as? [VNRecognizedObjectObservation] ?? []).compactMap { o -> [Double]? in
    guard let l = o.labels.first(where: { $0.identifier == "cell phone" }), l.confidence > 0.15 else { return nil }
    return [r(CGFloat(l.confidence))] + box(o.boundingBox)
  }
  frames.append(f)
  if frames.count % 30 == 0 { FileHandle.standardError.write("\(String(format: "%.1f", t)) / \(String(format: "%.1f", duration)) s\n".data(using: .utf8)!) }
}

let json: [String: Any] = ["fps": fps, "width": Int(size.width), "height": Int(size.height), "frames": frames]
try JSONSerialization.data(withJSONObject: json).write(to: outURL)
print("wrote \(frames.count) frames to \(outURL.path)")
