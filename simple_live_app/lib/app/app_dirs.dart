import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppDirs {
  static Future<Directory> appDataDirectory() async {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final dir = Directory(p.join(exeDir, 'AppData'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    return getApplicationSupportDirectory();
  }

  static Future<Directory> appDataSubdirectory(String name) async {
    final baseDir = await appDataDirectory();
    final dir = Directory(p.join(baseDir.path, name));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
