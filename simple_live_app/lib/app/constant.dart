import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';

class Constant {
  static const String kUpdateFollow = "UpdateFollow";
  static const String kUpdateHistory = "UpdateHistory";

  /// 主页分类栏固定分类发生变化（备份恢复 / 设备同步）
  static const String kUpdatePinnedCategories = "UpdatePinnedCategories";

  static final Map<String, HomePageItem> allHomePages = {
    "recommend": HomePageItem(
      iconData: Remix.home_smile_line,
      title: "首页",
      index: 0,
    ),
    "follow": HomePageItem(
      iconData: Remix.heart_line,
      title: "关注",
      index: 1,
    ),
    "user": HomePageItem(
      iconData: Remix.user_smile_line,
      title: "我的",
      index: 2,
    ),
  };

  static const String kBiliBili = "bilibili";
  static const String kDouyu = "douyu";
  static const String kHuya = "huya";
  static const String kDouyin = "douyin";
}

class HomePageItem {
  final IconData iconData;
  final String title;
  final int index;
  HomePageItem({
    required this.iconData,
    required this.title,
    required this.index,
  });
}
