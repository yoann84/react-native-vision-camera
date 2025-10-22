import type { Orientation } from './Orientation';
import type { TemporaryFile } from './TemporaryFile';
export interface TakePhotoOptions {
    /**
     * Whether the Flash should be enabled or disabled
     *
     * @default "off"
     */
    flash?: 'on' | 'off' | 'auto';
    /**
     * A custom `path` where the photo will be saved to.
     *
     * This must be a directory, as VisionCamera will generate a unique filename itself.
     * If the given directory does not exist, this method will throw an error.
     *
     * By default, VisionCamera will use the device's temporary directory.
     */
    path?: string;
    /**
     * Specifies whether red-eye reduction should be applied automatically on flash captures.
     *
     * @platform iOS
     * @default false
     */
    enableAutoRedEyeReduction?: boolean;
    /**
     * Specifies whether the photo output should use content aware distortion correction on this photo request.
     * For example, the algorithm may not apply correction to faces in the center of a photo, but may apply it to faces near the photo’s edges.
     *
     * @platform iOS
     * @default false
     */
    enableAutoDistortionCorrection?: boolean;
    /**
     * Whether to play the default shutter "click" sound when taking a picture or not.
     *
     * @default true
     */
    enableShutterSound?: boolean;
    /**
     * Whether to capture depth data along with the photo.
     *
     * Depth data provides distance information for each pixel,
     * enabling features like anti-spoofing detection and 3D reconstruction.
     *
     * Only available on devices with depth-sensing capabilities
     * (TrueDepth, LiDAR, or dual cameras).
     *
     * @platform iOS
     * @default false
     */
    enableDepthData?: boolean;
    /**
     * Enable debug mode for depth-based anti-spoofing.
     *
     * When enabled:
     * - Logs detailed anti-spoofing metrics to console
     * - Generates a debug depth heatmap visualization
     *
     * Only works when `enableDepthData` is also true.
     *
     * @platform iOS
     * @default false
     */
    enableDebug?: boolean;
}
/**
 * Represents a Photo taken by the Camera written to the local filesystem.
 *
 * See {@linkcode Camera.takePhoto | Camera.takePhoto()}
 */
export interface PhotoFile extends TemporaryFile {
    /**
     * The width of the photo, in pixels.
     */
    width: number;
    /**
     * The height of the photo, in pixels.
     */
    height: number;
    /**
     * Whether this photo is in RAW format or not.
     */
    isRawPhoto: boolean;
    /**
     * Display orientation of the photo, relative to the Camera's sensor orientation.
     *
     * Note that Camera sensors are landscape, so e.g. "portrait" photos will have a value of "landscape-left", etc.
     */
    orientation: Orientation;
    /**
     * Whether this photo is mirrored (selfies) or not.
     */
    isMirrored: boolean;
    thumbnail?: Record<string, unknown>;
    /**
     * Metadata information describing the captured image. (iOS only)
     *
     * @see [AVCapturePhoto.metadata](https://developer.apple.com/documentation/avfoundation/avcapturephoto/2873982-metadata)
     *
     * @platform iOS
     */
    metadata?: {
        /**
         * Orientation of the EXIF Image.
         *
         * * 1 = 0 degrees: the correct orientation, no adjustment is required.
         * * 2 = 0 degrees, mirrored: image has been flipped back-to-front.
         * * 3 = 180 degrees: image is upside down.
         * * 4 = 180 degrees, mirrored: image has been flipped back-to-front and is upside down.
         * * 5 = 90 degrees: image has been flipped back-to-front and is on its side.
         * * 6 = 90 degrees, mirrored: image is on its side.
         * * 7 = 270 degrees: image has been flipped back-to-front and is on its far side.
         * * 8 = 270 degrees, mirrored: image is on its far side.
         */
        Orientation: number;
        /**
         * @platform iOS
         */
        DPIHeight: number;
        /**
         * @platform iOS
         */
        DPIWidth: number;
        /**
         * Represents any data Apple cameras write to the metadata
         *
         * @platform iOS
         */
        '{MakerApple}'?: Record<string, unknown>;
        '{TIFF}': {
            ResolutionUnit: number;
            Software: string;
            Make: string;
            DateTime: string;
            XResolution: number;
            /**
             * @platform iOS
             */
            HostComputer?: string;
            Model: string;
            YResolution: number;
        };
        '{Exif}': {
            DateTimeOriginal: string;
            ExposureTime: number;
            FNumber: number;
            LensSpecification: number[];
            ExposureBiasValue: number;
            ColorSpace: number;
            FocalLenIn35mmFilm: number;
            BrightnessValue: number;
            ExposureMode: number;
            LensModel: string;
            SceneType: number;
            PixelXDimension: number;
            ShutterSpeedValue: number;
            SensingMethod: number;
            SubjectArea: number[];
            ApertureValue: number;
            SubsecTimeDigitized: string;
            FocalLength: number;
            LensMake: string;
            SubsecTimeOriginal: string;
            OffsetTimeDigitized: string;
            PixelYDimension: number;
            ISOSpeedRatings: number[];
            WhiteBalance: number;
            DateTimeDigitized: string;
            OffsetTimeOriginal: string;
            ExifVersion: string;
            OffsetTime: string;
            Flash: number;
            ExposureProgram: number;
            MeteringMode: number;
        };
    };
    /**
     * Anti-spoofing result from depth-based face analysis.
     *
     * Contains the result of TrueDepth anti-spoofing checks.
     * Only present when `enableDepthData` is true.
     *
     * @platform iOS
     */
    antiSpoofing?: AntiSpoofingResult;
    /**
     * Debug depth heatmap showing depth values as colors.
     *
     * Base64-encoded JPEG image showing the face region depth map as a heatmap:
     * - Blue: Far (low depth/disparity)
     * - Green/Yellow: Medium distance
     * - Red: Close (high depth/disparity)
     *
     * Only present when `enableDepthData` and `enableDebug` are both true.
     *
     * @platform iOS
     */
    debugDepthHeatmap?: string;
}
/**
 * Result of TrueDepth-based anti-spoofing analysis.
 */
export interface AntiSpoofingResult {
    /**
     * Whether TrueDepth anti-spoofing was enabled for this capture.
     */
    isEnabled: boolean;
    /**
     * Whether the device has TrueDepth capability (depth sensor available).
     */
    hasTrueDepth: boolean;
    /**
     * Whether exactly one face was detected in the image.
     */
    faceDetected: boolean;
    /**
     * Number of faces detected (0, 1, or multiple).
     */
    faceCount: number;
    /**
     * Whether the detected face passed anti-spoofing checks.
     * Only meaningful when `faceDetected` is true.
     */
    isRealFace: boolean;
    /**
     * Human-readable status of the anti-spoofing check.
     *
     * Possible values:
     * - `"success"` - One real face detected, anti-spoofing passed
     * - `"no_face"` - No face detected in the image
     * - `"multiple_faces"` - Multiple faces detected (requires exactly one)
     * - `"spoofing_detected"` - Face detected but failed anti-spoofing checks (fake face, photo, screen)
     * - `"no_depth_data"` - Device doesn't support depth capture
     * - `"disabled"` - Anti-spoofing not enabled
     */
    status: 'success' | 'no_face' | 'multiple_faces' | 'spoofing_detected' | 'no_depth_data' | 'disabled';
    /**
     * Detailed error or status message.
     */
    message: string;
    /**
     * Detailed metrics from the anti-spoofing analysis (only when debug mode is enabled).
     */
    metrics?: {
        /**
         * Depth range (max - min) in the face region.
         * Higher values indicate more 3D variation (real face).
         */
        range: number;
        /**
         * Standard deviation of depth values.
         * Higher values indicate more depth variation (real face).
         */
        stdDeviation: number;
        /**
         * Depth gradient from face center (nose) to edges.
         * Higher values indicate nose protrusion (real face).
         */
        gradient: number;
        /**
         * Smoothness of depth transitions.
         * Values in range indicate natural face contours.
         */
        smoothness: number;
        /**
         * Percentage of pixels with valid depth readings.
         * Higher percentages indicate better sensor lock.
         */
        validPixelPercentage: number;
        /**
         * Number of anti-spoofing checks passed (out of 5).
         */
        checksPassed: number;
        /**
         * Total number of checks performed.
         */
        totalChecks: number;
    };
}
//# sourceMappingURL=PhotoFile.d.ts.map