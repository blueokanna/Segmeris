import 'dart:ffi';
import 'dart:io';

String updateOperatingSystem() => Platform.operatingSystem;

/// Process ABI is the architecture that can run this app and its replacement.
/// Never infer it from the OS name (Windows and macOS can also be ARM hosts).
String updateArchitecture() => switch (Abi.current()) {
  Abi.androidArm64 ||
  Abi.linuxArm64 ||
  Abi.macosArm64 ||
  Abi.windowsArm64 => 'arm64',
  Abi.androidArm || Abi.linuxArm => 'arm',
  Abi.androidX64 || Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => 'x64',
  _ => 'unknown',
};
