import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "com.yellowsense.uidai.FingerprintSdkPlugin") {
      FingerprintSdkPlugin.register(with: registrar)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

public class FingerprintSdkPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.yellowsense.uidai/fingerprint_sdk",
      binaryMessenger: registrar.messenger()
    )
    let instance = FingerprintSdkPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "processImageOffline":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Arguments missing", details: nil))
        return
      }

      var imageData: Data? = nil
      if let typedData = args["imageBytes"] as? FlutterStandardTypedData {
        imageData = typedData.data
      } else if let rawData = args["imageBytes"] as? Data {
        imageData = rawData
      }

      let startTime = CFAbsoluteTimeGetCurrent()

      guard let bytes = imageData, let image = UIImage(data: bytes) else {
        result(FlutterError(code: "DECODE_ERROR", message: "Failed to decode image data", details: nil))
        return
      }

      let quality = self.assessQuality(image: image)
      let liveness = self.assessLiveness(image: image)
      let minutiae = self.extractMinutiae(image: image)
      let isFingerDetected = (minutiae.count >= 5 || quality.blurScore >= 25.0) && (quality.brightness >= 30.0 && quality.brightness <= 235.0)
      let isoBase64 = self.generateIsoTemplate(minutiae: minutiae, width: Int(image.size.width), height: Int(image.size.height))
      let b64Image = bytes.base64EncodedString()
      let execTime = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

      let resolvedGuidance = isFingerDetected ? quality.guidance : "No finger detected - place finger inside oval"

      let resultMap: [String: Any] = [
        "success": true,
        "message": isFingerDetected ? "iOS Native Pipeline successful" : "Low skin texture contrast",
        "total_execution_time_ms": execTime,
        "is_finger_detected": isFingerDetected,
        "blur_score": quality.blurScore,
        "brightness": quality.brightness,
        "glare_detected": quality.glareDetected,
        "is_live": liveness.isLive,
        "liveness_score": liveness.score,
        "minutiae_count": minutiae.count,
        "iso_template": isoBase64,
        "cropped_image": b64Image,
        "preprocessed_image": b64Image,
        "guidance": resolvedGuidance,
        "minutiae_list": minutiae.map { [
          "x": $0.x,
          "y": $0.y,
          "direction": $0.direction,
          "type": $0.type,
          "quality": 0.9
        ] }
      ]
      result(resultMap)

    case "verifyOffline":
      guard let args = call.arguments as? [String: Any],
            let m1 = args["minutiae1"] as? [[String: Any]],
            let m2 = args["minutiae2"] as? [[String: Any]] else {
        let mResult = self.compareMinutiae(m1: [], m2: [])
        result([
          "matched": false,
          "confidence": 0.0,
          "match_count": 0,
          "execution_time_ms": mResult.execTimeMs,
          "message": "Missing minutiae templates"
        ])
        return
      }

      let mResult = self.compareMinutiae(m1: m1, m2: m2)
      result([
        "matched": mResult.matched,
        "confidence": mResult.confidence,
        "match_count": mResult.matchCount,
        "execution_time_ms": mResult.execTimeMs,
        "message": mResult.matched ? "Biometric Match Verified" : "Biometric Match Failed"
      ])

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Native iOS Quality & Biometric Helpers
  private struct QualityResult {
    let blurScore: Double
    let brightness: Double
    let glareDetected: Bool
    let guidance: String
  }

  private struct MinutiaPoint {
    let x: Int
    let y: Int
    let direction: Double
    let type: String
  }

  private struct RawPixelData {
    let bytes: [UInt8]
    let width: Int
    let height: Int
  }

  private func extractRawPixels(image: UIImage) -> RawPixelData? {
    let cgImage: CGImage?
    if let directCg = image.cgImage {
      cgImage = directCg
    } else if let ciImage = image.ciImage ?? CIImage(image: image) {
      cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent)
    } else {
      cgImage = nil
    }

    guard let cg = cgImage else { return nil }
    let width = cg.width
    let height = cg.height
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var rawData = [UInt8](repeating: 0, count: width * height)

    guard let context = CGContext(
      data: &rawData,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }

    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RawPixelData(bytes: rawData, width: width, height: height)
  }

  private func assessQuality(image: UIImage) -> QualityResult {
    guard let raw = extractRawPixels(image: image) else {
      return QualityResult(blurScore: 0.0, brightness: 0.0, glareDetected: false, guidance: "Image decode error")
    }

    let width = raw.width
    let height = raw.height
    let pixels = raw.bytes

    var sum: Double = 0
    var glarePixels = 0
    let total = Double(pixels.count)

    for p in pixels {
      sum += Double(p)
      if p > 250 { glarePixels += 1 }
    }

    let brightnessMean = total > 0 ? (sum / total) : 0.0
    let hasGlare = total > 0 ? ((Double(glarePixels) / total) > 0.05) : false

    var laplacianSum: Double = 0
    var laplacianSqSum: Double = 0
    var count: Double = 0

    let stride = max(1, width / 180)
    for y in stride..<(height - stride) {
      for x in stride..<(width - stride) {
        let idx = y * width + x
        let c = Double(pixels[idx])
        let l = Double(pixels[idx - stride])
        let r = Double(pixels[idx + stride])
        let u = Double(pixels[idx - stride * width])
        let d = Double(pixels[idx + stride * width])
        let lap = (4 * c) - l - r - u - d

        laplacianSum += lap
        laplacianSqSum += (lap * lap)
        count += 1
      }
    }

    let mean = count > 0 ? (laplacianSum / count) : 0
    let variance = count > 0 ? max(0, (laplacianSqSum / count) - (mean * mean)) : 0.0
    let blurScore = min(100.0, max(0.0, sqrt(variance) * 2.5))

    let guidance: String
    if hasGlare {
      guidance = "Glare detected - tilt phone away from overhead light"
    } else if blurScore < 40 {
      guidance = "Image blurry - hold camera steady"
    } else {
      guidance = "Quality Passed - Good capture"
    }

    return QualityResult(
      blurScore: (blurScore * 10).rounded() / 10,
      brightness: (brightnessMean * 10).rounded() / 10,
      glareDetected: hasGlare,
      guidance: guidance
    )
  }

  private func assessLiveness(image: UIImage) -> (isLive: Bool, score: Double) {
    guard let raw = extractRawPixels(image: image) else { return (false, 0.0) }
    let width = raw.width
    let height = raw.height
    let pixels = raw.bytes

    var sum: Double = 0
    var sqSum: Double = 0
    var count: Double = 0
    let stride = max(1, width / 180)

    for y in stride..<(height - stride) {
      for x in stride..<(width - stride) {
        let p = Double(pixels[y * width + x])
        sum += p
        sqSum += (p * p)
        count += 1
      }
    }

    if count == 0 { return (false, 0.0) }
    let mean = sum / count
    let variance = max(0, (sqSum / count) - (mean * mean))

    let normScore = (variance / 900.0)
    let score = min(0.98, max(0.0, normScore))
    let finalScore = (score * 100.0).rounded() / 100.0
    let isLive = finalScore >= 0.40

    return (isLive: isLive, score: finalScore)
  }

  private func extractMinutiae(image: UIImage) -> [MinutiaPoint] {
    guard let raw = extractRawPixels(image: image) else { return [] }
    let width = raw.width
    let height = raw.height
    let pixels = raw.bytes

    var sum: Double = 0
    for p in pixels { sum += Double(p) }
    let meanBright = pixels.count > 0 ? (sum / Double(pixels.count)) : 128.0
    let darkThreshold = UInt8(clamping: Int(meanBright * 0.95))

    var points: [MinutiaPoint] = []
    let step = max(6, min(width, height) / 30)

    for y in stride(from: step * 2, to: height - step * 2, by: step) {
      for x in stride(from: step * 2, to: width - step * 2, by: step) {
        let idx = y * width + x
        let p = pixels[idx]
        let left = pixels[idx - 2]
        let right = pixels[idx + 2]
        let top = pixels[idx - 2 * width]
        let bot = pixels[idx + 2 * width]

        let diff = abs(Int(left) - Int(right)) + abs(Int(top) - Int(bot))
        if diff > 20 && p <= darkThreshold {
          let angle = atan2(Double(bot) - Double(top), Double(right) - Double(left))
          let type = (points.count % 2 == 0) ? "ENDING" : "BIFURCATION"
          points.append(MinutiaPoint(x: x, y: y, direction: angle, type: type))
          if points.count >= 50 { break }
        }
      }
      if points.count >= 50 { break }
    }

    return points
  }

  private func generateIsoTemplate(minutiae: [MinutiaPoint], width: Int, height: Int) -> String {
    var data = Data()
    // Magic 4 bytes 'F', 'M', 'R', '\0'
    data.append(contentsOf: [0x46, 0x4D, 0x52, 0x00])
    // Version '2', '0'
    data.append(contentsOf: [0x32, 0x30])
    // Length (4 bytes)
    var length = UInt32(28 + minutiae.count * 6).bigEndian
    data.append(Data(bytes: &length, count: 4))
    // Equipment ID (2 bytes)
    var equip: UInt16 = 0
    data.append(Data(bytes: &equip, count: 2))
    // Size X, Y (2 bytes each)
    var w = UInt16(width > 0 ? width : 320).bigEndian
    var h = UInt16(height > 0 ? height : 320).bigEndian
    data.append(Data(bytes: &w, count: 2))
    data.append(Data(bytes: &h, count: 2))
    // X, Y Resolution (2 bytes each) 500 DPI = 197 ppcm
    var res: UInt16 = UInt16(197).bigEndian
    data.append(Data(bytes: &res, count: 2))
    data.append(Data(bytes: &res, count: 2))
    // Views (1 byte), Reserved (1 byte), Impression (1 byte), Quality (1 byte)
    data.append(contentsOf: [1, 0, 0, 100])
    // Minutiae count (1 byte)
    data.append(UInt8(min(minutiae.count, 255)))

    for m in minutiae {
      var mx = UInt16(m.x).bigEndian
      var my = UInt16(m.y).bigEndian
      var angle = UInt8(((m.direction + Double.pi) / (2.0 * Double.pi)) * 255.0)
      var mtype: UInt8 = (m.type == "ENDING") ? 1 : 2
      data.append(Data(bytes: &mx, count: 2))
      data.append(Data(bytes: &my, count: 2))
      data.append(angle)
      data.append(mtype)
    }
    return data.base64EncodedString()
  }

  private struct MatchDetails {
    let matched: Bool
    let confidence: Double
    let matchCount: Int
    let execTimeMs: Int
  }

  private func compareMinutiae(m1: [[String: Any]], m2: [[String: Any]]) -> MatchDetails {
    let startTime = CFAbsoluteTimeGetCurrent()
    if m1.isEmpty || m2.isEmpty {
      return MatchDetails(matched: false, confidence: 0.0, matchCount: 0, execTimeMs: 0)
    }

    var pts1: [(x: Double, y: Double, dir: Double, type: String)] = []
    for p in m1 {
      let x = (p["x"] as? NSNumber)?.doubleValue ?? Double((p["x"] as? Int) ?? 0)
      let y = (p["y"] as? NSNumber)?.doubleValue ?? Double((p["y"] as? Int) ?? 0)
      let dir = (p["direction"] as? NSNumber)?.doubleValue ?? 0.0
      let type = (p["type"] as? String) ?? ""
      pts1.append((x: x, y: y, dir: dir, type: type))
    }

    var pts2: [(x: Double, y: Double, dir: Double, type: String)] = []
    for p in m2 {
      let x = (p["x"] as? NSNumber)?.doubleValue ?? Double((p["x"] as? Int) ?? 0)
      let y = (p["y"] as? NSNumber)?.doubleValue ?? Double((p["y"] as? Int) ?? 0)
      let dir = (p["direction"] as? NSNumber)?.doubleValue ?? 0.0
      let type = (p["type"] as? String) ?? ""
      pts2.append((x: x, y: y, dir: dir, type: type))
    }

    let minCount = min(pts1.count, pts2.count)
    let maxCount = max(pts1.count, pts2.count)
    if maxCount == 0 || (Double(minCount) / Double(maxCount)) < 0.25 {
      let execTime = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
      return MatchDetails(matched: false, confidence: 0.0, matchCount: 0, execTimeMs: execTime)
    }

    let meanX1 = pts1.map { $0.x }.reduce(0, +) / Double(pts1.count)
    let meanY1 = pts1.map { $0.y }.reduce(0, +) / Double(pts1.count)
    let norm1 = pts1.map { (x: $0.x - meanX1, y: $0.y - meanY1, dir: $0.dir, type: $0.type) }

    let meanX2 = pts2.map { $0.x }.reduce(0, +) / Double(pts2.count)
    let meanY2 = pts2.map { $0.y }.reduce(0, +) / Double(pts2.count)
    let norm2 = pts2.map { (x: $0.x - meanX2, y: $0.y - meanY2, dir: $0.dir, type: $0.type) }

    var matches = 0
    var used2 = Set<Int>()
    for p1 in norm1 {
      var bestIdx = -1
      var minDist = 40.0
      for (j, p2) in norm2.enumerated() {
        if used2.contains(j) { continue }
        let dist = sqrt((p1.x - p2.x) * (p1.x - p2.x) + (p1.y - p2.y) * (p1.y - p2.y))
        let dirDiff = abs(p1.dir - p2.dir)
        if dist < minDist && (p1.type.isEmpty || p2.type.isEmpty || p1.type == p2.type) && dirDiff < 1.0 {
          minDist = dist
          bestIdx = j
        }
      }
      if bestIdx >= 0 {
        used2.insert(bestIdx)
        matches += 1
      }
    }

    let totalPts = Double(pts1.count + pts2.count)
    let rawScore = totalPts > 0 ? (2.0 * Double(matches) / totalPts) : 0.0
    let confidence = (rawScore * 100.0).rounded() / 100.0
    let isMatched = confidence >= 0.25 && matches >= 3
    let execTime = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))

    return MatchDetails(matched: isMatched, confidence: min(1.0, confidence), matchCount: matches, execTimeMs: execTime)
  }
}
