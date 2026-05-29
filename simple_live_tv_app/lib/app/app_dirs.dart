import 'dart:io';

class AppDirs {
  static Future<Directory> appDataDirectory() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final dir = Directory('$exeDir${Platform.pathSeparator}AppData');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
