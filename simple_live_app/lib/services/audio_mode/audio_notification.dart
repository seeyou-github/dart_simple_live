import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_live_app/app/log.dart';

/// 音频模式的后台播放通知（仅 Android）
///
/// 原生侧是一个 `mediaPlayback` 类型的前台服务：常驻通知里显示
/// 直播间标题 / 主播 / 头像封面，并提供播放-暂停与关闭按钮。
/// iOS 通过 Info.plist 的 `UIBackgroundModes: audio` 保持后台播放，
/// 这里不做额外通知。
class AudioNotification {
  AudioNotification._();

  static const _channel = MethodChannel("simple_live/audio_notification");

  /// 通知栏点击播放 / 暂停时的回调
  static Future<void> Function()? onTogglePlay;

  static bool _permissionAsked = false;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// 提前申请通知权限（Android 13+），每个进程只弹一次
  Future<void> ensurePermission() async {
    if (!supported || _permissionAsked) {
      return;
    }
    _permissionAsked = true;
    try {
      if (!await Permission.notification.isGranted) {
        await Permission.notification.request();
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 注册通知栏按钮回调（App 启动时调用一次）
  static void init() {
    if (!supported) {
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == "togglePlay") {
        await onTogglePlay?.call();
      }
      return null;
    });
  }

  /// 进入音频模式：显示常驻通知并启动前台服务
  Future<void> show({
    required String title,
    required String artist,
    required String avatar,
    required bool playing,
  }) async {
    if (!supported) {
      return;
    }
    try {
      await _channel.invokeMethod("show", {
        "title": title,
        "artist": artist,
        "avatar": avatar,
        "playing": playing,
      });
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 同步播放 / 暂停状态
  Future<void> setPlaying(bool playing) async {
    if (!supported) {
      return;
    }
    try {
      await _channel.invokeMethod("setPlaying", {"playing": playing});
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 退出音频模式：结束前台服务并移除通知
  Future<void> hide() async {
    if (!supported) {
      return;
    }
    try {
      await _channel.invokeMethod("hide");
    } catch (e) {
      Log.logPrint(e);
    }
  }

  static final AudioNotification instance = AudioNotification._();
}
