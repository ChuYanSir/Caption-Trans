import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves the directories where the app keeps its own generated files.
///
/// The preferred root lives next to the executable (`runtime/`), so the Python
/// runtime, its virtualenv, the downloaded models and temporary audio can all
/// be removed together with the application folder.
///
/// When the installation directory is not writable - for example a machine
/// wide install the current user cannot modify - the app falls back to the
/// per-user application support directory, which is also where older builds
/// kept their runtimes.
class AppPaths {
  AppPaths._();

  /// Folder name used inside the application directory.
  static const String runtimeDirName = 'runtime';

  static Directory? _cachedRoot;

  /// Root directory for every app-managed file.
  static Future<Directory> root() async {
    final Directory? cached = _cachedRoot;
    if (cached != null) {
      return cached;
    }

    final Directory applicationDir =
        Directory(p.dirname(Platform.resolvedExecutable));
    final Directory bundledRoot = Directory(
      p.join(applicationDir.path, runtimeDirName),
    );

    if (await _ensureWritable(bundledRoot)) {
      _cachedRoot = bundledRoot;
      return bundledRoot;
    }

    final Directory supportDir = await getApplicationSupportDirectory();
    await supportDir.create(recursive: true);
    _cachedRoot = supportDir;
    return supportDir;
  }

  /// Directory for temporary working files such as extracted audio.
  static Future<Directory> temp() async {
    final Directory dir = Directory(p.join((await root()).path, 'temp'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<bool> _ensureWritable(Directory dir) async {
    try {
      await dir.create(recursive: true);
      final File probe = File(p.join(dir.path, '.write_probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
