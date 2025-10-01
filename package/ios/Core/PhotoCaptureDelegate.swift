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
        cause: error as NSError)
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

    print("🔍 Face cropping check:")
    print("  - hasDepthData: \(hasDepthData)")
    print("  - hasImageData: \(hasImageData)")
    print("  - enableDepthData: \(enableDepthData)")

    return hasDepthData && hasImageData
  }

  private func processPhoto(photo: AVCapturePhoto) throws {
    // Write original photo to file
    try FileUtils.writePhotoToFile(
      photo: photo,
      metadataProvider: metadataProvider,
      file: path)

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

    // Try face cropping if depth data is available
    var croppedImageBase64: String?
    var finalWidth: Any = exif?["PixelXDimension"] as Any
    var finalHeight: Any = exif?["PixelYDimension"] as Any

    if shouldProcessFaceCropping(photo: photo) {
      do {
        let result = try processFaceCropping(photo: photo, exifOrientation: cgOrientation)
        croppedImageBase64 = result.croppedImageBase64
        finalWidth = result.croppedWidth
        finalHeight = result.croppedHeight
      } catch {
        // Face cropping failed, continue with regular processing
        // The error will be logged but won't fail the entire photo capture
        print("Face cropping failed: \(error.localizedDescription)")
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

  private struct FaceCroppingResult {
    let croppedImageBase64: String
    let croppedWidth: Int
    let croppedHeight: Int
  }

  private func processFaceCropping(
    photo: AVCapturePhoto,
    exifOrientation: CGImagePropertyOrientation
  ) throws -> FaceCroppingResult {
    // Extract image and metadata
    guard let imageData = photo.fileDataRepresentation(),
      let image = UIImage(data: imageData)
    else {
      throw CameraError.capture(.unknown(message: "Failed to create image from photo data"))
    }

    // Store for depth data processing later
    self.lastProcessedImageSize = image.size

    // Detect single face
    let faceObservation = try detectSingleFace(in: image)

    // Convert face coordinates to image pixels
    let imageSize = image.size
    let faceRect = VNImageRectForNormalizedRect(
      faceObservation.boundingBox,
      Int(imageSize.width),
      Int(imageSize.height)
    )

    // Store face rect for depth data processing later
    self.lastProcessedFaceRect = faceRect

    // Crop image
    let croppedImage = try cropImage(image, to: faceRect)

    // Convert cropped image to base64
    guard let croppedImageData = croppedImage.jpegData(compressionQuality: 1.0) else {
      throw CameraError.capture(.unknown(message: "Failed to convert cropped image to JPEG"))
    }

    return FaceCroppingResult(
      croppedImageBase64: croppedImageData.base64EncodedString(),
      croppedWidth: Int(croppedImage.size.width),
      croppedHeight: Int(croppedImage.size.height)
    )
  }

  private func detectSingleFace(in image: UIImage) throws -> VNFaceObservation {
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

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])
    semaphore.wait()

    if let error = detectionError {
      throw error
    }

    guard let face = detectedFace else {
      throw CameraError.capture(.unknown(message: "Face detection failed"))
    }

    return face
  }

  private func cropImage(_ image: UIImage, to rect: CGRect) throws -> UIImage {
    guard let cgImage = image.cgImage else {
      throw CameraError.capture(.unknown(message: "Failed to get CGImage"))
    }

    // Ensure crop rect is within image bounds
    let imageRect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
    let clampedRect = rect.intersection(imageRect)

    guard !clampedRect.isEmpty else {
      throw CameraError.capture(.unknown(message: "Face region is outside image bounds"))
    }

    guard let croppedCGImage = cgImage.cropping(to: clampedRect) else {
      throw CameraError.capture(.unknown(message: "Failed to crop image"))
    }

    return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
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
