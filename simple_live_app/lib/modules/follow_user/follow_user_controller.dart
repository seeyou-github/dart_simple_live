// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  @override
  void onInit() {
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream =
        FollowService.instance.updatedListStream.listen((event) {
      filterData();
    });
    super.onInit();
  }

  @override
  Future refreshData() async {
    await FollowService.instance.loadData();
    super.refreshData();
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return Future.value([]);
    }
    // 不分类，默认显示所有关注主播，直播中的置顶。
    return _sortedAllFollowList();
  }

  /// 所有关注主播，按直播状态排序（直播中在前）。
  List<FollowUser> _sortedAllFollowList() {
    var result = List<FollowUser>.from(FollowService.instance.followList);
    result.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    return result;
  }

  void filterData() {
    list.assignAll(_sortedAllFollowList());
  }

  void removeItem(FollowUser item) async {
    var result =
        await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    await DBService.instance.followBox.delete(item.id);
    // 走统一刷新链路，立即更新关注页（不受下拉刷新冷却限制）
    EventBus.instance.emit(Constant.kUpdateFollow, item.id);
  }

  Future<void> updateItem(FollowUser item) async {
    await FollowService.instance.addFollow(item);
    EventBus.instance.emit(Constant.kUpdateFollow, item.id);
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    onUpdatedListStream?.cancel();
    super.onClose();
  }
}
