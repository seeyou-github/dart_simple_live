import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:simple_live_app/app/log.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面端单例控制：第二次启动时唤醒并聚焦已存在的窗口。
///
/// 使用本机回环端口实现，不依赖额外插件：
/// - 先尝试连接端口，若对端回复约定字符串，说明已有实例在运行；
/// - 连接不上则自己监听该端口，等待后续启动的实例发来唤醒请求。
class SingleInstance {
  SingleInstance._();

  static final SingleInstance instance = SingleInstance._();

  static const int _port = 47821;
  static const String _magic = "LIVE_SHOW_WINDOW";
  static const String _ack = "LIVE_OK";

  ServerSocket? _server;

  /// 返回 true 表示已有实例在运行，当前进程应直接退出。
  Future<bool> ensureSingle() async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return false;
    }
    if (await _notifyRunning()) {
      return true;
    }
    await _listen();
    return false;
  }

  /// 尝试通知已运行的实例显示窗口
  Future<bool> _notifyRunning() async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.write(_magic);
      await socket.flush();
      var reply = await socket.first.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () => Uint8List(0),
      );
      return String.fromCharCodes(reply).contains(_ack);
    } catch (e) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _listen() async {
    try {
      _server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _port,
      );
      _server!.listen(
        (socket) {
          socket.listen(
            (data) {
              if (String.fromCharCodes(data).contains(_magic)) {
                socket.write(_ack);
                showAndFocusWindow();
              }
            },
            onError: (e) {},
            cancelOnError: true,
          );
        },
        onError: (e) {
          Log.logPrint(e);
        },
        cancelOnError: false,
      );
    } catch (e) {
      // 端口被其它程序占用时不影响正常使用，只是失去单例能力
      Log.logPrint(e);
    }
  }

  /// 显示并聚焦窗口（窗口被最小化或隐藏时也能拉起）
  Future<void> showAndFocusWindow() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      Log.logPrint(e);
    }
  }
}
