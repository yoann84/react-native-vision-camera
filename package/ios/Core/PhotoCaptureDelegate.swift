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
  private let enableDebug: Bool

  // Anti-spoofing processor
  private let antiSpoofingProcessor: AntiSpoofingProcessor

  required init(
    promise: Promise,
    enableShutterSound: Bool,
    metadataProvider: MetadataProvider,
    path: URL,
    enableDepthData: Bool,
    enableDebug: Bool,
    cameraSessionDelegate: CameraSessionDelegate?
  ) {
    self.promise = promise
    self.enableShutterSound = enableShutterSound
    self.metadataProvider = metadataProvider
    self.path = path
    self.enableDepthData = enableDepthData
    self.enableDebug = enableDebug
    self.cameraSessionDelegate = cameraSessionDelegate
    self.antiSpoofingProcessor = AntiSpoofingProcessor(enableDebug: enableDebug)
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

    // Process face detection and anti-spoofing
    let finalWidth: Any = exif?["PixelXDimension"] as Any
    let finalHeight: Any = exif?["PixelYDimension"] as Any

    // Build anti-spoofing result using processor
    let antiSpoofing = antiSpoofingProcessor.buildAntiSpoofingResult(
      photo: photo,
      exifOrientation: exifOrientation,
      enableDepthData: enableDepthData
    )

    // Build final result dictionary
    var result: [String: Any] = [
      "path": path.absoluteString,
      "width": finalWidth,
      "height": finalHeight,
      "orientation": orientation,
      "isMirrored": isMirrored,
      "isRawPhoto": photo.isRawPhoto,
      "metadata": photo.metadata,
      "thumbnail": photo.embeddedThumbnailPhotoFormat as Any,
      "antiSpoofing": antiSpoofing,
    ]

    // Add debug heatmap only if debug mode is enabled
    if let heatmap = antiSpoofingProcessor.getDebugDepthHeatmap() {
      result["debugDepthHeatmap"] = heatmap
    }

    promise.resolve(result)
  }

  // MARK: - Helper Functions

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
