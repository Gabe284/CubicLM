/// CubicLM Sandbox — Android PRoot backend for Ubuntu and Debian.
///
/// Native Android bridge contract (mirrors Mobile-Harness pocket_spawn.c):
/// - MethodChannel `com.cubiclm.app/proot` with methods:
///   - `ping` {environment} → bool (true when that rootfs passes readiness)
///   - `exec` {environment, command, cwd, timeoutMs} →
///     {stdout: String, stderr: String, exitCode: int}
/// - Native side: fork/exec proot with the selected rootfs at
///   `<filesDir>/runtime/{ubuntu,debian}`, guest cwd `/workspace`,
///   bindings for /dev, /proc, /sys, and the project workspace.
/// - Bundle availability is gated by the verified catalog; no placeholder
///   stack can make the bridge report a ready environment.
///
/// All command callers should use [SandboxManager] so the selected
/// environment and its readiness checks stay consistent.
library;

import 'package:flutter/services.dart';

import 'sandbox_backend.dart';

/// PRoot backend. Available independently for each installed environment.
class ProotBackend implements SandboxBackend {
  static const MethodChannel _channel =
      MethodChannel('com.cubiclm.app/proot');

  String nameFor(String runtimeEnvironment) => runtimeEnvironment == 'debian'
      ? 'PRoot Debian'
      : 'PRoot Ubuntu 20.04';

  @override
  String get name => nameFor('ubuntu');

  @override
  Future<bool> isAvailable({String runtimeEnvironment = 'ubuntu'}) async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('ping', {'environment': runtimeEnvironment})
          .timeout(const Duration(seconds: 3));
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<SandboxResult> run(
    String command, {
    String runtimeEnvironment = 'ubuntu',
    String? workDir,
    Duration timeout = const Duration(seconds: 30),
    Map<String, String>? environment,
  }) async {
    if (!await isAvailable(runtimeEnvironment: runtimeEnvironment)) {
      return const SandboxResult(
        stderr:
            'Selected PRoot environment is not installed or ready.',
        exitCode: -1,
      );
    }
    try {
      final raw = await _channel.invokeMethod<Map>('exec', {
        'environment': runtimeEnvironment,
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
