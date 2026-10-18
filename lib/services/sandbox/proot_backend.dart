/// CubicLM Sandbox — PRoot Linux environment backend.
///
/// Native Android implementation accepts an allowlisted environment name
/// (`ubuntu` or `debian`) through the runtime channel:
/// - MethodChannel `com.cubiclm.app/proot` with methods:
///   - `ping` → bool (true when the selected rootfs is installed + runnable)
///   - `exec` {command: String, cwd: String, timeoutMs: int} →
///     {stdout: String, stderr: String, exitCode: int}
/// - Native side: JNI → fork/exec proot with the rootfs at
///   `<app-support>/runtime/<environment>`, guest cwd `/workspace/<slug>`,
///   bindings for /dev, /proc, /sys, and the project workspace.
/// - Ubuntu and Debian environment bundles install into separate rootfs
///   directories; toolchain overlays currently target Ubuntu only.
/// - The Debian catalog entry stays disabled until its complete bundle is
///   published and verified. Callers should use [SandboxManager] so fallback
///   and readiness checks remain consistent.
library;

import 'package:flutter/services.dart';

import 'sandbox_backend.dart';

/// PRoot backend for the selected Linux environment.
class ProotBackend implements SandboxBackend {
  static const MethodChannel _channel =
      MethodChannel('com.cubiclm.app/proot');

  bool? _cachedAvailable;

  @override
  String get name => 'PRoot Ubuntu 20.04';

  @override
  Future<bool> isAvailable() async {
    if (_cachedAvailable != null) return _cachedAvailable!;
    try {
      final ok = await _channel
          .invokeMethod<bool>('ping')
          .timeout(const Duration(seconds: 3));
      _cachedAvailable = ok ?? false;
    } catch (_) {
      _cachedAvailable = false;
    }
    return _cachedAvailable!;
  }

  /// Forget the cached probe (e.g. after the user installs the runtime).
  void resetCache() {
    _cachedAvailable = null;
  }

  @override
  Future<SandboxResult> run(
    String command, {
    String? workDir,
    Duration timeout = const Duration(seconds: 30),
    Map<String, String>? environment,
  }) async {
    if (!await isAvailable()) {
      return const SandboxResult(
        stderr:
            'PRoot runtime not installed yet — enable it in setup to run commands in isolated Ubuntu.',
        exitCode: -1,
      );
    }
    try {
      final raw = await _channel.invokeMethod<Map>('exec', {
        'command': command,
        'cwd': workDir ?? '',
        'timeoutMs': timeout.inMilliseconds,
      }).timeout(timeout + const Duration(seconds: 5));
      final map = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);
      return SandboxResult(
        stdout: (map['stdout'] ?? '').toString(),
        stderr: (map['stderr'] ?? '').toString(),
        exitCode: (map['exitCode'] as num?)?.toInt() ?? -1,
      );
    } catch (e) {
      return SandboxResult(
          stderr: 'PRoot exec failed: $e', exitCode: -1);
    }
  }
}
