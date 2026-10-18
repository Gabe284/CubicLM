import 'package:flutter_test/flutter_test.dart';

import 'package:cubiclm/services/runtime/runtime_installer.dart';
import 'package:cubiclm/services/runtime/toolchain_catalog.dart';

void main() {
  group('ToolchainCatalog', () {
    test('stacks list core first and keeps Debian independent', () {
      final stacks = ToolchainCatalog.stacks();
      expect(stacks.length, 9);
      expect(stacks.first.id, ToolchainId.core);
      expect(stacks.first.needsCore, isFalse);
      expect(ToolchainCatalog.stackOf(ToolchainId.debian).needsCore, isFalse);
      for (final s in [
        ToolchainCatalog.stackOf(ToolchainId.node),
        ToolchainCatalog.stackOf(ToolchainId.python),
        ToolchainCatalog.stackOf(ToolchainId.android),
        ToolchainCatalog.stackOf(ToolchainId.cpp),
        ToolchainCatalog.stackOf(ToolchainId.php),
      ]) {
        expect(s.needsCore, isTrue);
        expect(s.bundles, isNotEmpty);
      }
      for (final id in [ToolchainId.core, ToolchainId.debian]) {
        final stack = ToolchainCatalog.stackOf(id);
        expect(stack.available, isFalse);
        expect(stack.unavailableReason, isNotNull);
        expect(stack.unavailableReason, isNotEmpty);
      }
    });

    test('bundleUrl joins base + file', () {
      final bundle = ToolchainCatalog.stackOf(ToolchainId.core).bundles.first;
      expect(
        ToolchainCatalog.bundleUrl('https://x.test/r/', bundle),
        'https://x.test/r/${bundle.fileName}',
      );
      expect(
        ToolchainCatalog.checksumUrl('https://x.test/r', bundle),
        endsWith('.sha256'),
      );
    });

    test('embedded checksum must be exactly 64 hexadecimal characters', () {
      expect(
        RuntimeBundle(
          fileName: 'rootfs.tar.gz',
          version: '1',
          sha256: List.filled(64, 'a').join(),
          title: 'rootfs',
        ).hasEmbeddedChecksum,
        isTrue,
      );
      expect(
        RuntimeBundle(
          fileName: 'rootfs.tar.gz',
          version: '1',
          sha256: List.filled(64, 'z').join(),
          title: 'rootfs',
        ).hasEmbeddedChecksum,
        isFalse,
      );
      expect(
        RuntimeBundle(
          fileName: 'rootfs.tar.gz',
          version: '1',
          sha256: '${List.filled(64, "a").join()}x',
          title: 'rootfs',
        ).hasEmbeddedChecksum,
        isFalse,
      );
    });

    test('safeJoin blocks escapes, allows normal entries', () {
      expect(ToolchainCatalog.safeJoin('/r', 'usr/bin/bash'),
          '/r/usr/bin/bash');
      expect(ToolchainCatalog.safeJoin('/r', './a/./b'), '/r/a/b');
      expect(ToolchainCatalog.safeJoin('/r', '../evil'), isNull);
      expect(ToolchainCatalog.safeJoin('/r', 'a/../../evil'), isNull);
      expect(ToolchainCatalog.safeJoin('/r', '/absolute'), '/r/absolute');
      expect(ToolchainCatalog.safeJoin('/r', ''), isNull);
      expect(ToolchainCatalog.safeJoin('/r', 'C:/win'), isNull);
    });

    test('formatBytes renders human sizes', () {
      expect(ToolchainCatalog.formatBytes(0), '0 B');
      expect(ToolchainCatalog.formatBytes(1536), '1.5 KB');
      expect(ToolchainCatalog.formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(ToolchainCatalog.formatBytes(-5), '—');
    });

    test('core extracts to root (ubuntu/ + bin/proot), overlays to rootfs',
        () {
      expect(RuntimeInstaller.extractSubdirFor(ToolchainId.core), '');
      expect(RuntimeInstaller.extractSubdirFor(ToolchainId.debian), '');
      for (final id in [
        ToolchainId.node,
        ToolchainId.python,
        ToolchainId.android,
        ToolchainId.cpp,
        ToolchainId.php,
      ]) {
        expect(RuntimeInstaller.extractSubdirFor(id), 'ubuntu');
      }
    });

    test('Node and Python overlays are Ubuntu-only', () {
      expect(
        ToolchainCatalog.supportsOverlay(
            ToolchainId.node, RuntimeEnvironment.ubuntu),
        isTrue,
      );
      expect(
        ToolchainCatalog.supportsOverlay(
            ToolchainId.node, RuntimeEnvironment.debian),
        isFalse,
      );
      expect(
        ToolchainCatalog.supportsOverlay(
            ToolchainId.python, RuntimeEnvironment.debian),
        isFalse,
      );
    });

    test('splitTarMember separates symlink targets', () {
      expect(ToolchainCatalog.splitTarMember('ubuntu/a/b').path,
          'ubuntu/a/b');
      expect(ToolchainCatalog.splitTarMember('ubuntu/a/b').target, isNull);
      final link = ToolchainCatalog.splitTarMember(
          'ubuntu/a/b -> ../../c/d');
      expect(link.path, 'ubuntu/a/b');
      expect(link.target, '../../c/d');
    });

    test('resolveInside pops in-root dotdots, rejects escapes', () {
      expect(ToolchainCatalog.resolveInside('/r', 'a/b'), '/r/a/b');
      expect(ToolchainCatalog.resolveInside('/r', 'a/./b'), '/r/a/b');
      expect(ToolchainCatalog.resolveInside('/r', 'a/x/../b'), '/r/a/b');
      expect(ToolchainCatalog.resolveInside('/r', '../evil'), isNull);
      expect(ToolchainCatalog.resolveInside('/r', 'a/../../evil'), isNull);
      // Leading slashes map inside (same as safeJoin; absolute symlink
      // targets resolve against the guest root at runtime).
      expect(ToolchainCatalog.resolveInside('/r', '/absolute'),
          '/r/absolute');
      expect(ToolchainCatalog.resolveInside('/r', 'C:/win'), isNull);
      expect(ToolchainCatalog.resolveInside('/r', ''), isNull);
    });

    test('unsafeMemberReason allows the real Ubuntu fstab link', () {
      // Exact device failure (Redmi, core install): legit in-root link.
      expect(
          ToolchainCatalog.unsafeMemberReason('/r',
              'ubuntu/usr/share/doc/mount/examples/fstab -> ../../util-linux/examples/fstab'),
          isNull);
      // Distro absolute links resolve inside the guest.
      expect(
          ToolchainCatalog.unsafeMemberReason(
              '/r', 'ubuntu/etc/alternatives/awk -> /usr/bin/mawk'),
          isNull);
      expect(
          ToolchainCatalog.unsafeMemberReason(
              '/r', 'ubuntu/etc/os-release -> ../usr/lib/os-release'),
          isNull);
      // True escapes still blocked.
      expect(
          ToolchainCatalog.unsafeMemberReason('/r', '../evil'),
          isNotNull);
      expect(
          ToolchainCatalog.unsafeMemberReason(
              '/r', 'ubuntu/x -> ../../../etc/passwd'),
          isNotNull);
      expect(
          ToolchainCatalog.unsafeMemberReason('/r', 'ubuntu/../../evil'),
          isNotNull);
      // …but in-root dotdots are fine (lexical containment is enough).
      expect(
          ToolchainCatalog.unsafeMemberReason(
              '/r', 'ubuntu/a/../../evil'),
          isNull);
    });
  });
}
