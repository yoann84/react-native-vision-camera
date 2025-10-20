### TrueDepth anti-spoofing performance improvements (iOS)

This document lists concrete improvements to reduce latency and allocations in the anti‑spoofing pipeline while preserving behavior.

## Goals

- Minimize CPU work per capture.
- Avoid unnecessary memory allocations and I/O.
- Keep results stable across iOS versions.

## Bottlenecks

- JPEG/HEIC encode/decode via `AVCapturePhoto.fileDataRepresentation()` and `UIImage(data:)`.
- Blocking constructs (semaphores) around synchronous Vision calls.
- Multi-pass metrics with large temporary arrays.
- Debug heatmap always building large buffers when enabled.
- Depth delivery enabled globally when not needed.
- Incidental logging and small allocations inside inner loops.

## Recommended changes

### 1) Use CVPixelBuffer for Vision input

- Why: Avoids encode/decode path; zero-copy from camera pipeline.

```swift
let cgOrientation = CGImagePropertyOrientation(rawValue: exifOrientation) ?? .up
if let buffer = photo.pixelBuffer ?? photo.previewPixelBuffer {
  let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: cgOrientation, options: [:])
  let request = VNDetectFaceLandmarksRequest()
  try handler.perform([request])
  guard let results = request.results as? [VNFaceObservation] else { /* handle */ }
  // use results
} else if let data = photo.fileDataRepresentation(),
          let cgImage = UIImage(data: data)?.cgImage {
  // Fallback path (rare)
  let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation, options: [:])
  try handler.perform([request])
}
```

- Also update depth capability check:

```swift
func hasDepthData(photo: AVCapturePhoto) -> Bool {
  photo.depthData != nil
}
```

### 2) Remove semaphore; use synchronous Vision

- Why: `perform(_:)` is synchronous; a semaphore around it adds overhead and risk.

```swift
let request = VNDetectFaceLandmarksRequest()
try handler.perform([request])
guard let faces = request.results as? [VNFaceObservation] else { /* handle */ }
```

### 3) Stream depth metrics in one pass

- Why: Avoid `allValues`/`centerValues`/`edgeValues` arrays and separate “gradients” pass.

```swift
var count = 0, validCount = 0
var mean: Float = 0, m2: Float = 0
var centerMean: Float = 0, centerCount = 0
var edgeMean: Float = 0, edgeCount = 0
var lastValue: Float? = nil, gradSum: Float = 0

@inline(__always)
func update(_ x: Float, center: Bool) {
  count += 1
  let delta = x - mean
  mean += delta / Float(count)
  m2 += delta * (x - mean)
  if let prev = lastValue { gradSum += abs(x - prev) }
  lastValue = x
  if center {
    centerCount += 1
    centerMean += (x - centerMean) / Float(centerCount)
  } else {
    edgeCount += 1
    edgeMean += (x - edgeMean) / Float(edgeCount)
  }
}

// inside pixel loop: update(value, center: isCenter)
let variance = m2 / Float(max(count, 1))
let stdDev = sqrt(variance)
let depthGradient = abs(centerMean - edgeMean)
let smoothness = gradSum / Float(max(count - 1, 1))
let validPixelPercentage = Float(validCount) / Float(max(totalPixels, 1))
```

- Precompute `centerStartX/Y`, `centerEndX/Y` once; use integer bounds.

### 4) Precompute depth value reader and constants

- Why: Avoid per-pixel switch and divisions.

```swift
let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
let bytesPerPixel = (pixelFormat == kCVPixelFormatType_DepthFloat16 ||
                    pixelFormat == kCVPixelFormatType_DisparityFloat16) ? 2 : 4
let isDisparity = (pixelFormat == kCVPixelFormatType_DisparityFloat16 ||
                   pixelFormat == kCVPixelFormatType_DisparityFloat32)

let readValue: (UnsafeRawPointer, Int) -> Float = {
  switch pixelFormat {
  case kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
    return { base, offset in Float(base.load(fromByteOffset: offset, as: Float16.self)) }
  default:
    return { base, offset in base.load(fromByteOffset: offset, as: Float.self) }
  }
}()
```

### 5) Enable depth delivery only when needed

- Why: Reduces overhead on devices and captures that don’t need depth.

```swift
if photoOutput.isDepthDataDeliverySupported {
  photoOutput.isDepthDataDeliveryEnabled = needsDepth // toggle by feature flag/prop
}
// And per-capture: photoSettings.isDepthDataDeliveryEnabled = needsDepth
```

### 6) Gate heavy debug paths

- Why: Heatmap builds large RGBA buffers and JPEG‑encodes.

```swift
guard enableDebug else { return nil } // no heatmap
// optionally reuse a pixel buffer if same dimensions across captures in a session
```

### 7) Background work, UI responsiveness

- Why: Vision + depth iteration can stall UI.
- Do: Run capture processing off the main thread; resolve to JS after.

```swift
DispatchQueue.global(qos: .userInitiated).async {
  // process
  DispatchQueue.main.async {
    promise.resolve(result)
  }
}
```

### 8) Stabilize Vision behavior across iOS versions

- Why: Revisions may change runtime/perf.
- Do: Pin a tested revision when necessary.

```swift
let request = VNDetectFaceLandmarksRequest()
if #available(iOS 15, *) {
  request.revision = VNDetectFaceLandmarksRequestRevision3 // example; verify per device
}
```

### 9) Minimize per‑pixel branches

- Why: Branch mispredictions add cost.
- Do: Compute bounds once; use simple comparisons to classify center vs edge.

### 10) Logging discipline

- Why: `print` in hot paths is expensive.
- Do: Wrap logs in `if enableDebug {}` and keep them O(1) per capture.

## Optional UX/flow improvements

- Do anti‑spoofing first on buffers, then write photo to disk (or do I/O on a background queue) to reduce perceived shutter latency.
- Consider a feature flag to toggle “perf mode” for A/B benchmarks.

## Thresholds hygiene

- Keep thresholds in a struct with comments and validated values for depth vs disparity.
- Recheck on new iOS versions/devices.

```swift
private struct Thresholds {
  let range: Float
  let stdDev: Float
  let gradient: Float
  let minSmoothness: Float
  let maxSmoothness: Float
  let validPixels: Float
}
```

## Rollout checklist

- Test on devices with/without TrueDepth (front/back, LiDAR vs no LiDAR).
- Validate “no face”, “one face”, and “multiple faces” flows.
- Measure end‑to‑end capture time and memory (Xcode Instruments).
- Toggle debug heatmap to confirm guard works as intended.

## Benchmark tips

- Use Instruments “Time Profiler” and “Allocations”.
- Record latency from shutter to promise resolve.
- Compare old vs new across 10+ captures per device.
