import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/signalr_service.dart';

class MinePage extends StatelessWidget {
  const MinePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Get.isDarkMode
          ? SystemUiOverlayStyle.light.copyWith(
              systemNavigationBarColor: Colors.transparent,
            )
          : SystemUiOverlayStyle.dark.copyWith(
              systemNavigationBarColor: Colors.transparent,
            ),
      child: SafeArea(
        child: ListView(
          padding: AppStyle.edgeInsetsA4,
          children: [
            AppStyle.vGap12,
            ListTile(
              leading: Image.asset(
                'assets/images/logo.png',
                width: 56,
                height: 56,
              ),
              title: const Text("Live", style: TextStyle(height: 1.0)),
              subtitle: const Text("简简单单看直播"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.dialog(
                  AboutDialog(
                    applicationIcon: Image.asset(
                      'assets/images/logo.png',
                      width: 48,
                      height: 48,
                    ),
                    applicationName: "Live",
                    applicationVersion: "简简单单看直播",
                    applicationLegalese: "Ver ${Utils.packageInfo.version}",
                  ),
                );
              },
            ),
            Divider(
              indent: 12,
              endIndent: 12,
              color: Colors.grey.withAlpha(25),
            ),
            _buildCard(
              context,
              children: [
                _buildMenuItem(
                  Remix.settings_3_line,
                  "设置",
                  RoutePath.kSettings,
                ),
                AppStyle.divider,
                _buildMenuItem(
                  Icons.devices,
                  "备份同步",
                  RoutePath.kSync,
                ),
                AppStyle.divider,
                _buildMenuItem(
                  Remix.account_circle_line,
                  "账号管理",
                  RoutePath.kSettingsAccount,
                ),
                AppStyle.divider,
                _buildMenuItem(
                  Remix.link,
                  "链接解析",
                  RoutePath.kTools,
                ),
                AppStyle.divider,
                _buildMenuItem(
                  Remix.timer_2_line,
                  "定时关闭",
                  RoutePath.kSettingsAutoExit,
                ),
                AppStyle.divider,
                _buildMenuItem(
                  Remix.history_line,
                  "观看记录",
                  RoutePath.kHistory,
                ),
                if (kDebugMode) ...[
                  AppStyle.divider,
                  ListTile(
                    leading: const Icon(Remix.code_line),
                    title: const Text("测试"),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.grey,
                    ),
                    onTap: () async {
                      SignalRService signalRService = SignalRService();
                      await signalRService.connect();
                      //Get.toNamed(RoutePath.kTest);
                      var room = await signalRService.createRoom();
                      Log.logPrint(room);
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem(IconData icon, String title, String route) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: () {
        Get.toNamed(route);
      },
    );
  }

  Widget _buildCard(BuildContext context, {required List<Widget> children}) {
    return Theme(
      data: Theme.of(context).copyWith(
        listTileTheme: ListTileThemeData(
          shape: RoundedRectangleBorder(borderRadius: AppStyle.radius8),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
