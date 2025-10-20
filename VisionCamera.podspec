require "json"

package = JSON.parse(File.read(File.join(__dir__, "package", "package.json")))

Pod::UI.puts "[VisionCamera] Thank you for using VisionCamera ❤️"
Pod::UI.puts "[VisionCamera] If you enjoy using VisionCamera, please consider sponsoring this project: https://github.com/sponsors/mrousavy"

enableLocation = true
if defined?($VCEnableLocation)
  Pod::UI.puts "[VisionCamera] $VCEnableLocation is set to #{$VCEnableLocation}!"
  enableLocation = $VCEnableLocation
else
  Pod::UI.puts "[VisionCamera] $VCEnableLocation is not set, enabling CLLocation APIs by default..."
end

enableFrameProcessors = true
if defined?($VCEnableFrameProcessors)
  Pod::UI.puts "[VisionCamera] $VCEnableFrameProcessors is set to #{$VCEnableFrameProcessors}!"
  enableFrameProcessors = $VCEnableFrameProcessors
else
  Pod::UI.puts "[VisionCamera] $VCEnableFrameProcessors is not set, enabling Frame Processors if Worklets is installed..."
end

def Pod::getWorkletsLibraryPath
  output = `cd "#{Pod::Config.instance.installation_root.to_s}" && node --print "try { require.resolve('react-native-worklets-core/package.json') } catch(e) { /* returning undefined, if package not found */ }"`
  
  if output.strip == "undefined"
    return nil
  else
    return File.dirname(output)
  end
end

workletsPath = getWorkletsLibraryPath()
hasWorklets = workletsPath != nil && File.exist?(workletsPath)
if hasWorklets
  Pod::UI.puts("[VisionCamera] react-native-worklets-core found at #{workletsPath}, Frame Processors are #{enableFrameProcessors ? "enabled" : "disabled"}!")
else
  Pod::UI.puts("[VisionCamera] react-native-worklets-core not found - Frame Processors are disabled!")
  enableFrameProcessors = false
end

Pod::Spec.new do |s|
  s.name         = "VisionCamera"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.description  = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "12.4" }
  s.source       = { :git => "https://github.com/mrousavy/react-native-vision-camera.git", :tag => "#{s.version}" }

  s.pod_target_xcconfig = {
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) VISION_CAMERA_ENABLE_FRAME_PROCESSORS=#{enableFrameProcessors}",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "$(inherited) #{enableFrameProcessors ? "VISION_CAMERA_ENABLE_FRAME_PROCESSORS" : ""}",
  }

  s.requires_arc = true

  s.subspec 'Core' do |core|
    # VisionCamera Core Swift codebase
    core.source_files = [
      "package/ios/Core/**/*.swift"
    ]

    core.pod_target_xcconfig = {
      "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "$(inherited) #{enableLocation ? "VISION_CAMERA_ENABLE_LOCATION" : ""}",
    }
  end

  s.subspec 'React' do |core|
    # VisionCamera React-specific Swift codebase
    core.source_files = [
      "package/ios/React/**/*.swift",
      "package/ios/React/**/*.{h,m}",
    ]
    core.public_header_files = [
      "package/ios/React/CameraBridge.h"
    ]

    core.dependency "React-Core"
    if enableFrameProcessors
      core.dependency "VisionCamera/FrameProcessors"
    end
  end

  if enableFrameProcessors
    s.subspec 'FrameProcessors' do |fp|
      # VisionCamera Frame Processors C++ codebase (optional)
      fp.source_files = [
        "package/ios/FrameProcessors/**/*.{h,m,mm}"
      ]
      fp.public_header_files = [
        # Swift/Objective-C visible headers
        "package/ios/FrameProcessors/Frame.h",
        "package/ios/FrameProcessors/FrameProcessor.h",
        "package/ios/FrameProcessors/FrameProcessorPlugin.h",
        "package/ios/FrameProcessors/FrameProcessorPluginRegistry.h",
        "package/ios/FrameProcessors/SharedArray.h",
        "package/ios/FrameProcessors/VisionCameraProxyDelegate.h",
        "package/ios/FrameProcessors/VisionCameraProxyHolder.h",
        "package/ios/FrameProcessors/VisionCameraInstaller.h",
      ]

      fp.pod_target_xcconfig = {
        "CLANG_CXX_LANGUAGE_STANDARD" => "c++17",
      }

      fp.dependency "React"
      fp.dependency "React-callinvoker"
      fp.dependency "react-native-worklets-core"
    end
  end
end
