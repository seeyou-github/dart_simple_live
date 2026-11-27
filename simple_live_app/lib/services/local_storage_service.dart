import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/security/local_field_codec.dart';

class LocalStorageService extends GetxService {
  static LocalStorageService get instance => Get.find<LocalStorageService>();

  /// 首次运行
  static const String kFirstRun = "FirstRun";

  /// 缩放模式
  static const String kPlayerScaleMode = "ScaleMode";

  /// 网站排序
  static const String kSiteSort = "SiteSort";

  /// 首页排序
  static const String kHomeSort = "HomeSort";

  /// 显示模式
  /// * [0] 跟随系统
  /// * [1] 浅色模式
  /// * [2] 深色模式
  static const String kThemeMode = "ThemeMode";

  /// DEBUG模式
  static const String kDebugModeKey = "DebugMode";

  /// 弹幕大小
  static const String kDanmuSize = "DanmuSize";

  /// 弹幕速度
  static const String kDanmuSpeed = "DanmuSpeed";

  /// 弹幕区域
  static const String kDanmuArea = "DanmuArea";

  /// 弹幕透明度
  static const String kDanmuOpacity = "DanmuOpacity";

  /// 弹幕描边大小
  static const String kDanmuStrokeWidth = "DanmuStrokeWidth";

  /// 弹幕-屏蔽滚动
  static const String kDanmuHideScroll = "DanmuHideScroll";

  /// 弹幕-屏蔽底部
  static const String kDanmuHideBottom = "DanmuHideBottom";

  /// 弹幕-屏蔽顶部
  static const String kDanmuHideTop = "DanmuHideTop";

  /// 弹幕-顶部边距
  static const String kDanmuTopMargin = "DanmuTopMargin";

  /// 弹幕-底部边距
  static const String kDanmuBottomMargin = "DanmuBottomMargin";

  /// 弹幕开启
  static const String kDanmuEnable = "DanmuEnable";

  /// 过滤重复弹幕
  static const String kDanmuFilterRepeat = "DanmuFilterRepeat";

  /// 过滤纯表情弹幕
  static const String kDanmuFilterEmoji = "DanmuFilterEmoji";

  /// 过滤纯数字弹幕
  static const String kDanmuFilterNumber = "DanmuFilterNumber";

  /// 弹幕字重
  static const String kDanmuFontWeight = "DanmuFontWeight";

  /// 硬件解码
  static const String kHardwareDecode = "HardwareDecode";

  /// 聊天区文字大小
  static const String kChatTextSize = "ChatTextSize";

  /// 聊天区间隔
  static const String kChatTextGap = "ChatTextGap";

  /// 聊天区-气泡样式
  static const String kChatBubbleStyle = "ChatBubbleStyle";

  /// 播放清晰度，0=低，1=中，2=高
  static const String kQualityLevel = "QualityLevel";

  /// 蜂窝网络下播放清晰度，0=低，1=中，2=高
  static const String kQualityLevelCellular = "QualityLevelCellular";

  /// 开启定时关闭
  static const String kAutoExitEnable = "AutoExitEnable";

  /// 定时关闭时间（分钟）
  static const String kAutoExitDuration = "AutoExitDuration";

  /// 房间内定时关闭时间（分钟）
  /// 需要一个不同的 key，因为用户在房间内设置的倒计时和全局的可能不同。
  static const String kRoomAutoExitDuration = "RoomAutoExitDuration";

  /// 播放器兼容模式
  static const String kPlayerCompatMode = "PlayerCompatMode";

  /// 播放器后台自动暂停
  static const String kPlayerAutoPause = "PlayerAutoPause";

  /// 播放器缓冲区大小
  static const String kPlayerBufferSize = "PlayerBufferSize";

  /// 播放器强制使用HTTPS
  static const String kPlayerForceHttps = "PlayerForceHttps";

  /// 自动全屏
  static const String kAutoFullScreen = "AutoFullScreen";

  /// 播放器音量
  static const String kPlayerVolume = "PlayerVolume";

  /// 小窗隐藏弹幕
  static const String kPIPHideDanmu = "PIPHideDanmu";

  /// 哔哩哔哩cookie
  static const String kBilibiliCookie = "BilibiliCookie";

  /// 抖音cookie
  static const String kDouyinCookie = "DouyinCookie";

  ///主题色
  static const String kStyleColor = "kStyleColor";

  ///动态取色
  static const String kIsDynamic = "kIsDynamic";

  /// 提示哔哩哔哩登录
  static const String kBilibiliLoginTip = "BilibiliLoginTip";

  /// 日志记录
  static const String kLogEnable = "LogEnable";

  /// 开启自定义播放器视频输出
  static const String kCustomPlayerOutput = "CustomPlayerOutput";

  /// 视频输出驱动
  static const String kVideoOutputDriver = "VideoOutputDriver";

  /// 视频硬件解码器
  static const String kVideoHardwareDecoder = "VideoHardwareDecoder";

  /// 音频输出驱动
  static const String kAudioOutputDriver = "AudioOutputDriver";

  /// 开启自动更新关注
  static const String kAutoUpdateFollowEnable = "AutoUpdateFollowEnable";

  /// 定时自动更新关注间隔（分钟）
  static const String kUpdateFollowDuration = "AutoUpdateFollowDuration";

  /// 开启多线程更新关注
  static const String kUpdateFollowThreadCount = "UpdateFollowThreadCount";

  /// WebDAV_服务器地址
  static const String kWebDAVUri = "WebDAVUri";

  /// WebDAV_登录账号
  static const String kWebDAVUser = "WebDAVUser";

  /// WebDAV_登录密码
  static const String kWebDAVPassword = "kWebDAVPassword";

  /// WebDAV_最后一次上传时间
  static const String kWebDAVLastUploadTime = "kWebDAVLastUploadTime";

  /// WebDAV_最后一次备份时间
  static const String kWebDAVLastRecoverTime = "kWebDAVLastRecoverTime";

  /// WebDAV_自动备份开关
  static const String kWebDavAutoBackup = "WebDavAutoBackup";

  /// WebDAV_自动同步开关
  static const String kWebDavAutoSync = "WebDavAutoSync";

  /// WebDAV_跨设备同步基线（记录上次同步的内容与修改时间）
  static const String kWebDavSyncState = "WebDavSyncState";

  /// WebDAV_上次自动备份内容的摘要（内容未变化时跳过重复上传）
  static const String kWebDavLastBackupDigest = "WebDavLastBackupDigest";

  /// 用户手动调整后的窗口大小（仅尺寸，不含最大化/最小化状态）
  static const String kWindowSize = "WindowSize";

  /// 主页分类栏中用户固定的分类（按站点存 JSON）
  static const String kPinnedCategories = "PinnedCategories";

  /// 需要加密保存的字段：本地设置、导出的配置文件、同步到云端的配置文件
  /// 里都不应出现明文。
  static const Set<String> _sealedKeys = {
    kWebDAVUri,
    kWebDAVUser,
    kWebDAVPassword,
  };

  static bool _isSealedKey(dynamic key) =>
      key is String && _sealedKeys.contains(key);

  late Box settingsBox;
  late Box<String> shieldBox;

  Future init() async {
    settingsBox = await Hive.openBox(
      "LocalStorage",
    );
    shieldBox = await Hive.openBox(
      "DanmuShield",
    );
    // 旧版本把 WebDAV 配置存成了明文，启动后统一转成密文
    await sealSensitiveFields();
  }

  /// 把 [sealedKeys] 中仍是明文的字段加密重写一遍。
  ///
  /// 用于两处：启动时迁移旧明文数据；导入配置文件 / 从云端恢复后，
  /// 兼容旧备份里带明文的设置。
  Future<void> sealSensitiveFields() async {
    for (var key in _sealedKeys) {
      var raw = settingsBox.get(key);
      if (raw is String && raw.isNotEmpty && !isSealedField(raw)) {
        await settingsBox.put(key, sealField(raw));
      }
    }
  }

  T getValue<T>(dynamic key, T defaultValue) {
    try {
      dynamic stored = settingsBox.get(key, defaultValue: defaultValue);
      if (_isSealedKey(key) && stored is String) {
        stored = unsealField(stored);
      }
      var value = stored as T;
      var logValue = _isSealedKey(key) ? "******" : "$value";
      Log.d("Get LocalStorage：$key\r\n$logValue");
      return value;
    } catch (e) {
      Log.logPrint(e);
      return defaultValue;
    }
  }

  Future setValue<T>(dynamic key, T value) async {
    var logValue = _isSealedKey(key) ? "******" : "$value";
    Log.d("Set LocalStorage：$key\r\n$logValue");
    dynamic stored = value;
    if (_isSealedKey(key) && value is String) {
      stored = sealField(value);
    }
    return await settingsBox.put(key, stored);
  }

  Future removeValue<T>(dynamic key) async {
    Log.d("Remove LocalStorage：$key");
    return await settingsBox.delete(key);
  }
}
