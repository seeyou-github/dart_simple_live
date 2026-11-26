import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

/// 设置聚合页：把所有设置项收进一个入口，避免"我的"页面过长。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("设置"),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          SettingsCard(
            child: Column(
              children: [
                _buildItem(
                  Remix.moon_line,
                  "外观设置",
                  RoutePath.kAppstyleSetting,
                ),
                AppStyle.divider,
                _buildItem(
                  Remix.home_2_line,
                  "主页设置",
                  RoutePath.kSettingsIndexed,
                ),
                AppStyle.divider,
                _buildItem(
                  Remix.play_circle_line,
                  "直播设置",
                  RoutePath.kSettingsPlay,
                ),
                AppStyle.divider,
                _buildItem(
                  Remix.text,
                  "弹幕设置",
                  RoutePath.kSettingsDanmu,
                ),
                AppStyle.divider,
                _buildItem(
                  Remix.heart_line,
                  "关注设置",
                  RoutePath.kSettingsFollow,
                ),
                AppStyle.divider,
                _buildItem(
                  Remix.apps_line,
                  "其他设置",
                  RoutePath.kSettingsOther,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(IconData icon, String title, String route) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: () {
        Get.toNamed(route);
      },
    );
  }
}
