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

      // Create debug heatmap
      lastDepthHeatmap = createDepthHeatmap(
        depthData: orientedDepthData,
        faceRect: face.boundingBox,
        imageSize: CGSize(width: cgImage.width, height: cgImage.height)
      )
    } else {
      print("One and unique face recognized - Standard detection (no depth data)")
    }

    return face
  }

  private func analyzeDepthAtFaceLocation(
    depthData: AVDepthData,
    faceRect: CGRect,
    imageSize: CGSize
  ) -> Bool {
    print("Analyzing depth data at face location for anti-spoofing")

    // Get oriented depth map
    let depthMap = depthData.depthDataMap
    let depthWidth = CVPixelBufferGetWidth(depthMap)
    let depthHeight = CVPixelBufferGetHeight(depthMap)

    print("Depth map size: \(depthWidth)x\(depthHeight)")
    print("Image size: \(imageSize.width)x\(imageSize.height)")
    print("Face rect (normalized): \(faceRect)")

    // Convert normalized face rect to pixel coordinates in the IMAGE space
    // Vision framework uses bottom-left origin, UIImage uses top-left origin
    // Formula: newY = (1 - oldY - height) converts from bottom-left to top-left
    let faceRectInImagePixels = CGRect(
      x: faceRect.origin.x * imageSize.width,
      y: (1.0 - faceRect.origin.y - faceRect.height) * imageSize.height,  // Flip Y-axis
      width: faceRect.width * imageSize.width,
      height: faceRect.height * imageSize.height
    )
    print("Face rect in image pixels (Y-flipped): \(faceRectInImagePixels)")

    // Now scale from image pixel coordinates to depth map pixel coordinates
    let depthFaceRect = convertToDepthCoordinates(
      faceRectInImagePixels,
      from: imageSize,
      to: CGSize(width: depthWidth, height: depthHeight)
    )

    print("Face rect in depth map pixels: \(depthFaceRect)")

    // Lock depth buffer for reading
    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
      print("Failed to get depth map base address")
      return false
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
    let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)

    // Analyze depth values in face region
    let faceX = Int(depthFaceRect.origin.x)
    let faceY = Int(depthFaceRect.origin.y)
    let faceWidth = Int(depthFaceRect.width)
    let faceHeight = Int(depthFaceRect.height)

    var depthValues: [Float] = []

    // Sample depth values in face region based on actual pixel format
    let bytesPerPixel = getBytesPerPixel(for: pixelFormat)
    print("Depth format: \(pixelFormat), bytes per pixel: \(bytesPerPixel)")

    // Determine if we're working with disparity or depth data
    let isDisparityData =
      pixelFormat == kCVPixelFormatType_DisparityFloat16
      || pixelFormat == kCVPixelFormatType_DisparityFloat32
    print("Data type: \(isDisparityData ? "Disparity" : "Depth")")

    // Bounds check for face region
    let safeStartX = max(0, faceX)
    let safeStartY = max(0, faceY)
    let safeEndX = min(faceX + faceWidth, depthWidth)
    let safeEndY = min(faceY + faceHeight, depthHeight)

    print("Sampling region: x=\(safeStartX)..\(safeEndX), y=\(safeStartY)..\(safeEndY)")

    for y in safeStartY..<safeEndY {
      for x in safeStartX..<safeEndX {
        let pixelOffset = y * bytesPerRow + x * bytesPerPixel

        let depthValue: Float
        switch pixelFormat {
        case kCVPixelFormatType_DepthFloat16:
          let float16Value = baseAddress.load(fromByteOffset: pixelOffset, as: Float16.self)
          depthValue = Float(float16Value)
        case kCVPixelFormatType_DepthFloat32:
          depthValue = baseAddress.load(fromByteOffset: pixelOffset, as: Float.self)
        case kCVPixelFormatType_DisparityFloat16:
          let float16Value = baseAddress.load(fromByteOffset: pixelOffset, as: Float16.self)
          depthValue = Float(float16Value)
        case kCVPixelFormatType_DisparityFloat32:
          depthValue = baseAddress.load(fromByteOffset: pixelOffset, as: Float.self)
        default:
          print("Unsupported depth format: \(pixelFormat)")
          continue
        }

        // Filter valid depth/disparity values
        // Disparity: typically 0-2 (higher = closer)
        // Depth: typically 0-10 meters (higher = farther)
        let isValidValue: Bool
        if isDisparityData {
          // For disparity, valid values are typically 0.0 to 2.0
          isValidValue = depthValue > 0 && depthValue < 5.0
        } else {
          // For depth, valid values are typically 0.0 to 10.0 meters
          isValidValue = depthValue > 0 && depthValue < 10.0
        }

        if isValidValue {
          depthValues.append(depthValue)
        }
      }
    }

    print("Collected \(depthValues.count) valid depth values")

    // Analyze depth variation
    guard !depthValues.isEmpty else {
      print("No depth values found in face region")
      return false
    }

    let minDepth = depthValues.min() ?? 0
    let maxDepth = depthValues.max() ?? 0
    let depthRange = maxDepth - minDepth
    let avgDepth = depthValues.reduce(0, +) / Float(depthValues.count)

    print(
      "Depth analysis - Min: \(minDepth), Max: \(maxDepth), Range: \(depthRange), Avg: \(avgDepth), Count: \(depthValues.count)"
    )

    // Anti-spoofing logic: Real faces should have significant depth variation
    // 2D screens/photos will have minimal depth variation
    // For disparity data, variation is typically smaller than depth data
    let minDepthVariation: Float = isDisparityData ? 0.05 : 0.1
    let isRealFace = depthRange > minDepthVariation

    print(
      "Anti-spoofing result: \(isRealFace ? "Real face" : "Possible spoofing") - Depth range: \(depthRange) (threshold: \(minDepthVariation))"
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
