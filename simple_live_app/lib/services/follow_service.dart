import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/db_service.dart';

class FollowService extends GetxService {
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 是否正在更新
  var updating = false.obs;

  /// 状态更新期间又收到刷新请求（同步成功、关注/取消关注等），
  /// 等当前一轮结束后再检查一次，避免并发更新互相覆盖
  bool _updateStatusPending = false;

  Timer? updateTimer;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      // 同步成功、关注/取消关注后：立即刷新关注页，并重新检测直播状态
      loadData();
    });
    initTimer();
    super.onInit();
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
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
          loadData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  Future<void> loadData() async {
    var list = DBService.instance.getFollowList();
    followList.assignAll(list);
    if (list.isEmpty) {
      _updateStatusPending = false;
      // 列表清空也要立即通知关注页，避免残留旧数据；
      // 若上一轮状态检查仍在收尾，由它负责关闭 updating
      filterData();
      return;
    }
    // 立即通知关注页刷新，让同步 / 关注变更马上可见
    // （新关注先显示“读取中”），状态检查完成后再统一排序刷新
    filterData();
    startUpdateStatus();
  }

  /// 获取最优并发数
  /// 根据 CPU 核心数和用户设置自动计算
  int getOptimalConcurrency() {
    var userSetting =
        AppSettingsController.instance.updateFollowThreadCount.value;

    // 如果用户设置为 0，则自动根据 CPU 核心数计算
    if (userSetting == 0) {
      var cpuCount = Platform.numberOfProcessors;
      // 网络 I/O 密集型任务，并发数可以是 CPU 核心数的 2-3 倍
      var optimal = (cpuCount * 2.5).round();
      // 限制在合理范围内（最少 4，最多 20）
      return optimal.clamp(4, 20);
    }

    return userSetting;
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> interleaveByPlatform(List<FollowUser> list) {
    // 按平台分组
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    // 交错处理
    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  void startUpdateStatus() async {
    if (updating.value) {
      // 正在检查时又收到新的刷新请求，等这一轮结束后再重新检查
      _updateStatusPending = true;
      return;
    }
    updating.value = true;
    do {
      _updateStatusPending = false;
      await _updateAllStatus();
      // 检查期间 followList 可能已被新的同步 / 关注变更替换，这里按最新列表排序
      filterData();
    } while (_updateStatusPending && followList.isNotEmpty);
    Log.logPrint("关注状态更新完成");
    updating.value = false;
  }

  Future<void> _updateAllStatus() async {
    var concurrency = getOptimalConcurrency();

    Log.logPrint("开始更新关注状态，并发数: $concurrency，总数: ${followList.length}");

    // 按平台交错排列，避免单一平台阻塞
    var interleavedList = interleaveByPlatform(followList);

    // 创建任务队列
    var taskQueue = Queue<FollowUser>.from(interleavedList);

    // 工作函数 - 持续从队列中取任务执行
    Future<void> worker(int workerId) async {
      while (taskQueue.isNotEmpty) {
        var item = taskQueue.removeFirst();
        await updateLiveStatus(item);
      }
    }

    // 启动固定数量的并发 worker
    var workers = <Future>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(worker(i));
    }

    await Future.wait(workers);
  }

  Future updateLiveStatus(FollowUser item) async {
    try {
      var site = Sites.allSites[item.siteId]!;
      // 先只查状态
      var isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
      item.liveStatus.value = isLiving ? 2 : 1;
      if (item.liveStatus.value == 2) {
        // 只有正在直播时才查详细信息
        var detail = await site.liveSite.getRoomDetail(roomId: item.roomId);
        item.liveStartTime = detail.showTime;
      } else {
        item.liveStartTime = null;
      }
    } catch (e) {
      Log.logPrint(e);
      item.liveStatus.value = 0;
      item.liveStartTime = null;
    }
  }

  void filterData() {
    followList.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    notLiveList.assignAll(followList.where((x) => x.liveStatus.value == 1));
    _updatedListController.add(0);
  }

  /// 导出关注列表：弹出系统「另存为」对话框，由用户选择保存位置
  ///
  /// Android / iOS 走 SAF，保存时需要直接带上文件内容；桌面端拿到路径后自行写入。
  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }

    try {
      var bytes = Uint8List.fromList(utf8.encode(generateJson()));
      var fileName =
          "SimpleLive_follow_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json";
      var inlineSave = Platform.isAndroid || Platform.isIOS;
      var path = await FilePicker.platform.saveFile(
        dialogTitle: "保存关注列表",
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ["json"],
        bytes: inlineSave ? bytes : null,
      );
      if (path == null) {
        return;
      }
      if (!inlineSave) {
        await File(path).writeAsBytes(bytes);
      }
      SmartDialog.showToast("已导出关注列表");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }
      var file = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败:$e");
    } finally {
      loadData();
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: const Text("导出为文本"),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: const Text("复制"),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: const Text("从文本导入"),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: "请输入内容",
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: const Text("粘贴"),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("内容为空");
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功");
                Get.back();
                loadData();
              } catch (e) {
                SmartDialog.showToast("导入失败，请检查内容是否正确");
              }
            },
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    var data = followList
        .map(
          (item) => {
            "siteId": item.siteId,
            "id": item.id,
            "roomId": item.roomId,
            "userName": item.userName,
            "face": item.face,
            "addTime": item.addTime.toString(),
          },
        )
        .toList();
    return jsonEncode(data);
  }

  Future inputJson(String content) async {
    var data = jsonDecode(content);

    for (var item in data) {
      var follow = FollowUser.fromJson(item);
      await DBService.instance.addFollow(follow);
    }
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    subscription?.cancel();
    super.onClose();
  }
}
