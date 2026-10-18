/// CubicLM Runtime Toolchain Installer — downloads, verifies and extracts
/// the on-device Linux runtime + opt-in stacks (GetxService).
///
/// Mirrors the reference app's toolchain setup as our own cross-platform
/// implementation:
/// - Catalog: [ToolchainCatalog] (core Ubuntu rootfs + node/python/
///   android/cpp/php overlays, self-hostable base URL).
/// - Download: HTTP Range resume into `.part` files with progress.
/// - Verify: SHA-256 from the catalog or a `<file>.sha256` sidecar.
/// - Extract: system `tar -tzf` listing validated with
///   [ToolchainCatalog.unsafeMemberReason] (traversal guard that
///   understands symlinks), then `tar -xzf`.
/// - State: per-stack observables + Hive persistence + marker files.
/// - Keep-alive: `com.cubiclm.app/runtime` channel holds a foreground
///   service + wakelock during long installs (Android; no-op elsewhere).
///
/// A rootfs is ready only after its marker, shell, DNS, PRoot executable,
/// loader, libraries, and native execution probe all pass. The selected
/// environment is shared by terminal and agent shell execution.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../hive_service.dart';
import '../app_log_service.dart';
import '../sandbox/sandbox_manager.dart';
import 'toolchain_catalog.dart';

/// Live install status of one stack (bound by the setup UI).
class StackStatus {
  final ToolchainState state;
  final double fraction;
  final int downloadedBytes;
  final int totalBytes;
  final String line;
  final String? error;

  const StackStatus({
    this.state = ToolchainState.unknown,
    this.fraction = 0,
    this.downloadedBytes = 0,
    this.totalBytes = -1,
    this.line = '',
    this.error,
  });

  StackStatus copyWith({
    ToolchainState? state,
    double? fraction,
    int? downloadedBytes,
    int? totalBytes,
    String? line,
    String? error,
  }) =>
      StackStatus(
        state: state ?? this.state,
        fraction: fraction ?? this.fraction,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        line: line ?? this.line,
        error: error,
      );
}

/// Toolchain bundle installer (registered in main deferred init).
class RuntimeInstaller extends GetxService {
  static const _channel = MethodChannel('com.cubiclm.app/runtime');
  static const _prootChannel = MethodChannel('com.cubiclm.app/proot');
  static const _kInstalledKey = 'runtime_installed_stacks_v1';
  static const _kBaseUrlKey = 'runtime_base_url';
  static const _kSelectedEnvironmentKey = 'runtime_selected_environment';

  /// Observable status per stack id.
  final statuses = <ToolchainId, StackStatus>{}.obs;

  /// Overall busy flag (one install at a time, like the CLI queue).
  final busy = false.obs;
  final selectedEnvironment = RuntimeEnvironment.ubuntu.obs;

  String _root = '';
  bool _cancelRequested = false;

  Future<RuntimeInstaller> init() async {
    for (final s in ToolchainCatalog.stacks()) {
      statuses[s.id] = const StackStatus();
    }
    await refresh();
    final savedEnvironment =
        _hive?.getSetting<String>(_kSelectedEnvironmentKey);
    selectedEnvironment.value = savedEnvironment == 'debian'
        ? RuntimeEnvironment.debian
        : RuntimeEnvironment.ubuntu;
    _syncSelectedEnvironment();
    await _reportRuntimeRoot();
    return this;
  }

  HiveService? get _hive =>
      Get.isRegistered<HiveService>() ? Get.find<HiveService>() : null;

  // ── Paths ──────────────────────────────────────────────────────────

  Future<String> get _runtimeRoot async {
    if (_root.isNotEmpty) return _root;
    final base = await getApplicationSupportDirectory();
    _root = '${base.path}/runtime';
    return _root;
  }

  Future<Directory> get _cacheDir async =>
      Directory('${await _runtimeRoot}/cache')..createSync(recursive: true);

  Future<Directory> _rootfsDir(String name) async =>
      Directory('${await _runtimeRoot}/$name');

  Future<void> selectEnvironment(RuntimeEnvironment environment) async {
    selectedEnvironment.value = environment;
    try {
      await _hive?.setSetting(_kSelectedEnvironmentKey, environment.name);
    } catch (_) {}
    _syncSelectedEnvironment();
    await _refreshSandbox();
  }

  void _syncSelectedEnvironment() {
    try {
      if (Get.isRegistered<SandboxManager>()) {
        Get.find<SandboxManager>().selectEnvironment(selectedEnvironment.value);
      }
    } catch (_) {}
  }

  String _markerFor(ToolchainId id) => '$_root/.ready-${id.name}';

  String get baseUrl =>
      _hive?.getSetting<String>(_kBaseUrlKey) ??
      ToolchainCatalog.defaultBaseUrl;

  Future<void> setBaseUrl(String url) async {
    try {
      await _hive?.setSetting(_kBaseUrlKey, url.trim());
    } catch (_) {}
  }

  // ── State ──────────────────────────────────────────────────────────

  /// Re-probe marker files → statuses. Call on start + after changes.
  Future<void> refresh() async {
    if (kIsWeb) return;
    try {
      await _runtimeRoot;
      for (final s in ToolchainCatalog.stacks()) {
        final ready = await _isStackReady(s.id);
        final cur = statuses[s.id] ?? const StackStatus();
        // Never clobber an in-flight state.
        if (cur.state == ToolchainState.downloading ||
            cur.state == ToolchainState.verifying ||
            cur.state == ToolchainState.extracting) {
          continue;
        }
        statuses[s.id] = cur.copyWith(
          state: ready ? ToolchainState.ready : ToolchainState.notInstalled,
          error: null,
        );
      }
    } catch (_) {}
  }

  Future<bool> _isStackReady(ToolchainId id) async {
    try {
      if (!File(_markerFor(id)).existsSync()) return false;
      if (id == ToolchainId.core) {
        final filesPresent = File('$_root/ubuntu/usr/bin/bash').existsSync() &&
            File('$_root/bin/proot').existsSync() &&
            File('$_root/libexec/proot/loader').existsSync() &&
            File('$_root/lib/libtalloc.so.2').existsSync() &&
            File('$_root/lib/libandroid-shmem.so').existsSync() &&
            File('$_root/ubuntu/etc/resolv.conf').existsSync();
        return filesPresent && await _probeNativeEnvironment('ubuntu');
      }
      if (id == ToolchainId.debian) {
        final support = '$_root/debian/.cubiclm-proot';
        final filesPresent = (File('$_root/debian/bin/bash').existsSync() ||
                File('$_root/debian/usr/bin/bash').existsSync()) &&
            File('$_root/debian/etc/resolv.conf').existsSync() &&
            File('$support/bin/proot').existsSync() &&
            File('$support/libexec/proot/loader').existsSync() &&
            File('$support/lib/libtalloc.so.2').existsSync() &&
            File('$support/lib/libandroid-shmem.so').existsSync();
        return filesPresent && await _probeNativeEnvironment('debian');
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True when the isolated Ubuntu runtime can execute commands.
  Future<bool> get isCoreReady async {
    if (kIsWeb) return false;
    try {
      await _runtimeRoot;
      return await _isStackReady(ToolchainId.core);
    } catch (_) {
      return false;
    }
  }

  /// Preflight warnings for installing [id]. Empty = good to go.
  /// Core needs Android + ARM64 (proot + rootfs are ARM64-only).
  Future<List<String>> preflight(ToolchainId id) async {
    final warnings = <String>[];
    if (kIsWeb) {
      return ['Toolchain install needs Android or desktop.'];
    }
    if ((id == ToolchainId.core || id == ToolchainId.debian) &&
        !Platform.isAndroid) {
      warnings.add('Linux rootfs environments need Android (PRoot).');
    }
    if ((id == ToolchainId.core || id == ToolchainId.debian) &&
        Platform.isAndroid) {
      final abi = await _androidAbi();
      if (abi.isNotEmpty && !abi.contains('arm64')) {
        warnings.add('Linux rootfs environments need ARM64 (found $abi).');
      }
    }
    if ((id == ToolchainId.node || id == ToolchainId.python) &&
        !ToolchainCatalog.supportsOverlay(id, selectedEnvironment.value)) {
      warnings.add(
        '${ToolchainCatalog.stackOf(id).title} overlays are supported in Ubuntu only.',
      );
    }
    final stack = ToolchainCatalog.stackOf(id);
    if (stack.needsCore && !await isCoreReady) {
      warnings.add('Install the Core Ubuntu runtime first.');
    }
    return warnings;
  }

  Future<String> _androidAbi() async {
    try {
      final r = await Process.run(
        'getprop',
        ['ro.product.cpu.abi'],
        runInShell: false,
      ).timeout(const Duration(seconds: 5));
      return (r.stdout ?? '').toString().trim();
    } catch (_) {
      return '';
    }
  }

  // ── Install / remove ───────────────────────────────────────────────

  /// Runtime-lane logging: trail every install/remove, warning row only
  /// on failure. Never throws.
  void _rtLog(String message, {bool warn = false, Object? details}) {
    try {
      AppLogService.trailAction(message);
      if (warn && Get.isRegistered<AppLogService>()) {
        Get.find<AppLogService>().warning(
          message,
          details: details,
          category: LogCategory.runtime,
        );
      }
    } catch (_) {}
  }

  /// Install [id] (all its bundles in order). One at a time; returns null
  /// on success, else an error message. Never throws.
  Future<String?> install(ToolchainId id) async {
    if (kIsWeb) return 'Toolchain install needs Android or desktop.';
    if (busy.value) return 'Another install is already running.';
    final stack = ToolchainCatalog.stackOf(id);
    if (!stack.available) {
      return stack.unavailableReason ?? 'No verified bundle is available.';
    }
    final blocks = await preflight(id);
    if (blocks.isNotEmpty) return blocks.join('\n');

    busy.value = true;
    _cancelRequested = false;
    _rtLog('runtime install ${id.name} started');
    await _setKeepAlive(true);
    try {
      final oldMarker = File(_markerFor(id));
      if (await oldMarker.exists()) await oldMarker.delete();
      for (final bundle in stack.bundles) {
        final err = await _installBundle(id, bundle);
        if (err != null) {
          _set(id, state: ToolchainState.failed, error: err);
          _rtLog('runtime install ${id.name} failed',
              warn: true, details: err);
          return err;
        }
        if (_cancelRequested) {
          _set(id, state: ToolchainState.notInstalled, line: 'Cancelled.');
          AppLogService.trailAction(
              'runtime install ${id.name} cancelled');
          return 'Cancelled.';
        }
      }
      await _writeMarker(id, stack.bundles.map((b) => b.version).join(','));
      if (id == ToolchainId.core || id == ToolchainId.debian) {
        final environment =
            id == ToolchainId.core ? 'ubuntu' : 'debian';
        final runnable = await _probeNativeEnvironment(environment);
        if (!runnable) {
          try {
            await File(_markerFor(id)).delete();
          } catch (_) {}
          const error =
              'Rootfs files passed layout checks, but PRoot could not execute the readiness probe.';
          _set(id, state: ToolchainState.failed, error: error);
          return error;
        }
      }
      await _persistInstalled();
      _set(id, state: ToolchainState.ready, fraction: 1, line: 'Ready.');
      AppLogService.trailAction('runtime install ${id.name} ready');
      await _refreshSandbox();
      return null;
    } catch (e) {
      final marker = File(_markerFor(id));
      try {
        if (await marker.exists()) await marker.delete();
      } catch (_) {}
      final error = 'Runtime installation failed: $e';
      _set(id, state: ToolchainState.failed, error: error);
      _rtLog('runtime install ${id.name} failed', warn: true, details: e);
      return error;
    } finally {
      busy.value = false;
      await _setKeepAlive(false);
    }
  }

  /// Cancel the in-flight install (checked between bundles/chunks).
  void cancel() {
    _cancelRequested = true;
  }

  /// Remove one stack. Ubuntu and Debian rootfs directories are deleted
  /// independently; shared legacy PRoot files are removed only when Debian
  /// is not ready. Never throws.
  Future<void> remove(ToolchainId id) async {
    if (busy.value) return;
    try {
      await _runtimeRoot;
      if (id == ToolchainId.core || id == ToolchainId.debian) {
        final environment =
            id == ToolchainId.core ? 'ubuntu' : 'debian';
        final rootfs = await _rootfsDir(environment);
        if (await rootfs.exists()) await rootfs.delete(recursive: true);
        final marker = File(_markerFor(id));
        if (await marker.exists()) await marker.delete();
        if (id == ToolchainId.core) {
          for (final stack in ToolchainCatalog.stacks().where((s) => s.needsCore)) {
            final overlayMarker = File(_markerFor(stack.id));
            if (await overlayMarker.exists()) await overlayMarker.delete();
          }
          if (!await _isStackReady(ToolchainId.debian)) {
            await _removeSharedProot();
          }
        }
      } else {
        final m = File(_markerFor(id));
        if (await m.exists()) await m.delete();
      }
      await _persistInstalled();
      await refresh();
      await _refreshSandbox();
      AppLogService.trailAction('runtime ${id.name} removed');
    } catch (_) {}
  }

  Future<void> _refreshSandbox() async {
    try {
      if (Get.isRegistered<SandboxManager>()) {
        await Get.find<SandboxManager>().refresh();
      }
    } catch (_) {}
  }

  Future<bool> _probeNativeEnvironment(String environment) async {
    try {
      final result = await _prootChannel.invokeMethod<bool>(
        'ping',
        {'environment': environment},
      ).timeout(const Duration(seconds: 15));
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeSharedProot() async {
    for (final shared in [
      Directory('$_root/bin'),
      Directory('$_root/lib'),
      Directory('$_root/libexec'),
    ]) {
      if (await shared.exists()) await shared.delete(recursive: true);
    }
  }

  /// Rootfs bundles lay down their environment plus its PRoot support
  /// files. Overlays merge into Ubuntu. Pure for unit tests.
  static String extractSubdirFor(ToolchainId id) =>
      id == ToolchainId.core || id == ToolchainId.debian ? '' : 'ubuntu';

  /// Guest DNS: ubuntu-base ships no resolv.conf, so without this every
  /// network call inside proot (npm, apt, git) fails.
  static const _resolvConf = 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n';

  Future<String?> _installBundle(ToolchainId id, RuntimeBundle bundle) async {
    final cache = await _cacheDir;
    final dest = File('${cache.path}/${bundle.fileName}');

    // 1. Download (resume .part).
    _set(id, state: ToolchainState.downloading, line: 'Downloading ${bundle.title}…');
    final url = ToolchainCatalog.bundleUrl(baseUrl, bundle);
    final dlErr = await _downloadWithResume(url, dest, id);
    if (dlErr != null) return dlErr;
    if (_cancelRequested) return 'Cancelled.';

    // 2. Verify SHA-256.
    _set(id, state: ToolchainState.verifying, line: 'Verifying ${bundle.title}…');
    final sumErr = await _verifyChecksum(url, dest, bundle, id);
    if (sumErr != null) return sumErr;
    if (_cancelRequested) return 'Cancelled.';

    // 3. Extract (core → runtime root, overlays → rootfs).
    _set(id,
        state: ToolchainState.extracting,
        line: 'Extracting ${bundle.title}…');
    final root = await _runtimeRoot;
    final sub = extractSubdirFor(id);
    final target = sub.isEmpty ? Directory(root) : await _rootfsDir(sub);
    await target.create(recursive: true);
    final exErr = await _extractTarGz(dest, target);
    if (exErr != null) return exErr;
    // 4. Core post-steps: guest DNS + PRoot mode, then check the complete
    // runtime layout before the caller is allowed to write its marker.
    if (id == ToolchainId.core || id == ToolchainId.debian) {
      final finErr = await _finalizeEnvironment(
        root,
        id == ToolchainId.core ? 'ubuntu' : 'debian',
      );
      if (finErr != null) return finErr;
    }
    return null;
  }

  /// Write resolv.conf + ensure `bin/proot` is executable. Returns an
  /// error string, or null on success. Never throws.
  Future<String?> _finalizeEnvironment(String root, String environment) async {
    final rootfs = Directory('$root/$environment');
    final supportRoot = environment == 'debian'
        ? Directory('${rootfs.path}/.cubiclm-proot')
        : Directory(root);
    try {
      final etc = Directory('${rootfs.path}/etc');
      await etc.create(recursive: true);
      await File('${etc.path}/resolv.conf')
          .writeAsString(_resolvConf, flush: true);
    } catch (e) {
      return 'Could not write guest DNS config: $e';
    }
    try {
      final proot = File('${supportRoot.path}/bin/proot');
      if (!await proot.exists()) {
        return '$environment bundle is missing its PRoot binary.';
      }
      final chmod = await Process.run(
        'chmod',
        ['0755', proot.path],
        runInShell: false,
      ).timeout(const Duration(seconds: 10));
      if (chmod.exitCode != 0) {
        return 'Could not make the bundled PRoot binary executable.';
      }
      if (((await proot.stat()).mode & 0x40) == 0) {
        return 'The bundled PRoot binary is not executable after chmod.';
      }
      final loader = File('${supportRoot.path}/libexec/proot/loader');
      if (!await loader.exists()) {
        return '$environment bundle is missing the PRoot loader.';
      }
      final loaderChmod = await Process.run(
        'chmod',
        ['0755', loader.path],
        runInShell: false,
      ).timeout(const Duration(seconds: 10));
      if (loaderChmod.exitCode != 0) {
        return 'Could not make the PRoot loader executable.';
      }
      if (((await loader.stat()).mode & 0x40) == 0) {
        return 'The PRoot loader is not executable after chmod.';
      }
      for (final relative in [
        'libexec/proot/loader',
        'lib/libtalloc.so.2',
        'lib/libandroid-shmem.so',
      ]) {
        if (!await File('${supportRoot.path}/$relative').exists()) {
          return '$environment bundle is incomplete: missing $relative.';
        }
      }
      if (!await File('$root/$environment/bin/bash').exists() &&
          !await File('$root/$environment/usr/bin/bash').exists()) {
        return 'Rootfs is incomplete: missing $environment bash.';
      }
      final dns = await File('${etc.path}/resolv.conf').readAsString();
      if (!dns.contains('nameserver ')) {
        return 'Guest DNS configuration is incomplete.';
      }
    } catch (e) {
      return 'Could not finalize $environment: $e';
    }
    return null;
  }

  // ── Download ───────────────────────────────────────────────────────

  Future<String?> _downloadWithResume(String url, File dest, ToolchainId id) async {
    final part = File('${dest.path}.part');
    var startAt = 0;
    try {
      if (await part.exists()) startAt = await part.length();
      if (await dest.exists() && startAt == 0) {
        // Complete file from a previous run — keep it, verify next.
        _set(id, fraction: 1, line: 'Found cached download.');
        return null;
      }
    } catch (_) {}

    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      var target = url;
      HttpClientResponse? resp;
      for (var redirects = 0; redirects < 5; redirects++) {
        final req = await client.getUrl(Uri.parse(target));
        req.headers.set('User-Agent', 'CubicLM-runtime-installer/1.0');
        if (startAt > 0) req.headers.set('Range', 'bytes=$startAt-');
        req.followRedirects = false;
        resp = await req.close().timeout(const Duration(seconds: 60));
        if (resp.isRedirect && resp.statusCode != 304) {
          final loc = resp.headers.value('location');
          await resp.drain();
          if (loc == null || loc.isEmpty) {
            return 'Download redirect without location.';
          }
          target = loc;
          continue;
        }
        break;
      }
      final r = resp!;
      if (r.statusCode == 416) {
        // Range beyond EOF — restart cleanly.
        try {
          await part.delete();
        } catch (_) {}
        startAt = 0;
        return await _downloadWithResume(url, dest, id);
      }
      if (r.statusCode != 200 && r.statusCode != 206) {
        await r.drain();
        if (r.statusCode == 404) {
          return 'Bundle not published yet (${Uri.parse(url).pathSegments.last}). '
              'Core + stacks ship with the runtime release — check Settings → Runtime.';
        }
        return 'Download failed (HTTP ${r.statusCode}).';
      }
      if (r.statusCode == 200 && startAt > 0) {
        // Server ignored Range — restart from zero.
        startAt = 0;
        try {
          await part.delete();
        } catch (_) {}
      }
      final total = (r.contentLength < 0 ? -1 : r.contentLength + startAt);
      var received = startAt;
      final sink = part.openWrite(mode: FileMode.append);
      try {
        await for (final chunk in r) {
          if (_cancelRequested) {
            await sink.flush();
            await sink.close();
            return 'Cancelled.';
          }
          sink.add(chunk);
          received += chunk.length;
          final frac = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
          _set(
            id,
            fraction: frac,
            downloadedBytes: received,
            totalBytes: total,
            line:
                'Downloading… ${ToolchainCatalog.formatBytes(received)}${total > 0 ? ' / ${ToolchainCatalog.formatBytes(total)}' : ''}',
          );
          if (received % (4 * 1024 * 1024) < chunk.length) {
            await _pushProgress(id);
          }
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      try {
        if (await dest.exists()) await dest.delete();
        await part.rename(dest.path);
      } catch (e) {
        return 'Could not finalize download: $e';
      }
      _set(id, fraction: 1, line: 'Download complete.');
      return null;
    } catch (e) {
      return 'Download failed: $e';
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  // ── Verify ─────────────────────────────────────────────────────────

  Future<String?> _verifyChecksum(
    String url,
    File dest,
    RuntimeBundle bundle,
    ToolchainId id,
  ) async {
    var expected = bundle.sha256.trim().toLowerCase();
    if (!bundle.hasEmbeddedChecksum) {
      expected = await _fetchSidecarChecksum(
        ToolchainCatalog.checksumUrl(baseUrl, bundle),
      );
    }
    if (expected.isEmpty) {
      return 'No SHA-256 checksum is available for ${bundle.fileName}; refusing to install an unverified bundle.';
    }
    try {
      final digest = await _sha256File(dest, (done, total) {
        _set(
          id,
          fraction: total > 0 ? (done / total).clamp(0.0, 1.0) : 0,
          line: 'Verifying… ${ToolchainCatalog.formatBytes(done)}',
        );
      });
      if (digest != expected) {
        try {
          await dest.delete();
        } catch (_) {}
        return 'Checksum mismatch — deleted the corrupt file, retry the install.';
      }
      return null;
    } catch (e) {
      return 'Verify failed: $e';
    }
  }

  Future<String> _fetchSidecarChecksum(String url) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 20);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'CubicLM-runtime-installer/1.0');
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        await resp.drain();
        return '';
      }
      final text = await resp.transform(utf8.decoder).join();
      final m = RegExp(r'[0-9a-fA-F]{64}').firstMatch(text);
      return (m?.group(0) ?? '').toLowerCase();
    } catch (_) {
      return '';
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  Future<String> _sha256File(
    File file,
    void Function(int done, int total) onProgress,
  ) async {
    final total = await file.length();
    var done = 0;
    // Stream the file through sha256 without holding it all in memory.
    // Report progress per chunk (matches Mobile-Harness verify UX).
    final digest = await sha256.bind(
      file.openRead().map((chunk) {
        done += chunk.length;
        onProgress(done, total);
        return chunk;
      }),
    ).first;
    return digest.toString();
  }

  // ── Extract ────────────────────────────────────────────────────────

  /// List-then-extract with a traversal guard. Uses system `tar`
  /// (Android toybox, desktop bsdtar/GNU) so multi-hundred-MB bundles never
  /// sit fully in memory.
  Future<String?> _extractTarGz(File archive, Directory dest) async {
    // 1. List members.
    List<String> members;
    try {
      final list = await Process.run(
        _tarBin(),
        ['-tzf', archive.path],
        runInShell: false,
      ).timeout(const Duration(minutes: 5));
      if (list.exitCode != 0) {
        return 'Could not list bundle: ${(list.stderr ?? '').toString().trim()}';
      }
      members = (list.stdout ?? '')
          .toString()
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (e) {
      return 'Archive listing failed: $e';
    }
    // 2. Traversal guard (pure, no I/O). Understands `a -> b` symlink
    // lines and in-root `..` (distro links like fstab); rejects escapes.
    for (final m in members) {
      final reason = ToolchainCatalog.unsafeMemberReason(dest.path, m);
      if (reason != null) {
        return 'Blocked unsafe bundle entry: $reason';
      }
    }
    if (members.isEmpty) return 'Bundle is empty.';
    // 3. Extract.
    try {
      final ex = await Process.run(
        _tarBin(),
        ['-xzf', archive.path, '-C', dest.path],
        runInShell: false,
      ).timeout(const Duration(minutes: 30));
      if (ex.exitCode != 0) {
        return 'Extract failed: ${(ex.stderr ?? '').toString().trim()}';
      }
      return null;
    } catch (e) {
      return 'Extract failed: $e';
    }
  }

  String _tarBin() =>
      Platform.isWindows ? 'tar.exe' : 'tar';

  // ── Markers + persistence ──────────────────────────────────────────

  Future<void> _writeMarker(ToolchainId id, String version) async {
    await _runtimeRoot;
    final marker = File(_markerFor(id));
    final temporary = File('${marker.path}.tmp');
    await temporary.writeAsString(
      'version=$version\ninstalled=${DateTime.now().millisecondsSinceEpoch}\n',
      flush: true,
    );
    await temporary.rename(marker.path);
  }

  Future<void> _persistInstalled() async {
    try {
      final ready = <String>[];
      for (final s in ToolchainCatalog.stacks()) {
        if (await _isStackReady(s.id)) ready.add(s.id.name);
      }
      await _hive?.setSetting(_kInstalledKey, ready);
    } catch (_) {}
  }

  // ── Native keep-alive + progress ───────────────────────────────────

  /// Tell the native side where the runtime root lives (proot ping/exec).
  Future<void> _reportRuntimeRoot() async {
    try {
      if (kIsWeb) return;
      final root = await _runtimeRoot;
      await _channel.invokeMethod('setRuntimeRoot', {'path': root}).timeout(
            const Duration(seconds: 5),
          );
    } on MissingPluginException {
      // No native runtime channel (desktop/web tests) — ignore.
    } catch (_) {}
  }

  Future<void> _setKeepAlive(bool active) async {
    try {
      await _channel.invokeMethod('setKeepAlive', {'active': active}).timeout(
            const Duration(seconds: 5),
          );
    } on MissingPluginException {
      // Desktop/web — no foreground service needed.
    } catch (_) {}
  }

  Future<void> _pushProgress(ToolchainId id) async {
    try {
      final st = statuses[id] ?? const StackStatus();
      await _channel.invokeMethod('updateProgress', {
        'title': 'Installing ${ToolchainCatalog.stackOf(id).title}',
        'fraction': st.fraction.clamp(0.0, 1.0),
        'line': st.line,
      }).timeout(const Duration(seconds: 3));
    } on MissingPluginException {
      // Desktop/web — no native progress surface.
    } catch (_) {}
  }

  void _set(
    ToolchainId id, {
    ToolchainState? state,
    double? fraction,
    int? downloadedBytes,
    int? totalBytes,
    String? line,
    String? error,
  }) {
    final cur = statuses[id] ?? const StackStatus();
    statuses[id] = cur.copyWith(
      state: state ?? cur.state,
      fraction: fraction ?? cur.fraction,
      downloadedBytes: downloadedBytes ?? cur.downloadedBytes,
      totalBytes: totalBytes ?? cur.totalBytes,
      line: line ?? cur.line,
      error: error,
    );
  }
}
