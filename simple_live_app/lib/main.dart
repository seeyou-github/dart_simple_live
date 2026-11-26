import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/other/debug_log_page.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:window_manager/window_manager.dart';

import 'package:path/path.dart' as p;
import 'package:dynamic_color/dynamic_color.dart';
import 'package:simple_live_app/app/app_dirs.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端单例：若已有实例在运行，则唤醒其窗口并让当前进程退出
  if (await SingleInstance.instance.ensureSingle()) {
    exit(0);
    return;
  }
  await migrateData();
  await initWindow();
  MediaKit.ensureInitialized();
  await Hive.initFlutter(
    (!Platform.isAndroid && !Platform.isIOS)
        ? (await AppDirs.appDataDirectory()).path
        : null,
  );
  //初始化服务
  await initServices();
  //桌面端：注册窗口大小监听并恢复上次手动调整的尺寸
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    windowManager.addListener(_windowSizeListener);
    await restoreWindowSize();
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  //设置状态栏为透明
  SystemUiOverlayStyle systemUiOverlayStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
  );
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
  runApp(const MyApp());
  // 桌面端：窗口尺寸已在显示前恢复，这里等首帧渲染完成后再显示窗口，
  // 避免启动瞬间看到默认尺寸的白底窗口再跳动到上次的尺寸
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
      await LocalStorageService.instance.setValue(
        LocalStorageService.kWindowSize,
        [size.width, size.height],
      );
      Log.d("保存窗口大小：${size.width}x${size.height}");
    } catch (e) {
      Log.logPrint(e);
    }
  }
}

final _windowSizeListener = _WindowSizeListener();

/// 恢复用户上次手动调整的窗口大小（不恢复最大化/最小化状态）
Future restoreWindowSize() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  try {
    if (await windowManager.isMaximized() ||
        await windowManager.isMinimized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    var saved = LocalStorageService.instance.getValue<dynamic>(
      LocalStorageService.kWindowSize,
      null,
    );
    if (saved is List && saved.length == 2) {
      var width = (saved[0] as num).toDouble();
      var height = (saved[1] as num).toDouble();
      if (width >= 280 && height >= 280) {
        await windowManager.setSize(Size(width, height));
        await windowManager.center();
        Log.d("恢复窗口大小：$width x $height");
      }
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

/// 桌面端：等待首帧渲染完成后再显示窗口，避免白屏和尺寸跳变
Future<void> showWindowAfterFirstFrame() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  try {
    await WidgetsBinding.instance.endOfFrame;
  } catch (e) {
    Log.logPrint(e);
  }
  try {
    await windowManager.show();
    await windowManager.focus();
  } catch (e) {
    Log.logPrint(e);
  }
}

Future initServices() async {
  Hive.registerAdapter(FollowUserAdapter());
  Hive.registerAdapter(HistoryAdapter());
  Hive.registerAdapter(FollowUserTagAdapter());

  //包信息
  Utils.packageInfo = await PackageInfo.fromPlatform();
  //本地存储
  Log.d("Init LocalStorage Service");
  await Get.put(LocalStorageService()).init();
  await Get.put(DBService()).init();
  //初始化设置控制器
  Get.put(AppSettingsController());

  Get.put(BiliBiliAccountService());

  Get.put(DouyinAccountService());

  Get.put(SyncService());

  Get.put(FollowService());

  initCoreLog();
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
