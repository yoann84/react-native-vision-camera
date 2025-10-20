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

  // Face processing results
  private var lastProcessedFaceRect: CGRect?
  private var lastProcessedImageSize: CGSize?

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

    // Process depth data only if face cropping succeeded
    var depthDataResult: [String: Any]?
    if let depthData = photo.depthData,
      let faceRect = lastProcessedFaceRect,
      let imageSize = lastProcessedImageSize,
      enableDepthData
    {
      // Face cropping succeeded, process cropped depth data
      depthDataResult = try processCroppedDepthData(
        depthData: depthData,
        faceRect: faceRect,
        imageSize: imageSize,
        exifOrientation: cgOrientation
      )
    }
    // If face cropping failed, both croppedImage and depthData will be nil

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
      "depthData": depthDataResult as Any,
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

    // Store for depth data processing later
    lastProcessedImageSize = image.size
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
    let faceRectInImagePixels = CGRect(
      x: faceRect.origin.x * imageSize.width,
      y: faceRect.origin.y * imageSize.height,
      width: faceRect.width * imageSize.width,
      height: faceRect.height * imageSize.height
    )
    print("Face rect in image pixels: \(faceRectInImagePixels)")

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

  private func createPixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
    let width = cgImage.width
    let height = cgImage.height

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )

    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
      return nil
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let pixelData = CVPixelBufferGetBaseAddress(buffer)
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: pixelData,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: rgbColorSpace,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )

    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    return buffer
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

  private func cropPixelBuffer(_ sourceBuffer: CVPixelBuffer, to cropRect: CGRect) throws
    -> CVPixelBuffer
  {
    let cropX = Int(cropRect.origin.x)
    let cropY = Int(cropRect.origin.y)
    let cropWidth = Int(cropRect.width)
    let cropHeight = Int(cropRect.height)

    // Lock source buffer
    CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly) }

    // Get source buffer properties
    let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
    let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)
    let pixelFormat = CVPixelBufferGetPixelFormatType(sourceBuffer)
    let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(sourceBuffer)

    // Validate crop bounds
    guard cropX >= 0, cropY >= 0,
      cropX + cropWidth <= sourceWidth,
      cropY + cropHeight <= sourceHeight
    else {
      throw CameraError.capture(.unknown(message: "Crop region exceeds depth buffer bounds"))
    }

    // Create new pixel buffer
    var croppedBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      cropWidth,
      cropHeight,
      pixelFormat,
      nil,
      &croppedBuffer
    )

    guard status == kCVReturnSuccess, let croppedBuffer = croppedBuffer else {
      throw CameraError.capture(.unknown(message: "Failed to create cropped pixel buffer"))
    }

    // Lock destination buffer
    CVPixelBufferLockBaseAddress(croppedBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(croppedBuffer, []) }

    // Get buffer addresses
    guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(sourceBuffer),
      let destBaseAddress = CVPixelBufferGetBaseAddress(croppedBuffer)
    else {
      throw CameraError.capture(.unknown(message: "Failed to get pixel buffer addresses"))
    }

    // Calculate bytes per pixel based on actual pixel format
    let bytesPerPixel = getBytesPerPixel(for: pixelFormat)
    let destBytesPerRow = CVPixelBufferGetBytesPerRow(croppedBuffer)

    // Copy pixel data row by row
    for row in 0..<cropHeight {
      let sourceRowOffset = (cropY + row) * sourceBytesPerRow + cropX * bytesPerPixel
      let destRowOffset = row * destBytesPerRow

      let sourceRowPtr = sourceBaseAddress.advanced(by: sourceRowOffset)
      let destRowPtr = destBaseAddress.advanced(by: destRowOffset)

      memcpy(destRowPtr, sourceRowPtr, cropWidth * bytesPerPixel)
    }

    return croppedBuffer
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
      // Fallback: calculate from bytes per row
      // This should work for most cases even if format is unknown
      return 4  // Default to 4 bytes, but this will be overridden by actual calculation
    }
  }

  private func processCroppedDepthData(
    depthData: AVDepthData,
    faceRect: CGRect,
    imageSize: CGSize,
    exifOrientation: CGImagePropertyOrientation
  ) throws -> [String: Any] {
    // Apply orientation to depth data
    let orientedDepthData = depthData.applyingExifOrientation(exifOrientation)

    // Get depth buffer dimensions
    let depthMap = orientedDepthData.depthDataMap
    let depthWidth = CVPixelBufferGetWidth(depthMap)
    let depthHeight = CVPixelBufferGetHeight(depthMap)
    let depthSize = CGSize(width: depthWidth, height: depthHeight)

    // Convert face coordinates to depth buffer coordinates
    let depthFaceRect = convertToDepthCoordinates(
      faceRect,
      from: imageSize,
      to: depthSize
    )

    // Crop depth data pixel buffer
    let croppedPixelBuffer = try cropPixelBuffer(depthMap, to: depthFaceRect)

    // Create new AVDepthData with cropped buffer
    let croppedDepthData = try orientedDepthData.replacingDepthDataMap(with: croppedPixelBuffer)

    // Convert to base64
    return processDepthData(croppedDepthData)
  }

  private func processDepthData(_ depthData: AVDepthData) -> [String: Any] {
    let depthDataMap = depthData.depthDataMap
    let depthDataType = depthData.depthDataType

    // Lock the pixel buffer for reading
    CVPixelBufferLockBaseAddress(depthDataMap, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(depthDataMap, .readOnly)
    }

    // Get pixel buffer properties
    let width = CVPixelBufferGetWidth(depthDataMap)
    let height = CVPixelBufferGetHeight(depthDataMap)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthDataMap)

    // Get base address of pixel data
    guard let baseAddress = CVPixelBufferGetBaseAddress(depthDataMap) else {
      return [:]
    }

    // Calculate total data size
    let dataSize = height * bytesPerRow
    let data = Data(bytes: baseAddress, count: dataSize)
    let base64String = data.base64EncodedString()

    return [
      "data": base64String,
      "format": depthDataType,
      "width": width,
      "height": height,
      "bytesPerRow": bytesPerRow,
    ]
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
