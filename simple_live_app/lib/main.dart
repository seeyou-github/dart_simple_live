import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/single_instance.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/listen_fourth_button.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/other/debug_log_page.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/audio_mode/audio_notification.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/webdav/backup_sync.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:window_manager/window_manager.dart';

import 'package:path/path.dart' as p;
import 'package:dynamic_color/dynamic_color.dart';
import 'package:simple_live_app/app/app_dirs.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端单例：Windows 由原生 runner 的命名互斥体处理，
  // macOS / Linux 走这里的端口探测；若已有实例则唤醒其窗口并退出
  if (await SingleInstance.instance.ensureSingle()) {
    // exit 返回 Never，这里不需要也无法再 return
    exit(0);
  }
  // 只做窗口相关的最小初始化（纯 dart:io + 窗口通道），
  // 数据目录、窗口尺寸都不经过 Hive，尽快把启动页显示出来。
  await initWindow();
  var appDir = await AppDirs.appDataDirectory();
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    //注册窗口大小监听并恢复上次手动调整的尺寸（此时窗口仍隐藏）
    windowManager.addListener(_windowSizeListener);
    await restoreWindowSize(appDir);
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  //设置状态栏为透明
  SystemUiOverlayStyle systemUiOverlayStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
  );
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
  // 先渲染启动页，首帧上屏后再显示窗口；Hive/数据库等服务在启动页期间初始化
  runApp(AppBootstrap(appDir: appDir));
  unawaited(showWindowAfterFirstFrame());
}

/// 将Hive数据迁移到Application Support
Future migrateData() async {
  if (Platform.isAndroid || Platform.isIOS || Platform.isWindows) {
    return;
  }
  var hiveFileList = [
    "followuser",
    //旧版本写错成hostiry了
    "hostiry",
    "followusertag",
    "localstorage",
    "danmushield",
  ];
  try {
    var newDir = await AppDirs.appDataDirectory();
    var hiveFile = File(p.join(newDir.path, "followuser.hive"));
    if (await hiveFile.exists()) {
      return;
    }

    var oldDir = await getApplicationDocumentsDirectory();
    for (var element in hiveFileList) {
      var oldFile = File(p.join(oldDir.path, "$element.hive"));
      if (await oldFile.exists()) {
        var fileName = "$element.hive";
        if (element == "hostiry") {
          fileName = "history.hive";
        }
        await oldFile.copy(p.join(newDir.path, fileName));
        await oldFile.delete();
      }
      var lockFile = File(p.join(oldDir.path, "$element.lock"));
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    }
  } catch (e) {
    Log.logPrint(e);
  }
}

/// 启动早期（尺寸迁移完成前）不写入窗口尺寸，
/// 避免默认尺寸把上次保存的尺寸覆盖掉
var _windowSizeSaveEnabled = false;

/// 桌面端窗口大小记忆：仅保存用户手动调整的尺寸，
/// 最大化/最小化/系统全屏/小窗状态均不保存。
class _WindowSizeListener with WindowListener {
  Timer? _saveTimer;

  @override
  void onWindowResized() {
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_saveWindowSize());
    });
  }

  Future<void> _saveWindowSize() async {
    if (!_windowSizeSaveEnabled) {
      return;
    }
    try {
      // 最大化/最小化/系统全屏时不保存，避免用异常尺寸覆盖用户手动调整的尺寸
      if (await windowManager.isMaximized() ||
          await windowManager.isMinimized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      // 小窗模式下不保存其临时尺寸
      if (Get.isRegistered<LiveRoomController>() &&
          Get.find<LiveRoomController>().smallWindowState.value) {
        return;
      }
      var size = await windowManager.getSize();
      if (size.width < 280 || size.height < 280) {
        return;
      }
      // 轻量文件：下次启动可在 Hive 初始化之前直接读取，加快启动
      await _writeWindowSizeFile(size);
      // 同时写入 Hive，保持与备份 / 同步一致
      try {
        await LocalStorageService.instance.setValue(
          LocalStorageService.kWindowSize,
          [size.width, size.height],
        );
      } catch (e) {
        // 启动早期 Hive 可能尚未初始化，忽略即可
        Log.logPrint(e);
      }
      Log.d("保存窗口大小：${size.width}x${size.height}");
    } catch (e) {
      Log.logPrint(e);
    }
  }
}

final _windowSizeListener = _WindowSizeListener();

/// 窗口尺寸轻量存储文件（纯 dart:io，不依赖 Hive / 插件）
File _windowSizeFile(Directory appDir) =>
    File(p.join(appDir.path, "window_size.txt"));

Future<void> _writeWindowSizeFile(Size size) async {
  try {
    var appDir = await AppDirs.appDataDirectory();
    await _windowSizeFile(appDir).writeAsString("${size.width},${size.height}");
  } catch (e) {
    Log.logPrint(e);
  }
}

/// 恢复用户上次手动调整的窗口大小（不恢复最大化/最小化状态）
Future restoreWindowSize(Directory appDir) async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  try {
    if (await windowManager.isMaximized() ||
        await windowManager.isMinimized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    var file = _windowSizeFile(appDir);
    if (!await file.exists()) {
      return;
    }
    var parts = (await file.readAsString()).trim().split(",");
    if (parts.length != 2) {
      return;
    }
    var width = double.tryParse(parts[0]);
    var height = double.tryParse(parts[1]);
    if (width == null || height == null || width < 280 || height < 280) {
      return;
    }
    await windowManager.setSize(Size(width, height));
    await windowManager.center();
    Log.d("恢复窗口大小：$width x $height");
  } catch (e) {
    Log.logPrint(e);
  }
}

/// 把旧版本只存在 Hive 里的窗口尺寸补写到轻量文件，供下次启动快速恢复
Future<void> migrateWindowSizeToFile() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  try {
    var appDir = await AppDirs.appDataDirectory();
    var file = _windowSizeFile(appDir);
    if (await file.exists()) {
      return;
    }
    var saved = LocalStorageService.instance.getValue<dynamic>(
      LocalStorageService.kWindowSize,
      null,
    );
    if (saved is List && saved.length == 2) {
      await file.writeAsString("${saved[0]},${saved[1]}");
    }
  } catch (e) {
    Log.logPrint(e);
  }
}

/// 桌面端：若处于窗口全屏则退出，返回是否已处理。
/// 用于鼠标侧键/ESC 返回时优先退出窗口全屏，而不是返回上一页。
bool exitWindowFullScreenIfActive() {
  if (Platform.isAndroid || Platform.isIOS) {
    return false;
  }
  if (Get.isRegistered<LiveRoomController>()) {
    final controller = Get.find<LiveRoomController>();
    if (controller.windowFullScreenState.value) {
      controller.exitWindowFullScreen();
      return true;
    }
  }
  return false;
}

Future initWindow() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    minimumSize: Size(280, 280),
    center: true,
    title: "Live",
  );
  // 只等待窗口就绪并应用初始参数，此时窗口仍处于隐藏状态。
  // 显示动作放到尺寸恢复 + 首帧渲染之后（showWindowAfterFirstFrame），
  // 避免启动时先出现默认尺寸的白底窗口，再跳到上次的尺寸。
  await windowManager.waitUntilReadyToShow(windowOptions);
  // 兜底：若启动流程异常导致迟迟没有显示窗口，超时后强制显示，避免无窗口可用
  Timer(const Duration(seconds: 10), () async {
    try {
      if (!await windowManager.isVisible()) {
        await windowManager.show();
        await windowManager.focus();
      }
    } catch (e) {
      Log.logPrint(e);
    }
  });
}

/// 桌面端：等首帧真正上屏后再显示窗口。
/// 原生 runner 已去掉「首帧自动 Show」，这里等启动页完成构建、
/// 再等下一帧栅格化完成（并留一点余量）后显示，避免出现白屏帧。
Future<void> showWindowAfterFirstFrame() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  try {
    // 第一帧（启动页）构建完成；加超时兜底，避免极端情况下卡住不显示窗口
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 300),
      onTimeout: () {},
    );
  } catch (e) {
    Log.logPrint(e);
  }
  // 再等一帧真正栅格化，确保画面已经提交给 GPU
  await _waitNextFrameRasterized();
  try {
    await windowManager.show();
    await windowManager.focus();
  } catch (e) {
    Log.logPrint(e);
  }
}

/// 等待下一帧完成栅格化（FrameTiming 回调晚于 build 完成，更接近真正上屏）
Future<void> _waitNextFrameRasterized() async {
  var completer = Completer<void>();
  void onTimings(List<FrameTiming> timings) {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  WidgetsBinding.instance.addTimingsCallback(onTimings);
  try {
    WidgetsBinding.instance.scheduleFrame();
    await completer.future.timeout(
      const Duration(milliseconds: 200),
      onTimeout: () {},
    );
  } catch (e) {
    Log.logPrint(e);
  } finally {
    WidgetsBinding.instance.removeTimingsCallback(onTimings);
  }
  // 给合成器一帧的时间把这一帧真正提交到窗口
  await Future.delayed(const Duration(milliseconds: 16));
}

/// 注册 Hive 适配器；重复注册会被 Hive 抛错，这里忽略即可
void _registerAdapterOnce<T>(TypeAdapter<T> adapter) {
  try {
    Hive.registerAdapter<T>(adapter);
  } catch (e) {
    Log.logPrint("适配器已注册：$e");
  }
}

Future initServices() async {
  //播放器内核：只在真正需要播放前初始化即可，放到启动页期间完成
  MediaKit.ensureInitialized();
  // 音频模式的后台通知：注册通知栏按钮回调（仅 Android）
  AudioNotification.init();

  // 初始化失败后允许重试，因此每一步都要可重入：
  // 已经注册过的适配器 / 服务不再重复注册，避免重试时二次抛错。
  _registerAdapterOnce(FollowUserAdapter());
  _registerAdapterOnce(HistoryAdapter());

  //包信息
  Utils.packageInfo = await PackageInfo.fromPlatform();
  //本地存储
  if (!Get.isRegistered<LocalStorageService>()) {
    Log.d("Init LocalStorage Service");
    await Get.put(LocalStorageService()).init();
  }
  if (!Get.isRegistered<DBService>()) {
    await Get.put(DBService()).init();
  }
  //初始化设置控制器
  if (!Get.isRegistered<AppSettingsController>()) {
    Get.put(AppSettingsController());
  }

  if (!Get.isRegistered<BiliBiliAccountService>()) {
    Get.put(BiliBiliAccountService());
  }

  if (!Get.isRegistered<DouyinAccountService>()) {
    Get.put(DouyinAccountService());
  }

  if (!Get.isRegistered<FollowService>()) {
    Get.put(FollowService());
  }

  initCoreLog();

  // 旧版本窗口尺寸只存在 Hive 里，补写轻量文件供下次启动快速恢复；
  // 迁移完成后才允许监听器写入尺寸，避免把默认尺寸覆盖上去。
  try {
    await migrateWindowSizeToFile();
  } finally {
    _windowSizeSaveEnabled = true;
  }

  // 自动备份 / 自动同步调度：冷启动一分钟后首次触发，之后随数据变更防抖触发
  BackupScheduler.init();
}

void initCoreLog() {
  //日志信息
  CoreLog.enableLog =
      !kReleaseMode || AppSettingsController.instance.logEnable.value;
  CoreLog.requestLogType = RequestLogType.short;
  CoreLog.onPrintLog = (level, msg) {
    switch (level) {
      case Level.debug:
        Log.d(msg);
        break;
      case Level.error:
        Log.e(msg, StackTrace.current);
        break;
      case Level.info:
        Log.i(msg);
        break;
      case Level.warning:
        Log.w(msg);
        break;
      default:
        Log.logPrint(msg);
    }
  };
}

/// 应用引导：先显示启动页，服务初始化完成后切换到正式界面
class AppBootstrap extends StatefulWidget {
  final Directory appDir;
  const AppBootstrap({super.key, required this.appDir});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  var _ready = false;
  var _retrying = false;
  var _hiveReady = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    try {
      // 旧数据迁移需要先于 Hive 初始化（仅 macOS/Linux 有效，Windows 直接返回）
      await migrateData();
      // Hive 重复 init 会抛「already initialized」，重试时跳过
      if (!_hiveReady) {
        await Hive.initFlutter(
          (!Platform.isAndroid && !Platform.isIOS)
              ? widget.appDir.path
              : null,
        );
        _hiveReady = true;
      }
      await initServices();
      if (!mounted) {
        return;
      }
      setState(() {
        _ready = true;
        _error = null;
      });
    } catch (e, stack) {
      Log.e("初始化服务失败：$e", stack);
      if (!mounted) {
        return;
      }
      // 不再带着半初始化的状态进入主界面（会直接红屏且无提示），
      // 停在启动页给出原因并允许重试。
      setState(() {
        _ready = false;
        _error = "$e";
      });
    }
  }

  Future<void> _retry() async {
    if (_retrying) {
      return;
    }
    setState(() {
      _retrying = true;
      _error = null;
    });
    await _initServices();
    if (!mounted) {
      return;
    }
    setState(() {
      _retrying = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      return const MyApp();
    }
    if (_error != null) {
      return BootError(message: _error!, onRetry: _retry);
    }
    return const BootSplash();
  }
}

/// 启动页：服务初始化期间先给用户反馈，避免窗口迟迟不出现
class BootSplash extends StatelessWidget {
  const BootSplash({super.key});

  /// 此时 Hive 尚未初始化，直接跟随系统深浅色
  bool get _isDark =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;

  @override
  Widget build(BuildContext context) {
    var dark = _isDark;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: Scaffold(
        backgroundColor:
            dark ? const Color(0xFF101012) : const Color(0xFFF7F7F9),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                "assets/images/logo.png",
                width: 72,
                height: 72,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: dark ? Colors.white70 : Colors.black38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 启动失败页：初始化数据目录 / 数据库失败时给出原因并允许重试
class BootError extends StatelessWidget {
  const BootError({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  bool get _isDark =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;

  @override
  Widget build(BuildContext context) {
    var dark = _isDark;
    var textColor = dark ? Colors.white70 : Colors.black87;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: Scaffold(
        backgroundColor:
            dark ? const Color(0xFF101012) : const Color(0xFFF7F7F9),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  "assets/images/logo.png",
                  width: 72,
                  height: 72,
                ),
                const SizedBox(height: 20),
                Text(
                  "启动失败",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: textColor),
                ),
                const SizedBox(height: 20),
                FilledButton.tonal(
                  onPressed: onRetry,
                  child: const Text("重试"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    bool isDynamicColor = AppSettingsController.instance.isDynamic.value;
    Color styleColor = Color(AppSettingsController.instance.styleColor.value);
    return DynamicColorBuilder(
      builder: ((ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme? lightColorScheme;
        ColorScheme? darkColorScheme;
        if (lightDynamic != null && darkDynamic != null && isDynamicColor) {
          lightColorScheme = lightDynamic;
          darkColorScheme = darkDynamic;
        } else {
          lightColorScheme = ColorScheme.fromSeed(
            seedColor: styleColor,
            brightness: Brightness.light,
          );
          darkColorScheme = ColorScheme.fromSeed(
            seedColor: styleColor,
            brightness: Brightness.dark,
          );
        }
        return GetMaterialApp(
          title: "Live",
          theme: AppStyle.lightTheme.copyWith(colorScheme: lightColorScheme),
          darkTheme: AppStyle.darkTheme.copyWith(colorScheme: darkColorScheme),
          themeMode: ThemeMode
              .values[Get.find<AppSettingsController>().themeMode.value],
          initialRoute: RoutePath.kIndex,
          getPages: AppPages.routes,
          //国际化
          locale: const Locale("zh", "CN"),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale("zh", "CN")],
          logWriterCallback: (text, {bool? isError}) {
            Log.addDebugLog(
              text,
              (isError ?? false) ? Colors.red : Colors.grey,
            );
            Log.writeLog(text, (isError ?? false) ? Level.error : Level.info);
          },
          // 升级后Android页面过渡动画似乎有BUG
          defaultTransition: Platform.isAndroid ? Transition.cupertino : null,
          //debugShowCheckedModeBanner: false,
          navigatorObservers: [FlutterSmartDialog.observer],
          builder: FlutterSmartDialog.init(
            loadingBuilder: ((msg) => const AppLoaddingWidget()),
            //字体大小不跟随系统变化
            builder: (context, child) {
              // Fix for HyperOS windowed-mode Flutter bug:
              // - Values > 50 indicate the bug (windowed mode on HyperOS)
              // - Values == 0 are valid for fullscreen/immersive mode and must NOT be treated as abnormal
              const fallbackPadding = EdgeInsets.only(top: 25, bottom: 35);
              const maxNormalPadding = 50.0;

              final mediaQueryData = MediaQuery.of(context);
              final hasAbnormalPadding =
                  mediaQueryData.viewPadding.top > maxNormalPadding;

              final fixedMediaQueryData = hasAbnormalPadding
                  ? mediaQueryData.copyWith(
                      viewPadding: fallbackPadding,
                      padding: fallbackPadding,
                      textScaler: const TextScaler.linear(1.0),
                    )
                  : mediaQueryData.copyWith(
                      textScaler: const TextScaler.linear(1.0),
                    );

              return MediaQuery(
                data: fixedMediaQueryData,
                child: Stack(
                  children: [
                    //侧键返回
                    RawGestureDetector(
                      excludeFromSemantics: true,
                      gestures: <Type, GestureRecognizerFactory>{
                        FourthButtonTapGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<
                              FourthButtonTapGestureRecognizer
                            >(() => FourthButtonTapGestureRecognizer(), (
                              FourthButtonTapGestureRecognizer instance,
                            ) {
                              instance
                                  .onTapDown = (TapDownDetails details) async {
                                //窗口全屏优先退出，不返回上一页
                                if (exitWindowFullScreenIfActive()) {
                                  return;
                                }
                                //如果处于全屏状态，退出全屏
                                if (!Platform.isAndroid && !Platform.isIOS) {
                                  if (await windowManager.isFullScreen()) {
                                    await windowManager.setFullScreen(false);
                                    return;
                                  }
                                }
                                Get.back();
                              };
                            }),
                      },
                      child: KeyboardListener(
                        focusNode: FocusNode(),
                        onKeyEvent: (KeyEvent event) async {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.escape) {
                            // 窗口全屏优先退出
                            if (exitWindowFullScreenIfActive()) {
                              return;
                            }
                            // ESC退出全屏
                            // 如果处于全屏状态，退出全屏
                            if (!Platform.isAndroid && !Platform.isIOS) {
                              if (await windowManager.isFullScreen()) {
                                await windowManager.setFullScreen(false);
                                return;
                              }
                            }
                          }
                        },
                        child: child!,
                      ),
                    ),

                    //查看DEBUG日志按钮
                    //只在Debug、Profile模式显示
                    Visibility(
                      visible: !kReleaseMode,
                      child: Positioned(
                        right: 12,
                        bottom: 100 + context.mediaQueryViewPadding.bottom,
                        child: Opacity(
                          opacity: 0.4,
                          child: ElevatedButton(
                            child: const Text("DEBUG LOG"),
                            onPressed: () {
                              Get.bottomSheet(const DebugLogPage());
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      }),
    );
  }
}
