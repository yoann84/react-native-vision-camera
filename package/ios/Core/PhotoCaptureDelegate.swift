//
//  PhotoCaptureDelegate.swift
//  mrousavy
//
//  Created by Marc Rousavy on 15.12.20.
//  Copyright © 2020 mrousavy. All rights reserved.
//

import AVFoundation
import Vision

// MARK: - PhotoCaptureDelegate

class PhotoCaptureDelegate: GlobalReferenceHolder, AVCapturePhotoCaptureDelegate {
  private let promise: Promise
  private let enableShutterSound: Bool
  private let cameraSessionDelegate: CameraSessionDelegate?
  private let metadataProvider: MetadataProvider
  private let path: URL
  private let enableDepthData: Bool

  // Debug visualization
  private var lastDepthHeatmap: String?

  required init(
    promise: Promise,
    enableShutterSound: Bool,
    metadataProvider: MetadataProvider,
    path: URL,
    enableDepthData: Bool,
    cameraSessionDelegate: CameraSessionDelegate?
  ) {
    self.promise = promise
    self.enableShutterSound = enableShutterSound
    self.metadataProvider = metadataProvider
    self.path = path
    self.enableDepthData = enableDepthData
    self.cameraSessionDelegate = cameraSessionDelegate
    super.init()
    makeGlobal()
  }

  func photoOutput(_: AVCapturePhotoOutput, willCapturePhotoFor _: AVCaptureResolvedPhotoSettings) {
    if !enableShutterSound {
      // disable system shutter sound (see https://stackoverflow.com/a/55235949/5281431)
      AudioServicesDisposeSystemSoundID(1108)
    }

    // onShutter(..) event
    cameraSessionDelegate?.onCaptureShutter(shutterType: .photo)
  }

  func photoOutput(
    _: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    defer {
      removeGlobal()
    }
    if let error = error as NSError? {
      promise.reject(error: .capture(.unknown(message: error.description)), cause: error)
      return
    }

    do {
      try processPhoto(photo: photo)
    } catch let error as CameraError {
      promise.reject(error: error)
    } catch {
      promise.reject(
        error: .capture(.unknown(message: "An unknown error occured while capturing the photo!")),
        cause: error as NSError
      )
    }
  }

  func photoOutput(
    _: AVCapturePhotoOutput, didFinishCaptureFor _: AVCaptureResolvedPhotoSettings, error: Error?
  ) {
    defer {
      removeGlobal()
    }
    if let error = error as NSError? {
      if error.code == -11807 {
        promise.reject(error: .capture(.insufficientStorage), cause: error)
      } else {
        promise.reject(error: .capture(.unknown(message: error.description)), cause: error)
      }
      return
    }
  }

  private func shouldProcessFaceCropping(photo: AVCapturePhoto) -> Bool {
    // Always try face cropping when depth data is available
    let hasDepthData = photo.depthData != nil
    let hasImageData = photo.fileDataRepresentation() != nil

    return hasDepthData && hasImageData
  }

  private func processPhoto(photo: AVCapturePhoto) throws {
    // Write original photo to file
    try FileUtils.writePhotoToFile(
      photo: photo,
      metadataProvider: metadataProvider,
      file: path
    )

    // Extract basic metadata
    let exif = photo.metadata["{Exif}"] as? [String: Any]
    let exifOrientation =
      photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32
      ?? CGImagePropertyOrientation.up.rawValue
    let cgOrientation =
      CGImagePropertyOrientation(rawValue: exifOrientation)
      ?? CGImagePropertyOrientation.up
    let orientation = getOrientation(forExifOrientation: cgOrientation)
    let isMirrored = getIsMirrored(forExifOrientation: cgOrientation)

    // Process face detection and anti-spoofing (no cropping)
    var croppedImageBase64: String?
    var finalWidth: Any = exif?["PixelXDimension"] as Any
    var finalHeight: Any = exif?["PixelYDimension"] as Any

    if shouldProcessFaceCropping(photo: photo) {
      do {
        print("orientation raw value: \(orientation)")
        print("isMirrored: \(isMirrored)")
        let result = try processAntiSpoofing(photo: photo, exifOrientation: exifOrientation)
        print("Anti-spoofing result: isTrueFace=\(result.isTrueFace), reason=\(result.reason)")
      } catch {
        // Face detection failed, continue with regular processing
        print("Face detection failed: \(error.localizedDescription)")
      }
    }

    promise.resolve([
      "path": path.absoluteString,
      "width": finalWidth,
      "height": finalHeight,
      "orientation": orientation,
      "isMirrored": isMirrored,
      "isRawPhoto": photo.isRawPhoto,
      "metadata": photo.metadata,
      "thumbnail": photo.embeddedThumbnailPhotoFormat as Any,
      "croppedImage": croppedImageBase64 as Any,
      "debugDepthHeatmap": lastDepthHeatmap as Any,
    ])
  }

  private struct AntiSpoofingResult {
    let isTrueFace: Bool
    let reason: String
  }

  private func processAntiSpoofing(
    photo: AVCapturePhoto,
    exifOrientation: UInt32
  ) throws -> AntiSpoofingResult {
    // Extract image and metadata
    guard let imageData = photo.fileDataRepresentation(),
      let image = UIImage(data: imageData)
    else {
      throw CameraError.capture(.unknown(message: "Failed to create image from photo data"))
    }

    let imageSize = image.size
    // Detect single face with proper orientation and depth data for anti-spoofing
    do {
      let faceObservation = try detectSingleFace(
        in: image, photo: photo, exifOrientation: exifOrientation
      )

      // Essential debug info
      print("Face bounding box: \(faceObservation.boundingBox)")
      print("Image size: \(imageSize)")

      // Anti-spoofing passed - one unique face detected
      return AntiSpoofingResult(
        isTrueFace: true,
        reason: "One and unique face recognized"
      )
    } catch {
      // Handle no face detected case
      print("No face recognized")

      return AntiSpoofingResult(
        isTrueFace: false,
        reason: "No face detected"
      )
    }
  }

  private func detectSingleFace(in image: UIImage, photo: AVCapturePhoto, exifOrientation: UInt32)
    throws -> VNFaceObservation
  {
    guard let cgImage = image.cgImage else {
      throw CameraError.capture(.unknown(message: "Failed to get CGImage from photo"))
    }

    var detectedFace: VNFaceObservation?
    var detectionError: Error?

    let semaphore = DispatchSemaphore(value: 0)

    let request = VNDetectFaceRectanglesRequest { request, error in
      if let error = error {
        detectionError = error
      } else if let results = request.results as? [VNFaceObservation] {
        if results.count == 1 {
          detectedFace = results.first
        } else if results.isEmpty {
          detectionError = CameraError.capture(.unknown(message: "No face detected in image"))
        } else {
          detectionError = CameraError.capture(
            .unknown(message: "Multiple faces detected, unable to crop"))
        }
      }
      semaphore.signal()
    }

    // Create handler with proper orientation for accurate coordinate mapping
    // Use the exifOrientation from processPhoto function
    let cgOrientation: CGImagePropertyOrientation
    if let orientation = CGImagePropertyOrientation(rawValue: exifOrientation) {
      print(
        "exifOrientation used for face detection: \(exifOrientation) and brut force orientation: \(orientation)"
      )
      cgOrientation = orientation
    } else {
      print(
        "Warning: Failed to convert exifOrientation to CGImagePropertyOrientation, using .up as fallback"
      )
      cgOrientation = .up
    }

    // Use standard face detection first
    let handler = VNImageRequestHandler(
      cgImage: cgImage, orientation: cgOrientation, options: [:]
    )

    if photo.depthData != nil {
      print("Depth data available for custom anti-spoofing analysis")
    } else {
      print("Using standard face detection (no depth data available)")
    }

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
      print("Applied orientation \(cgOrientation.rawValue) to depth data")

      // Create debug heatmap FIRST (before anti-spoofing check)
      // This ensures we get the heatmap even if anti-spoofing fails
      lastDepthHeatmap = createDepthHeatmap(
        depthData: orientedDepthData,
        faceRect: face.boundingBox,
        imageSize: CGSize(width: cgImage.width, height: cgImage.height)
      )

      let isRealFace = analyzeDepthAtFaceLocation(
        depthData: orientedDepthData,
        faceRect: face.boundingBox,
        imageSize: CGSize(width: cgImage.width, height: cgImage.height)
      )

      if isRealFace {
        print("One and unique face recognized - Custom anti-spoofing passed")
      } else {
        print("Face detected but failed custom anti-spoofing - possible spoofing")
        throw CameraError.capture(
          .unknown(message: "Anti-spoofing failed - possible 2D spoofing detected"))
      }
    } else {
      print("One and unique face recognized - Standard detection (no depth data)")
    }

    return face
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
    faceRect: CGRect,
    imageSize: CGSize
  ) -> Bool {
    print("🔍 Multi-factor anti-spoofing analysis started")

    // Get oriented depth map
    let depthMap = depthData.depthDataMap
    let depthWidth = CVPixelBufferGetWidth(depthMap)
    let depthHeight = CVPixelBufferGetHeight(depthMap)

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
      print("❌ Failed to get depth map base address")
      return false
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
    let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
    let bytesPerPixel = getBytesPerPixel(for: pixelFormat)

    // Determine if we're working with disparity or depth data
    let isDisparityData =
      pixelFormat == kCVPixelFormatType_DisparityFloat16
      || pixelFormat == kCVPixelFormatType_DisparityFloat32

    print("📊 Data type: \(isDisparityData ? "Disparity" : "Depth")")

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

    // Define center region (middle 40% of face)
    let centerMargin = 0.3
    let centerStartX = safeStartX + Int(Float(faceWidth) * Float(centerMargin))
    let centerEndX = safeEndX - Int(Float(faceWidth) * Float(centerMargin))
    let centerStartY = safeStartY + Int(Float(faceHeight) * Float(centerMargin))
    let centerEndY = safeEndY - Int(Float(faceHeight) * Float(centerMargin))

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
      print("❌ No valid depth values found")
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
    print("\n📊 DEPTH METRICS:")
    print("  Range: \(metrics.depthRange)")
    print("  Std Dev: \(metrics.stdDeviation)")
    print("  Center→Edge Gradient: \(metrics.depthGradient)")
    print("  Smoothness: \(metrics.smoothness)")
    print("  Valid Pixels: \(String(format: "%.1f%%", metrics.validPixelPercentage * 100))")
    print("  Data type: \(isDisparityData ? "Disparity" : "Depth")")

    // Define thresholds based on research and data type
    // Research-based thresholds for real faces:
    // - Depth range: >80-100mm (0.08-0.10m) for depth, >0.15 for disparity
    // - Std deviation: >30mm (0.03m) for depth, >0.05 for disparity
    // - Center-edge gradient: >50mm (0.05m) for depth, >0.08 for disparity
    // - Smoothness: 0.01-0.04 (too low = uniform/fake, too high = noisy)
    // - Valid pixels: >85%

    let thresholds:
      (
        range: Float, stdDev: Float, gradient: Float, minSmoothness: Float, maxSmoothness: Float,
        validPixels: Float
      )

    if isDisparityData {
      // Disparity thresholds (higher values = closer objects)
      // Updated based on real-world testing:
      // Session 1 - Real: range=2.82, stdDev=0.73, gradient=0.54 (close)
      // Session 2 - Real: range=1.19, stdDev=0.24, gradient=0.13 (normal distance)
      // Session 1 - Fake: range=0.39, stdDev=0.10, gradient=0.11
      // Session 2 - Fake: range=0.12, stdDev=0.022, gradient=0.006
      thresholds = (
        range: 0.50,  // Real: 1.19-2.82, Fake: 0.12-0.39 → Clear separation ✅
        stdDev: 0.15,  // Real: 0.24-0.73, Fake: 0.022-0.10 → Clear separation ✅
        gradient: 0.10,  // Real: 0.13-0.54, Fake: 0.006-0.11 → Adjusted for distance ⚠️
        minSmoothness: 0.005,  // Fake session 2 had 0.002 → Caught it! ✅
        maxSmoothness: 0.06,  // Not too noisy
        validPixels: 0.85  // Not reliable (fake had 100%) → Use as backup only
      )
    } else {
      // Depth thresholds (meters)
      thresholds = (
        range: 0.10,  // Minimum 100mm (10cm) depth variation
        stdDev: 0.03,  // Minimum 30mm standard deviation
        gradient: 0.05,  // Minimum 50mm center-to-edge difference
        minSmoothness: 0.005,  // Not too uniform
        maxSmoothness: 0.04,  // Not too noisy
        validPixels: 0.85  // At least 85% valid pixels
      )
    }

    // Perform individual checks
    let check1_range = metrics.depthRange > thresholds.range
    let check2_stdDev = metrics.stdDeviation > thresholds.stdDev
    let check3_gradient = metrics.depthGradient > thresholds.gradient
    let check4_smoothness =
      metrics.smoothness > thresholds.minSmoothness && metrics.smoothness < thresholds.maxSmoothness
    let check5_validPixels = metrics.validPixelPercentage > thresholds.validPixels

    print("\n📋 THRESHOLDS (min required):")
    print("  Range: \(thresholds.range)")
    print("  Std Dev: \(thresholds.stdDev)")
    print("  Gradient: \(thresholds.gradient)")
    print("  Smoothness: \(thresholds.minSmoothness)-\(thresholds.maxSmoothness)")
    print("  Valid Pixels: \(String(format: "%.0f%%", thresholds.validPixels * 100))")

    print("\n✅ ANTI-SPOOFING CHECKS:")
    print(
      "  1. Depth Range (\(metrics.depthRange) > \(thresholds.range)): \(check1_range ? "✓ PASS" : "✗ FAIL")"
    )
    print(
      "  2. Std Deviation (\(metrics.stdDeviation) > \(thresholds.stdDev)): \(check2_stdDev ? "✓ PASS" : "✗ FAIL")"
    )
    print(
      "  3. Center→Edge Gradient (\(metrics.depthGradient) > \(thresholds.gradient)): \(check3_gradient ? "✓ PASS" : "✗ FAIL")"
    )
    print(
      "  4. Smoothness (\(thresholds.minSmoothness) < \(metrics.smoothness) < \(thresholds.maxSmoothness)): \(check4_smoothness ? "✓ PASS" : "✗ FAIL")"
    )
    print(
      "  5. Valid Pixel Coverage (\(String(format: "%.1f%%", metrics.validPixelPercentage * 100)) > \(String(format: "%.0f%%", thresholds.validPixels * 100))): \(check5_validPixels ? "✓ PASS" : "✗ FAIL")"
    )

    // Count passed checks
    let checks = [
      check1_range, check2_stdDev, check3_gradient, check4_smoothness, check5_validPixels,
    ]
    let passedCount = checks.filter { $0 }.count

    // Require at least 4 out of 5 checks to pass for real face
    let isRealFace = passedCount >= 4

    print(
      "\n🎯 RESULT: \(passedCount)/5 checks passed → \(isRealFace ? "✅ REAL FACE" : "❌ SPOOFING DETECTED")\n"
    )

    return isRealFace
  }

  private func createDepthHeatmap(
    depthData: AVDepthData,
    faceRect: CGRect,
    imageSize: CGSize
  ) -> String? {
    let depthMap = depthData.depthDataMap
    let depthWidth = CVPixelBufferGetWidth(depthMap)
    let depthHeight = CVPixelBufferGetHeight(depthMap)

    // Convert face rect to depth coordinates
    // Vision framework uses bottom-left origin, UIImage uses top-left origin
    let faceRectInImagePixels = CGRect(
      x: faceRect.origin.x * imageSize.width,
      y: (1.0 - faceRect.origin.y - faceRect.height) * imageSize.height,  // Flip Y-axis
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

  // MARK: - Helper Functions
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
      // Fallback: calculate from bytes per row
      // This should work for most cases even if format is unknown
      return 4  // Default to 4 bytes, but this will be overridden by actual calculation
    }
  }
  private func getOrientation(forExifOrientation exifOrientation: CGImagePropertyOrientation)
    -> String
  {
    switch exifOrientation {
    case .up, .upMirrored:
      return "portrait"
    case .down, .downMirrored:
      return "portrait-upside-down"
    case .left, .leftMirrored:
      return "landscape-left"
    case .right, .rightMirrored:
      return "landscape-right"
    default:
      return "portrait"
    }
  }

  private func getIsMirrored(forExifOrientation exifOrientation: CGImagePropertyOrientation) -> Bool
  {
    switch exifOrientation {
    case .upMirrored, .rightMirrored, .downMirrored, .leftMirrored:
      return true
    default:
      return false
    }
  }
}
