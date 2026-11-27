import 'dart:async';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/services/db_service.dart';

class FollowUserService extends BasePageController<FollowUser> {
  static FollowUserService get instance => Get.find<FollowUserService>();
  StreamSubscription<dynamic>? subscription;

  RxList<FollowUser> livingList = RxList<FollowUser>();
  Timer? updateTimer;

  /// 状态更新期间又收到刷新请求（同步、关注/取消关注等），
  /// 等当前一轮结束后再检查一次，避免并发更新互相覆盖
  bool _updateStatusPending = false;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      // 同步成功、关注/取消关注后：刷新关注列表并重新检测直播状态
      refreshData();
    });

    if (list.isEmpty) {
      refreshData();
    }
    initTimer();
    super.onInit();
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
          minutes:
              AppSettingsController.instance.autoUpdateFollowDuration.value,
        ),
        (timer) {
          Log.logPrint("Update Follow Timer");
          refreshData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  var updating = false.obs;
  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return [];
    }

    var followList = DBService.instance.getFollowList();
    if (followList.isEmpty) {
      // 列表为空：没有需要检查的条目；若上一轮检查仍在收尾，由它负责关闭 updating
      if (!updating.value) {
        updating.value = false;
      }
      return followList;
    }
    startUpdateStatus(followList);
    return followList;
  }

  void sortList() {
    list.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    updateLivingList();
  }

  void updateLivingList() {
    livingList.assignAll(list.where((x) => x.liveStatus.value == 2));
  }

  void startUpdateStatus(List<FollowUser> followList) async {
    if (updating.value) {
      // 正在检查时又收到新的刷新请求，等这一轮结束后再重新检查
      _updateStatusPending = true;
      return;
    }
    updating.value = true;
    var target = followList;
    do {
      _updateStatusPending = false;
      await _updateAllStatus(target);
      sortList();
      if (_updateStatusPending) {
        // 检查期间关注列表有变更（同步 / 关注 / 取消关注），读取最新列表再检查一轮
        target = DBService.instance.getFollowList();
        list.value = target;
        sortList();
      }
    } while (_updateStatusPending && target.isNotEmpty);
    updating.value = false;
  }

  Future<void> _updateAllStatus(List<FollowUser> followList) async {
    var threadCount =
        AppSettingsController.instance.updateFollowThreadCount.value;

    var tasks = <Future>[];
    for (var i = 0; i < threadCount; i++) {
      tasks.add(
        Future(() async {
          var start = i * followList.length ~/ threadCount;
          var end = (i + 1) * followList.length ~/ threadCount;

          // 确保 end 不超出列表长度
          if (end > followList.length) {
            end = followList.length;
          }
          var items = followList.sublist(start, end);
          for (var item in items) {
            await updateLiveStatus(item);
          }
        }),
      );
    }
    await Future.wait(tasks);
  }

  Future updateLiveStatus(FollowUser item) async {
    try {
      var site = Sites.allSites[item.siteId]!;
      item.liveStatus.value =
          (await site.liveSite.getLiveStatus(roomId: item.roomId)) ? 2 : 1;
    } catch (e) {
      Log.logPrint(e);
    }
  }

  void removeItem(FollowUser item, {bool refresh = true}) async {
    var result =
        await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    await DBService.instance.followBox.delete(item.id);
    if (refresh) {
      refreshData();
    } else {
      list.remove(item);
      livingList.remove(item);
    }
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    subscription?.cancel();

    super.onClose();
  }
}
