#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint rust_lib_segmeris.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'rust_lib_segmeris'
  s.version          = '1.0.8'
  s.summary          = 'Segmeris Rust download engine and Flutter bridge.'
  s.description      = <<-DESC
Builds and links the Segmeris Rust runtime for Flutter.
                       DESC
  s.homepage         = 'https://github.com/blueokanna/Segmeris'
  s.license          = { :file => '../../LICENSE' }
  s.author           = 'blueokanna'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust rust_lib_segmeris',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    :output_files => ["${BUILT_PRODUCTS_DIR}/librust_lib_segmeris.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/librust_lib_segmeris.a -lc++ -framework Security -framework SystemConfiguration -framework CoreFoundation',
  }
end
