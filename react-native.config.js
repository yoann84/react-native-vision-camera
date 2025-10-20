const path = require('path');

module.exports = {
  dependency: {
    platforms: {
      ios: {
        podspecPath: path.join(__dirname, 'package', 'VisionCamera.podspec'),
      },
      android: {
        sourceDir: path.join(__dirname, 'package', 'android'),
        packageImportPath: 'import com.mrousavy.camera.react.CameraPackage;',
      },
    },
  },
};

