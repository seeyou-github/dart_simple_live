import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/audio_mode/audio_notification.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

/// 聊天列表条目：普通聊天 / 系统消息，或 SC 醒目留言卡片
class ChatListItem {
  ChatListItem.chat(this.message) : superChat = null;

  ChatListItem.superChat(this.superChat) : message = null;

  final LiveMessage? message;
  final LiveSuperChatMessage? superChat;
}

class LiveRoomController extends PlayerController
    with WidgetsBindingObserver, WindowListener {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息（普通聊天 / 系统消息 / SC 醒目留言卡片）
  RxList<ChatListItem> messages = RxList<ChatListItem>();

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间活动是否已挂起（音频模式 / 后台：弹幕连接断开、计时暂停）
  bool _roomActivitySuspended = false;

  /// 桌面端后台窗口状态监控定时器：每秒核对窗口真实状态，
  /// 保证后台处于音频模式、回前台立即退出（防误派发事件撤销状态后无法恢复）
  Timer? _autoAudioModeMonitor;

  /// 用户在后台手动退出音频模式后暂不自动重新进入，回前台后解除
  bool _suppressAutoAudioMode = false;

  /// 最近显示过的弹幕内容（用于过滤重复弹幕，最多保留 100 条）
  final Queue<String> _recentDanmakuTexts = Queue<String>();

  /// 表情字符（含修饰符、变体选择符、零宽连接符、键帽符）
  static final RegExp _emojiCharRegExp = RegExp(
    r'[\u{1F000}-\u{1FFFF}\u{2190}-\u{21FF}\u{2300}-\u{23FF}'
    r'\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{20E3}]',
    unicode: true,
  );

  /// [xx] 风格表情标签（如 [捂脸]）
  static final RegExp _emoteTagRegExp = RegExp(r"\[[^\[\]]{1,10}\]");

  /// 纯数字内容（仅数字与空白）
  static final RegExp _pureNumberRegExp = RegExp(r"^[\d\s]+$");

  /// 直播间加载失败
  var loadError = false.obs;
  Error? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    // 桌面端：最小化 / 失去焦点时进入音频模式，恢复时退出
    if (!Platform.isAndroid && !Platform.isIOS) {
      windowManager.addListener(this);
    } else {
      // 提前要通知权限，进入后台切音频模式时才能显示常驻通知
      AudioNotification.instance.ensurePermission();
    }
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    // 播放器底栏的弹幕开关是会话级临时开关，不写入设置；
    // 设置页修改「默认开关」后仍同步到当前播放页
    ever(AppSettingsController.instance.danmuEnable, (bool value) {
      showDanmakuState.value = value;
    });
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    // 音频模式 / 后台时弹幕连接已停止，这里兜底忽略残留消息，避免更新 UI
    if (audioMode.value || isBackground) {
      return;
    }
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }

      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      // 过滤表情：删除文字中的表情与 [微笑] 类表情标签，仅保留文字
      var displayMsg = msg;
      if (AppSettingsController.instance.danmuStripEmoji.value) {
        var text = _stripEmojiText(msg.message);
        if (text.isEmpty) {
          // 整条都是表情，删完后没有文字可显示
          return;
        }
        if (text != msg.message) {
          displayMsg = LiveMessage(
            type: msg.type,
            userName: msg.userName,
            message: text,
            data: msg.data,
            color: msg.color,
          );
        }
      }

      // 过滤规则：重复弹幕 / 纯表情弹幕 / 纯数字弹幕（基于显示文本）
      if (_isFilteredByRules(displayMsg.message)) {
        return;
      }
      // 记录最近显示的弹幕内容，用于重复弹幕过滤
      _recordRecentDanmaku(displayMsg.message);

      messages.add(ChatListItem.chat(displayMsg));

      if (!isBackground && !audioMode.value) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => chatScrollToBottom(),
        );
      }
      // 音频模式 / 后台时不再往弹幕画布加内容
      if (!liveStatus.value || isBackground || audioMode.value) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          displayMsg.message,
          color: Color.fromARGB(
            255,
            displayMsg.color.r,
            displayMsg.color.g,
            displayMsg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      // SC 醒目留言作为卡片插入聊天流，跟随聊天滚动
      messages.add(ChatListItem.superChat(msg.data as LiveSuperChatMessage));
    }
  }

  /// 过滤规则：重复弹幕 / 纯表情弹幕 / 纯数字弹幕
  ///（开关在「关键词屏蔽」弹框中，默认开启；同时作用于弹幕与聊天区）
  bool _isFilteredByRules(String message) {
    var settings = AppSettingsController.instance;
    var text = message.trim();
    // 重复弹幕：与最近显示的 100 条对比；
    // 接受后立即记录，同一批弹幕内的重复也会被过滤
    if (settings.danmuFilterRepeat.value &&
        _recentDanmakuTexts.contains(text)) {
      return true;
    }
    if (settings.danmuFilterEmoji.value && _isPureEmoji(text)) {
      return true;
    }
    if (settings.danmuFilterNumber.value && _isPureNumber(text)) {
      return true;
    }
    return false;
  }

  /// 是否为纯表情弹幕：仅由 Unicode 表情字符或 [xx] 表情标签构成
  ///（允许空白与表情修饰符；纯数字标签如 [666] 不按表情处理）
  bool _isPureEmoji(String text) {
    if (text.isEmpty) {
      return false;
    }
    var hasEmoji = _emojiCharRegExp.hasMatch(text);
    var remainder = text.replaceAllMapped(_emoteTagRegExp, (match) {
      var inner = match.group(0)!;
      inner = inner.substring(1, inner.length - 1).trim();
      if (inner.isEmpty || int.tryParse(inner) != null) {
        // 非表情标签，保留内容参与后续判断
        return inner;
      }
      hasEmoji = true;
      return "";
    });
    remainder = remainder.replaceAll(_emojiCharRegExp, "");
    return hasEmoji && remainder.trim().isEmpty;
  }

  /// 删除文字中的表情：Unicode 表情字符与 [xx] 表情标签全部移除，
  /// 仅保留文字（纯数字标签如 [666] 不按表情处理）
  String _stripEmojiText(String text) {
    var remainder = text.replaceAllMapped(_emoteTagRegExp, (match) {
      var inner = match.group(0)!;
      inner = inner.substring(1, inner.length - 1).trim();
      if (inner.isEmpty || int.tryParse(inner) != null) {
        return inner;
      }
      return "";
    });
    remainder = remainder.replaceAll(_emojiCharRegExp, "");
    return remainder.trim();
  }

  /// 是否为纯数字弹幕：仅由数字与空白构成（至少含一个数字）
  bool _isPureNumber(String text) {
    return text.isNotEmpty && _pureNumberRegExp.hasMatch(text);
  }

  /// 记录最近显示的弹幕内容（最多 100 条），用于重复弹幕过滤
  void _recordRecentDanmaku(String message) {
    _recentDanmakuTexts.addLast(message.trim());
    while (_recentDanmakuTexts.length > 100) {
      _recentDanmakuTexts.removeFirst();
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      ChatListItem.chat(
        LiveMessage(
          type: LiveMessageType.chat,
          userName: "LiveSysMessage",
          message: msg,
          color: LiveMessageColor.white,
        ),
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  /// 按前后台 / 音频模式状态挂起或恢复直播间活动
  ///
  /// 音频模式或后台时：断开弹幕连接（聊天 / 弹幕 / 人气值全部停止加载）、
  /// 暂停开播时长计时，仅保留播放器的音频输出，把 CPU / GPU 占用降到最低；
  /// 回到前台后重新连接弹幕服务器、恢复计时。
  void applyRoomActivityState() {
    if (audioMode.value || isBackground) {
      liveDanmaku.stop();
      _liveDurationTimer?.cancel();
      _roomActivitySuspended = true;
    } else if (_roomActivitySuspended) {
      _roomActivitySuspended = false;
      if (detail.value != null) {
        initDanmau();
        liveDanmaku.start(detail.value?.danmakuData);
      }
      startLiveDurationTimer();
    }
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
      startLiveDurationTimer(); // 启动开播时长定时器
      // 若此时已处于音频模式 / 后台（如后台切换直播间），立即挂起
      applyRoomActivityState();
    } catch (e) {
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e as Error;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  void getPlayUrl() async {
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    playUrls.value = playUrl.urls;
    playHeaders = playUrl.headers;
    currentLineIndex = 0;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    //重置错误次数
    mediaErrorRetryCount = 0;
    initPlaylist();
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  void initPlaylist() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    final mediaList = playUrls.map((url) {
      var finalUrl = url;
      if (AppSettingsController.instance.playerForceHttps.value) {
        finalUrl = finalUrl.replaceAll("http://", "https://");
      }
      return Media(finalUrl, httpHeaders: playHeaders);
    }).toList();

    // 初始化播放器并设置 ao 参数
    await initializePlayer();

    await player.open(Playlist(mediaList));
    // 音频模式下保持关闭视频解码（换线路 / 刷新会重新打开解码器）
    if (audioMode.value) {
      await setVideoTrackEnabled(false);
    }
  }

  void setPlayer() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    await player.jump(currentLineIndex);
    // 切换线路会重新打开解码器，音频模式下需要再次关闭视频解码
    if (audioMode.value) {
      await setVideoTrackEnabled(false);
    }
  }

  @override
  void mediaEnd() async {
    super.mediaEnd();
    if (mediaErrorRetryCount < 2) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    Log.d("播放结束");
    // 遍历线路，如果全部链接都断开就是直播结束了
    if (playUrls.length - 1 == currentLineIndex) {
      liveStatus.value = false;
    } else {
      changePlayLine(currentLineIndex + 1);

      //setPlayer();
    }
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    super.mediaEnd();
    if (mediaErrorRetryCount < 2) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
    } else {
      //currentLineIndex += 1;
      //setPlayer();
      changePlayLine(currentLineIndex + 1);
    }
  }

  /// 读取SC，作为卡片插入聊天流
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      messages.addAll(sc.map((e) => ChatListItem.superChat(e)));
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  Future<void> followUser() async {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    await DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    await DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    if (qualites.isEmpty) {
      SmartDialog.showToast("暂无可用分辨率");
      return;
    }
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text("过滤规则", style: Get.textTheme.titleSmall),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsSwitch(
                    title: "过滤重复弹幕",
                    subtitle: "与最近显示的 100 条弹幕对比，去除重复内容",
                    value:
                        AppSettingsController.instance.danmuFilterRepeat.value,
                    onChanged: (e) {
                      AppSettingsController.instance.setDanmuFilterRepeat(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "过滤纯表情弹幕",
                    subtitle: "只含表情符号或[表情]标签的弹幕不再显示",
                    value:
                        AppSettingsController.instance.danmuFilterEmoji.value,
                    onChanged: (e) {
                      AppSettingsController.instance.setDanmuFilterEmoji(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "过滤纯数字弹幕",
                    subtitle: "只含数字的弹幕（如 666、233）不再显示",
                    value:
                        AppSettingsController.instance.danmuFilterNumber.value,
                    onChanged: (e) {
                      AppSettingsController.instance.setDanmuFilterNumber(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "过滤表情",
                    subtitle:
                        "删除弹幕与聊天文字中的表情（含 [微笑] 标签），仅显示文字",
                    value:
                        AppSettingsController.instance.danmuStripEmoji.value,
                    onChanged: (e) {
                      AppSettingsController.instance.setDanmuStripEmoji(e);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    danmakuController?.clear();
    // 换房间后重复弹幕对比不跨房间
    _recentDanmakuTexts.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${error?.stackTrace}''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // 桌面端「失焦但仍可见」通常只上报 inactive，必须一并当作后台处理
    final desktop = !Platform.isAndroid && !Platform.isIOS;
    final enteredBackground = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        (desktop && state == AppLifecycleState.inactive);
    if (enteredBackground) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
      if (Platform.isAndroid || Platform.isIOS) {
        // 移动端进入后台：直接切音频模式，由前台服务保活并显示通知。
        // 用户显式设置了「后台暂停」时保持暂停，不自动切音频模式。
        if (!AppSettingsController.instance.playerAutoPause.value) {
          enterAudioMode();
        }
      } else {
        // 桌面端：最小化 / 失焦立即进入音频模式
        scheduleAutoAudioMode();
      }
      // 挂起弹幕连接与开播时长计时（含「后台暂停」不进音频模式的情况）
      applyRoomActivityState();
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      if (Platform.isAndroid || Platform.isIOS) {
        isBackground = false;
        if (audioMode.value && !audioModeManual) {
          exitAudioMode();
        }
        applyRoomActivityState();
      } else {
        // 桌面端：核对窗口真实状态后再恢复（最小化 / 失焦可能伴随误事件）
        _confirmWindowForeground();
      }
    }
  }

  /// 音频模式的通知栏信息：头像作封面，标题为直播间标题，副标题为主播名
  @override
  ({String id, String title, String artist, String avatar})?
      get audioNotificationInfo {
    var info = detail.value;
    if (info == null) {
      return null;
    }
    return (
      id: "${site.id}_${info.roomId}",
      title: info.title.trim().isEmpty ? "直播音频" : info.title,
      artist: info.userName.trim().isEmpty ? site.name : info.userName,
      avatar: info.userAvatar,
    );
  }

  /// 进入音频模式时同步挂起直播间活动（弹幕 / 聊天 / 计时）
  @override
  Future<void> enterAudioMode({bool manual = false}) async {
    await super.enterAudioMode(manual: manual);
    applyRoomActivityState();
  }

  /// 退出音频模式时同步恢复直播间活动
  @override
  Future<void> exitAudioMode({bool manual = false}) async {
    await super.exitAudioMode(manual: manual);
    if (manual) {
      // 用户在后台手动退出音频模式，监控不再自动重新进入，回前台后解除
      _suppressAutoAudioMode = true;
    }
    applyRoomActivityState();
  }

  /// 桌面端：最小化 / 失焦后立即进入音频模式，并启动后台监控自愈
  ///
  /// 最小化 / 失焦时系统可能紧接着派发误的 focus / restore 事件，
  /// 单次进入可能被核对逻辑误撤销且没有后续事件补救，
  /// 因此除立即进入外，再由每秒一次的后台监控兜底：
  /// 后台保持音频模式（自愈重新进入），回前台立即退出。
  void scheduleAutoAudioMode() {
    if (Platform.isAndroid || Platform.isIOS) {
      return;
    }
    // 「进入后台自动暂停」开启时不进入音频模式，也无需后台监控
    if (AppSettingsController.instance.playerAutoPause.value) {
      return;
    }
    // 小窗常驻桌面播放，失焦后仍需显示画面
    if (smallWindowState.value) {
      return;
    }
    // 新的后台事件解除「后台手动退出」的抑制
    _suppressAutoAudioMode = false;
    _startAutoAudioModeMonitor();
    if (audioMode.value || audioModeManual) {
      return;
    }
    Log.d("桌面端最小化/失焦，立即进入音频模式");
    enterAudioMode();
  }

  void _startAutoAudioModeMonitor() {
    _autoAudioModeMonitor ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _verifyAutoAudioMode();
    });
  }

  void _stopAutoAudioModeMonitor() {
    _autoAudioModeMonitor?.cancel();
    _autoAudioModeMonitor = null;
  }

  /// 每秒核对窗口真实状态：后台自愈保持音频模式，回前台立即退出
  Future<void> _verifyAutoAudioMode() async {
    try {
      var minimized = await windowManager.isMinimized();
      var focused = await windowManager.isFocused();
      if (!minimized && focused) {
        // 窗口已回到前台：停止监控并退出自动音频模式
        _stopAutoAudioModeMonitor();
        _suppressAutoAudioMode = false;
        isBackground = false;
        if (audioMode.value && !audioModeManual) {
          await exitAudioMode();
        }
        applyRoomActivityState();
        return;
      }
      // 仍在后台：自愈，确保音频模式与直播间挂起状态有效
      isBackground = true;
      if (!_suppressAutoAudioMode && !audioModeManual && !audioMode.value) {
        Log.d("桌面端后台监控：重新进入音频模式");
        await enterAudioMode();
      }
      applyRoomActivityState();
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 桌面端：窗口焦点 / 还原变化后核对真实状态并同步前后台
  ///
  /// 最小化 / 失焦时系统可能紧接着派发 focus / restore 事件，
  /// 不能直接按事件恢复前台，否则刚进入的音频模式会被误撤销；
  /// 核对窗口确实回到前台后，才恢复直播间活动并退出自动音频模式。
  Future<void> _confirmWindowForeground() async {
    try {
      var minimized = await windowManager.isMinimized();
      var focused = await windowManager.isFocused();
      if (minimized || !focused) {
        // 仍在后台：交给后台监控保持音频模式（不解除手动退出的抑制）
        isBackground = true;
        _startAutoAudioModeMonitor();
        applyRoomActivityState();
        return;
      }
      // 真正回到前台：停止监控并退出自动音频模式
      _stopAutoAudioModeMonitor();
      _suppressAutoAudioMode = false;
      isBackground = false;
      if (audioMode.value && !audioModeManual) {
        await exitAudioMode();
      }
      applyRoomActivityState();
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 桌面端：最小化
  @override
  void onWindowMinimize() {
    isBackground = true;
    applyRoomActivityState();
    scheduleAutoAudioMode();
  }

  /// 桌面端：从最小化还原
  @override
  void onWindowRestore() {
    _confirmWindowForeground();
  }

  /// 桌面端：窗口失去焦点
  @override
  void onWindowBlur() {
    isBackground = true;
    applyRoomActivityState();
    scheduleAutoAudioMode();
  }

  /// 桌面端：窗口重新获得焦点
  @override
  void onWindowFocus() {
    _confirmWindowForeground();
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!Platform.isAndroid && !Platform.isIOS) {
      windowManager.removeListener(this);
    }
    _stopAutoAudioModeMonitor();
    // 离开直播间时清掉通知栏，避免残留一个无法关闭的音频通知
    stopAudioNotification();
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    super.onClose();
  }
}
