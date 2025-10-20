//
//  AntiSpoofingProcessor.swift
//  VisionCamera
//
//  Created for TrueDepth-based face anti-spoofing detection.
//

import AVFoundation
import Vision

/// Handles TrueDepth-based anti-spoofing detection using depth data analysis
class AntiSpoofingProcessor {
  private let enableDebug: Bool

  // Cached results for metrics and face count
  private var lastMetrics: [String: Any]?
  private var lastFaceCount: Int = 0
  private var lastDepthHeatmap: String?

  init(enableDebug: Bool) {
    self.enableDebug = enableDebug
  }

  // MARK: - Public API

  /// Builds the complete anti-spoofing result for a captured photo
  func buildAntiSpoofingResult(
    photo: AVCapturePhoto,
    exifOrientation: UInt32,
    enableDepthData: Bool
  ) -> [String: Any] {
    // Reset cached data
    lastMetrics = nil
    lastFaceCount = 0
    lastDepthHeatmap = nil

    // Check if anti-spoofing is enabled
    guard enableDepthData else {
      return createResult(
        isEnabled: false,
        hasTrueDepth: false,
        faceCount: 0,
        status: "disabled",
        message: "Anti-spoofing not enabled"
      )
    }

    // Check if device has TrueDepth capability
    guard hasDepthData(photo: photo) else {
      return createResult(
        isEnabled: true,
        hasTrueDepth: false,
        faceCount: 0,
        status: "no_depth_data",
        message: "Device does not support depth capture"
      )
    }

    // Attempt anti-spoofing detection
    do {
      return try performAntiSpoofing(photo: photo, exifOrientation: exifOrientation)
    } catch {
      // Handle detection failure
      let status = determineFailureStatus(faceCount: lastFaceCount)

      return createResult(
        isEnabled: true,
        hasTrueDepth: true,
        faceCount: lastFaceCount,
        status: status,
        message: error.localizedDescription
      )
    }
  }

  /// Returns the debug depth heatmap if available and debug mode is enabled
  func getDebugDepthHeatmap() -> String? {
    guard enableDebug else { return nil }
    return lastDepthHeatmap
  }

  // MARK: - Private Helpers

  private func hasDepthData(photo: AVCapturePhoto) -> Bool {
    return photo.depthData != nil && photo.fileDataRepresentation() != nil
  }

  private func performAntiSpoofing(
    photo: AVCapturePhoto,
    exifOrientation: UInt32
  ) throws -> [String: Any] {
    // Extract image and metadata
    guard let imageData = photo.fileDataRepresentation(),
      let image = UIImage(data: imageData)
    else {
      throw CameraError.capture(.unknown(message: "Failed to create image from photo data"))
    }

    let imageSize = image.size

    // Detect single face with proper orientation and depth data for anti-spoofing
    let faceObservation = try detectSingleFace(
      in: image,
      photo: photo,
      exifOrientation: exifOrientation
    )

    lastFaceCount = 1

    // Anti-spoofing passed - one unique face detected
    return createResult(
      isEnabled: true,
      hasTrueDepth: true,
      faceCount: 1,
      isRealFace: true,
      status: "success",
      message: "One and unique face recognized"
    )
  }

  private func detectSingleFace(
    in image: UIImage,
    photo: AVCapturePhoto,
    exifOrientation: UInt32
  ) throws -> VNFaceObservation {
    guard let cgImage = image.cgImage else {
      throw CameraError.capture(.unknown(message: "Failed to get CGImage from photo"))
    }

    var detectedFace: VNFaceObservation?
    var detectionError: Error?

    let semaphore = DispatchSemaphore(value: 0)

    // Use VNDetectFaceLandmarksRequest to get actual nose position
    let request = VNDetectFaceLandmarksRequest { request, error in
      if let error = error {
        detectionError = error
      } else if let results = request.results as? [VNFaceObservation] {
        self.lastFaceCount = results.count

        if results.count == 1 {
          detectedFace = results.first
        } else if results.isEmpty {
          detectionError = CameraError.capture(.unknown(message: "No face detected in image"))
        } else {
          detectionError = CameraError.capture(
            .unknown(message: "Multiple faces detected (\(results.count) faces found)"))
        }
      }
      semaphore.signal()
    }

    // Create handler with proper orientation
    let cgOrientation: CGImagePropertyOrientation
    if let orientation = CGImagePropertyOrientation(rawValue: exifOrientation) {
      cgOrientation = orientation
    } else {
      cgOrientation = .up
    }

    let handler = VNImageRequestHandler(
      cgImage: cgImage, orientation: cgOrientation, options: [:]
    )

    try handler.perform([request])
    semaphore.wait()

    if let error = detectionError {
      throw error
    }

    guard let face = detectedFace else {
      throw CameraError.capture(.unknown(message: "Face detection failed"))
    }

    // Custom anti-spoofing analysis using depth data
    if let depthData = photo.depthData {
      // Apply orientation to depth data to match image orientation
      let orientedDepthData = depthData.applyingExifOrientation(cgOrientation)

      // Create debug heatmap (only if debug enabled)
      if enableDebug {
        lastDepthHeatmap = createDepthHeatmap(
          depthData: orientedDepthData,
          faceObservation: face,
          imageSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
      }

      let isRealFace = analyzeDepthAtFaceLocation(
        depthData: orientedDepthData,
        faceObservation: face,
        imageSize: CGSize(width: cgImage.width, height: cgImage.height)
      )

      if !isRealFace {
        throw CameraError.capture(
          .unknown(message: "Anti-spoofing failed - possible 2D spoofing detected"))
      }
    }

    return face
  }

  private func determineFailureStatus(faceCount: Int) -> String {
    switch faceCount {
    case 0:
      return "no_face"
    case 1:
      return "spoofing_detected"
    default:
      return "multiple_faces"
    }
  }

  private func createResult(
    isEnabled: Bool,
    hasTrueDepth: Bool,
    faceCount: Int,
    isRealFace: Bool = false,
    status: String,
    message: String
  ) -> [String: Any] {
    var result: [String: Any] = [
      "isEnabled": isEnabled,
      "hasTrueDepth": hasTrueDepth,
      "faceDetected": faceCount == 1,
      "faceCount": faceCount,
      "isRealFace": isRealFace,
      "status": status,
      "message": message,
    ]

    // Add metrics only if debug mode is enabled and we have metrics
    if enableDebug, let metrics = lastMetrics {
      result["metrics"] = metrics
    }

    return result
  }

  // MARK: - Multi-Factor Anti-Spoofing Analysis

  private struct DepthMetrics {
    let minDepth: Float
    let maxDepth: Float
    let depthRange: Float
    let stdDeviation: Float
    let centerDepth: Float
    let edgeDepth: Float
    let depthGradient: Float
    let validPixelPercentage: Float
    let smoothness: Float
  }

  private func analyzeDepthAtFaceLocation(
    depthData: AVDepthData,
    faceObservation: VNFaceObservation,
    imageSize: CGSize
  ) -> Bool {

    // Get oriented depth map
    let depthMap = depthData.depthDataMap
    let depthWidth = CVPixelBufferGetWidth(depthMap)
    let depthHeight = CVPixelBufferGetHeight(depthMap)

    let faceRect = faceObservation.boundingBox

    // Convert normalized face rect to pixel coordinates
    let faceRectInImagePixels = CGRect(
      x: faceRect.origin.x * imageSize.width,
      y: (1.0 - faceRect.origin.y - faceRect.height) * imageSize.height,
      width: faceRect.width * imageSize.width,
      height: faceRect.height * imageSize.height
    )

    let depthFaceRect = convertToDepthCoordinates(
      faceRectInImagePixels,
      from: imageSize,
      to: CGSize(width: depthWidth, height: depthHeight)
    )

    // Lock depth buffer for reading
    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
      return false
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
    let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
    let bytesPerPixel = getBytesPerPixel(for: pixelFormat)

    // Determine if we're working with disparity or depth data
    let isDisparityData =
      pixelFormat == kCVPixelFormatType_DisparityFloat16
      || pixelFormat == kCVPixelFormatType_DisparityFloat32

    // Collect depth values from face region
    let faceX = Int(depthFaceRect.origin.x)
    let faceY = Int(depthFaceRect.origin.y)
    let faceWidth = Int(depthFaceRect.width)
    let faceHeight = Int(depthFaceRect.height)

    let safeStartX = max(0, faceX)
    let safeStartY = max(0, faceY)
    let safeEndX = min(faceX + faceWidth, depthWidth)
    let safeEndY = min(faceY + faceHeight, depthHeight)

    var allDepthValues: [Float] = []
    var centerDepthValues: [Float] = []
    var edgeDepthValues: [Float] = []

    // Try to get actual nose position from landmarks
    var noseCenter: CGPoint?
    if let noseCrest = faceObservation.landmarks?.noseCrest,
      let nosePoints = noseCrest.normalizedPoints as [CGPoint]?,
      !nosePoints.isEmpty
    {
      // Calculate center of nose crest points
      let sumX = nosePoints.reduce(0.0) { $0 + $1.x }
      let sumY = nosePoints.reduce(0.0) { $0 + $1.y }
      let avgX = sumX / CGFloat(nosePoints.count)
      let avgY = sumY / CGFloat(nosePoints.count)

      // Convert from landmark coordinates (relative to face bbox) to normalized image coordinates
      noseCenter = CGPoint(
        x: faceRect.origin.x + avgX * faceRect.width,
        y: faceRect.origin.y + avgY * faceRect.height
      )

    }

    // Define center region based on nose position or geometric center
    let centerStartX: Int
    let centerEndX: Int
    let centerStartY: Int
    let centerEndY: Int

    if let nose = noseCenter {
      // Use actual nose position: sample 20% radius around nose
      let noseInImagePixels = CGPoint(
        x: nose.x * imageSize.width,
        y: (1.0 - nose.y) * imageSize.height  // Flip Y-axis
      )
      let noseInDepth = CGPoint(
        x: noseInImagePixels.x * CGFloat(depthWidth) / imageSize.width,
        y: noseInImagePixels.y * CGFloat(depthHeight) / imageSize.height
      )

      let radiusX = Int(Float(faceWidth) * 0.2)
      let radiusY = Int(Float(faceHeight) * 0.2)

      centerStartX = max(safeStartX, Int(noseInDepth.x) - radiusX)
      centerEndX = min(safeEndX, Int(noseInDepth.x) + radiusX)
      centerStartY = max(safeStartY, Int(noseInDepth.y) - radiusY)
      centerEndY = min(safeEndY, Int(noseInDepth.y) + radiusY)
    } else {
      // Fallback to geometric center (60% center region for better coverage)
      let centerMargin = 0.2  // 60% center (was 40%)
      centerStartX = safeStartX + Int(Float(faceWidth) * Float(centerMargin))
      centerEndX = safeEndX - Int(Float(faceWidth) * Float(centerMargin))
      centerStartY = safeStartY + Int(Float(faceHeight) * Float(centerMargin))
      centerEndY = safeEndY - Int(Float(faceHeight) * Float(centerMargin))
    }

    let totalPixels = (safeEndX - safeStartX) * (safeEndY - safeStartY)
    var validPixelCount = 0

    for y in safeStartY..<safeEndY {
      for x in safeStartX..<safeEndX {
        let pixelOffset = y * bytesPerRow + x * bytesPerPixel

        let depthValue: Float
        switch pixelFormat {
        case kCVPixelFormatType_DepthFloat16:
          depthValue = Float(baseAddress.load(fromByteOffset: pixelOffset, as: Float16.self))
        case kCVPixelFormatType_DepthFloat32:
          depthValue = baseAddress.load(fromByteOffset: pixelOffset, as: Float.self)
        case kCVPixelFormatType_DisparityFloat16:
          depthValue = Float(baseAddress.load(fromByteOffset: pixelOffset, as: Float16.self))
        case kCVPixelFormatType_DisparityFloat32:
          depthValue = baseAddress.load(fromByteOffset: pixelOffset, as: Float.self)
        default:
          continue
        }

        // Filter valid depth/disparity values
        let isValidValue: Bool
        if isDisparityData {
          isValidValue = depthValue > 0 && depthValue < 5.0
        } else {
          isValidValue = depthValue > 0 && depthValue < 10.0
        }

        if isValidValue {
          validPixelCount += 1
          allDepthValues.append(depthValue)

          // Categorize as center or edge
          if x >= centerStartX && x < centerEndX && y >= centerStartY && y < centerEndY {
            centerDepthValues.append(depthValue)
          } else {
            edgeDepthValues.append(depthValue)
          }
        }
      }
    }

    guard !allDepthValues.isEmpty else {
      return false
    }

    // Calculate comprehensive metrics
    let metrics = calculateDepthMetrics(
      allValues: allDepthValues,
      centerValues: centerDepthValues,
      edgeValues: edgeDepthValues,
      validPixelCount: validPixelCount,
      totalPixelCount: totalPixels
    )

    // Multi-factor anti-spoofing checks
    let result = performMultiFactorAntiSpoofing(metrics: metrics, isDisparityData: isDisparityData)

    return result
  }

  private func calculateDepthMetrics(
    allValues: [Float],
    centerValues: [Float],
    edgeValues: [Float],
    validPixelCount: Int,
    totalPixelCount: Int
  ) -> DepthMetrics {
    let minDepth = allValues.min() ?? 0
    let maxDepth = allValues.max() ?? 0
    let depthRange = maxDepth - minDepth
    let avgDepth = allValues.reduce(0, +) / Float(allValues.count)

    // Calculate standard deviation
    let variance = allValues.map { pow($0 - avgDepth, 2) }.reduce(0, +) / Float(allValues.count)
    let stdDeviation = sqrt(variance)

    // Calculate center vs edge depth (for concentric pattern detection)
    let centerDepth =
      centerValues.isEmpty ? 0 : centerValues.reduce(0, +) / Float(centerValues.count)
    let edgeDepth = edgeValues.isEmpty ? 0 : edgeValues.reduce(0, +) / Float(edgeValues.count)
    let depthGradient = abs(centerDepth - edgeDepth)

    // Calculate valid pixel percentage
    let validPixelPercentage = Float(validPixelCount) / Float(totalPixelCount)

    // Calculate smoothness (average absolute difference between adjacent values)
    var gradients: [Float] = []
    for i in 1..<allValues.count {
      gradients.append(abs(allValues[i] - allValues[i - 1]))
    }
    let smoothness = gradients.isEmpty ? 0 : gradients.reduce(0, +) / Float(gradients.count)

    return DepthMetrics(
      minDepth: minDepth,
      maxDepth: maxDepth,
      depthRange: depthRange,
      stdDeviation: stdDeviation,
      centerDepth: centerDepth,
      edgeDepth: edgeDepth,
      depthGradient: depthGradient,
      validPixelPercentage: validPixelPercentage,
      smoothness: smoothness
    )
  }

  private func performMultiFactorAntiSpoofing(metrics: DepthMetrics, isDisparityData: Bool) -> Bool
  {

    // Define thresholds based on research and data type
    let thresholds:
      (
        range: Float, stdDev: Float, gradient: Float, minSmoothness: Float, maxSmoothness: Float,
        validPixels: Float
      )

    if isDisparityData {
      // Disparity thresholds (higher values = closer objects)
      thresholds = (
        range: 0.50,  // Real: 1.19-2.82, Fake: 0.12-0.39
        stdDev: 0.15,  // Real: 0.24-0.73, Fake: 0.022-0.10
        gradient: 0.10,  // Real: 0.13-0.54, Fake: 0.006-0.11
        minSmoothness: 0.005,
        maxSmoothness: 0.06,
        validPixels: 0.85
      )
    } else {
      // Depth thresholds (meters)
      thresholds = (
        range: 0.10,  // Minimum 100mm (10cm) depth variation
        stdDev: 0.03,  // Minimum 30mm standard deviation
        gradient: 0.05,  // Minimum 50mm center-to-edge difference
        minSmoothness: 0.005,
        maxSmoothness: 0.04,
        validPixels: 0.85
      )
    }

    // Perform individual checks
    let check1_range = metrics.depthRange > thresholds.range
    let check2_stdDev = metrics.stdDeviation > thresholds.stdDev
    let check3_gradient = metrics.depthGradient > thresholds.gradient
    let check4_smoothness =
      metrics.smoothness > thresholds.minSmoothness && metrics.smoothness < thresholds.maxSmoothness
    let check5_validPixels = metrics.validPixelPercentage > thresholds.validPixels

    // Count passed checks
    let checks = [
      check1_range, check2_stdDev, check3_gradient, check4_smoothness, check5_validPixels,
    ]
    let passedCount = checks.filter { $0 }.count

    // Require at least 4 out of 5 checks to pass for real face
    let isRealFace = passedCount >= 4

    if enableDebug {
      print(
        "\n🎯 RESULT: \(passedCount)/5 checks passed → \(isRealFace ? "✅ REAL FACE" : "❌ SPOOFING DETECTED")\n"
      )
    }

    // Store metrics for result (only in debug mode)
    if enableDebug {
      lastMetrics = [
        "range": metrics.depthRange,
        "stdDeviation": metrics.stdDeviation,
        "gradient": metrics.depthGradient,
        "smoothness": metrics.smoothness,
        "validPixelPercentage": metrics.validPixelPercentage,
        "checksPassed": passedCount,
        "totalChecks": checks.count,
      ]
    }

    return isRealFace
  }

  // MARK: - Debug Heatmap Generation

  private func createDepthHeatmap(
    depthData: AVDepthData,
    faceObservation: VNFaceObservation,
    imageSize: CGSize
  ) -> String? {
    let depthMap = depthData.depthDataMap
    let depthWidth = CVPixelBufferGetWidth(depthMap)
    let depthHeight = CVPixelBufferGetHeight(depthMap)

    let faceRect = faceObservation.boundingBox

    // Convert face rect to depth coordinates
    let faceRectInImagePixels = CGRect(
      x: faceRect.origin.x * imageSize.width,
      y: (1.0 - faceRect.origin.y - faceRect.height) * imageSize.height,
      width: faceRect.width * imageSize.width,
      height: faceRect.height * imageSize.height
    )

    let depthFaceRect = convertToDepthCoordinates(
      faceRectInImagePixels,
      from: imageSize,
      to: CGSize(width: depthWidth, height: depthHeight)
    )

    let startX = max(0, Int(depthFaceRect.origin.x))
    let startY = max(0, Int(depthFaceRect.origin.y))
    let endX = min(Int(depthFaceRect.origin.x + depthFaceRect.width), depthWidth)
    let endY = min(Int(depthFaceRect.origin.y + depthFaceRect.height), depthHeight)
    let width = endX - startX
    let height = endY - startY

    guard width > 0 && height > 0 else { return nil }

    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

    // Collect depth values and find min/max for normalization
    var depthValues: [Float] = []
    for y in startY..<endY {
      for x in startX..<endX {
        let offset = y * bytesPerRow + x * 2  // 2 bytes for Float16
        let depthValue = baseAddress.load(fromByteOffset: offset, as: Float16.self)
        if depthValue > 0 {
          depthValues.append(Float(depthValue))
        }
      }
    }

    guard !depthValues.isEmpty else { return nil }

    let minDepth = depthValues.min() ?? 0
    let maxDepth = depthValues.max() ?? 1
    let range = maxDepth - minDepth

    // Create RGB image
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    for y in startY..<endY {
      for x in startX..<endX {
        let offset = y * bytesPerRow + x * 2
        let depthValue = Float(baseAddress.load(fromByteOffset: offset, as: Float16.self))

        let normalized = range > 0 ? (depthValue - minDepth) / range : 0
        let pixelIndex = ((y - startY) * width + (x - startX)) * 4

        // Color mapping: blue (far) → green → yellow → red (close)
        if normalized < 0.33 {
          let t = normalized / 0.33
          pixels[pixelIndex] = UInt8(255 * (1 - t))  // R
          pixels[pixelIndex + 1] = 0  // G
          pixels[pixelIndex + 2] = 255  // B
        } else if normalized < 0.66 {
          let t = (normalized - 0.33) / 0.33
          pixels[pixelIndex] = UInt8(255 * t)  // R
          pixels[pixelIndex + 1] = UInt8(255 * t)  // G
          pixels[pixelIndex + 2] = UInt8(255 * (1 - t))  // B
        } else {
          let t = (normalized - 0.66) / 0.34
          pixels[pixelIndex] = 255  // R
          pixels[pixelIndex + 1] = UInt8(255 * (1 - t))  // G
          pixels[pixelIndex + 2] = 0  // B
        }
      }
    }

    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      ),
      let cgImage = context.makeImage()
    else { return nil }

    let uiImage = UIImage(cgImage: cgImage)
    guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else { return nil }

    return jpegData.base64EncodedString()
  }

  // MARK: - Utility Functions

  private func convertToDepthCoordinates(
    _ faceRect: CGRect,
    from imageSize: CGSize,
    to depthSize: CGSize
  ) -> CGRect {
    let scaleX = depthSize.width / imageSize.width
    let scaleY = depthSize.height / imageSize.height

    return CGRect(
      x: faceRect.origin.x * scaleX,
      y: faceRect.origin.y * scaleY,
      width: faceRect.width * scaleX,
      height: faceRect.height * scaleY
    )
  }

  private func getBytesPerPixel(for pixelFormat: OSType) -> Int {
    switch pixelFormat {
    case kCVPixelFormatType_DepthFloat16:
      return 2  // 16-bit float
    case kCVPixelFormatType_DepthFloat32:
      return 4  // 32-bit float
    case kCVPixelFormatType_DisparityFloat16:
      return 2  // 16-bit float disparity
    case kCVPixelFormatType_DisparityFloat32:
      return 4  // 32-bit float disparity
    default:
      return 4  // Default fallback
    }
  }
}
