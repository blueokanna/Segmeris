/// This is copied from Cargokit (which is the official way to use it currently)
/// Details: https://fzyzcjy.github.io/flutter_rust_bridge/manual/integrate/builtin

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;

import 'util.dart';

class _Toolchain {
  _Toolchain(
    this.name,
    this.targets,
  );

  final String name;
  final List<String> targets;
}

class Rustup {
  List<String>? installedTargets(String toolchain) {
    final targets = _installedTargets(toolchain);
    return targets != null ? List.unmodifiable(targets) : null;
  }

  void installToolchain(String toolchain) {
    log.info("Installing Rust toolchain: $toolchain");
    runCommand("rustup", ['toolchain', 'install', toolchain]);
    _installedToolchains
        .add(_Toolchain(toolchain, _getInstalledTargets(toolchain)));
  }

  void installTarget(
    String target, {
    required String toolchain,
  }) {
    log.info("Installing Rust target: $target");
    runCommand("rustup", [
      'target',
      'add',
      '--toolchain',
      toolchain,
      target,
    ]);
    _installedTargets(toolchain)?.add(target);
  }

  final List<_Toolchain> _installedToolchains;

  Rustup() : _installedToolchains = _getInstalledToolchains();

  List<String>? _installedTargets(String toolchain) => _installedToolchains
      .firstWhereOrNull(
          (e) => e.name == toolchain || e.name.startsWith('$toolchain-'))
      ?.targets;

  static List<_Toolchain> _getInstalledToolchains() {
    String extractToolchainName(String line) {
      // ignore (default) after toolchain name
      final parts = line.split(' ');
      return parts[0];
    }

    final res = runCommand("rustup", ['toolchain', 'list']);

    // To list all non-custom toolchains, we need to filter out lines that
    // don't start with "stable", "beta", or "nightly".
    Pattern nonCustom = RegExp(r"^(stable|beta|nightly)");
    final lines = res.stdout
        .toString()
        .split('\n')
        .where((e) => e.isNotEmpty && e.startsWith(nonCustom))
        .map(extractToolchainName)
        .toList(growable: true);

    return lines
        .map(
          (name) => _Toolchain(
            name,
            _getInstalledTargets(name),
          ),
        )
        .toList(growable: true);
  }

  static List<String> _getInstalledTargets(String toolchain) {
    final res = runCommand("rustup", [
      'target',
      'list',
      '--toolchain',
      toolchain,
      '--installed',
    ]);
    final lines = res.stdout
        .toString()
        .split('\n')
        .where((e) => e.isNotEmpty)
        .toList(growable: true);
    return lines;
  }

  bool _didInstallRustSrcForNightly = false;

  void installRustSrcForNightly() {
    if (_didInstallRustSrcForNightly) {
      return;
    }
    // Useful for -Z build-std
    runCommand(
      "rustup",
      ['component', 'add', 'rust-src', '--toolchain', 'nightly'],
    );
    _didInstallRustSrcForNightly = true;
  }

  static String? executablePath() {
    final envPath = Platform.environment['PATH'];
    final envPathSeparator = Platform.isWindows ? ';' : ':';
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    final paths = [
      if (home != null) path.join(home, '.cargo', 'bin'),
      if (envPath != null) ...envPath.split(envPathSeparator),
    ];
    for (final p in paths) {
      final rustup = Platform.isWindows ? 'rustup.exe' : 'rustup';
      final rustupPath = path.join(p, rustup);
      if (File(rustupPath).existsSync()) {
        return rustupPath;
      }
    }
    return null;
  }

  /// Path of the rustup `rustc` proxy in the default cargo home
  /// (`$HOME/.cargo/bin/rustc`), or `null` when rustup is installed
  /// elsewhere.
  ///
  /// The build tool hands this to cargo through `RUSTC`: `rustup run` picks
  /// the toolchain, but cargo still resolves `rustc` through `PATH`, where a
  /// standalone Rust installation (a stale "Rust 1.78" under Program Files,
  /// a Homebrew rustc, …) can shadow the rustup shim and fail the build with
  /// confusing flag errors. The proxy honours the `RUSTUP_TOOLCHAIN` that
  /// `rustup run` propagates, so the compiler always matches the toolchain.
  static String? rustcProxyPath() {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE']
        : Platform.environment['HOME'];
    if (home == null) {
      return null;
    }
    final rustc = Platform.isWindows ? 'rustc.exe' : 'rustc';
    final candidate = path.join(home, '.cargo', 'bin', rustc);
    return File(candidate).existsSync() ? candidate : null;
  }
}
