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
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    :script => 'export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-C link-arg=-undefined -C link-arg=dynamic_lookup" CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUSTFLAGS="-C link-arg=-undefined -C link-arg=dynamic_lookup" CARGO_TARGET_X86_64_APPLE_IOS_RUSTFLAGS="-C link-arg=-undefined -C link-arg=dynamic_lookup"; sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust rust_lib_segmeris',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    :output_files => ["${BUILT_PRODUCTS_DIR}/librust_lib_segmeris.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/librust_lib_segmeris.a -lc++ -lz -liconv -lresolv -framework Security -framework SystemConfiguration -framework CoreFoundation -framework CFNetwork',
  }
end
