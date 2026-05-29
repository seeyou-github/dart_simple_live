import 'package:simple_live_tv_app/models/version_model.dart';

class CommonRequest {
  Future<VersionModel> checkUpdate() async {
    throw UnsupportedError('Update check is disabled.');
  }
}
