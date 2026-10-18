/// CubicLM Sandbox — backend selector for all command execution.
///
/// Prefers the selected ready PRoot environment. Ubuntu retains its existing
/// host-shell fallback; an unready Debian selection returns an explicit
/// error instead of running the command in the wrong environment.
library;

import 'package:get/get.dart';

import 'host_backend.dart';
import 'proot_backend.dart';
import 'sandbox_backend.dart';
import '../runtime/toolchain_catalog.dart';

/// Selects and exposes the active sandbox backend.
class SandboxManager extends GetxService {
  final ProotBackend proot = ProotBackend();
  final HostBackend host = HostBackend();

  /// Human label of the backend chosen for the last run.
  final activeBackendName = 'Host shell'.obs;
  final selectedEnvironment = RuntimeEnvironment.ubuntu.obs;

  void selectEnvironment(RuntimeEnvironment environment) {
    selectedEnvironment.value = environment;
  }

  Future<SandboxManager> init() async {
    await refresh();
    return this;
  }

  /// Re-probe backends (call after runtime install / uninstall).
  Future<void> refresh() async {
    final runtimeEnvironment = selectedEnvironment.value.name;
    activeBackendName.value = await proot.isAvailable(
            runtimeEnvironment: runtimeEnvironment)
        ? proot.nameFor(runtimeEnvironment)
        : host.name;
  }

  /// True when commands run inside isolated Ubuntu.
  Future<bool> get isIsolated async =>
      await proot.isAvailable(
          runtimeEnvironment: selectedEnvironment.value.name);

  /// Run [command] on the best available backend. Never throws.
  Future<SandboxResult> run(
    String command, {
    String? workDir,
    Duration timeout = const Duration(seconds: 30),
    Map<String, String>? environment,
  }) async {
    final runtimeEnvironment = selectedEnvironment.value.name;
    if (await proot.isAvailable(runtimeEnvironment: runtimeEnvironment)) {
      activeBackendName.value = proot.nameFor(runtimeEnvironment);
      return proot.run(command,
          runtimeEnvironment: runtimeEnvironment,
          workDir: workDir,
          timeout: timeout,
          environment: environment);
    }
    if (selectedEnvironment.value == RuntimeEnvironment.debian) {
      activeBackendName.value = 'Debian unavailable';
      return const SandboxResult(
        stderr: 'Debian is selected but is not installed and ready.',
        exitCode: -1,
      );
    }
    activeBackendName.value = host.name;
    return host.run(command,
        workDir: workDir, timeout: timeout, environment: environment);
  }
}
