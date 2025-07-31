import 'package:package_info_plus/package_info_plus.dart';

class VersionUtil {
  static Future<String> getAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    return 'v${info.version}+${info.buildNumber}';
  }
}
