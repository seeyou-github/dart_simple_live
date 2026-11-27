import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// 远端备份文件
class BackupFile {
  const BackupFile({
    required this.name,
    required this.size,
    required this.modified,
  });

  final String name;
  final int size;
  final DateTime? modified;
}

/// 带可读原因的 WebDAV 异常
class BackupException implements Exception {
  const BackupException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 把网络 / WebDAV 异常转换成用户可读的文案
String describeBackupError(Object error) {
  if (_mentionsNoHost(error)) {
    return "WebDAV 地址不正确（缺少主机名），请填写完整地址";
  }
  if (error is BackupException) {
    var code = error.statusCode;
    if (code == null || error.message.contains("HTTP $code")) {
      return error.message;
    }
    return "${error.message}（HTTP $code）";
  }
  if (error is dio.DioException) {
    // 用 if 而不是 switch：DioExceptionType 在不同 dio 版本里枚举值数量不同
    // （例如 dio 5.11 才新增 transformTimeout）。switch 要求穷尽枚举，
    // 引用新值会在旧版本编译失败，不引用又会在新版本编译失败。
    var type = error.type;
    if (type == dio.DioExceptionType.connectionTimeout) {
      return "网络超时：连接服务器超时，请检查网络或地址";
    }
    if (type == dio.DioExceptionType.sendTimeout) {
      return "网络超时：上传超时，请检查网络";
    }
    if (type == dio.DioExceptionType.receiveTimeout) {
      return "网络超时：服务器响应过慢，请稍后重试";
    }
    if (type == dio.DioExceptionType.badCertificate) {
      return "证书错误：HTTPS 证书校验失败";
    }
    if (type == dio.DioExceptionType.connectionError) {
      return "网络错误：无法访问服务器${_causeOf(error)}";
    }
    if (type == dio.DioExceptionType.cancel) {
      return "请求已取消";
    }
    if (type == dio.DioExceptionType.badResponse) {
      var code = error.response?.statusCode;
      var message = error.response?.statusMessage;
      return "服务器返回错误：HTTP ${code ?? '未知'}"
          "${message == null || message.isEmpty ? '' : ' $message'}";
    }
    // 其余类型（unknown，以及新版本新增的超时类型）统一归到网络异常
    return "网络异常${_causeOf(error)}";
  }
  var text = "$error";
  return text.length > 200 ? "${text.substring(0, 200)}…" : text;
}

bool _mentionsNoHost(Object error) {
  if ("$error".contains("No host specified")) {
    return true;
  }
  if (error is dio.DioException) {
    return "${error.message}${error.error ?? ''}".contains("No host specified");
  }
  return false;
}

String _causeOf(dio.DioException error) {
  var inner = error.error;
  if (inner == null) {
    return "";
  }
  var text = "$inner";
  if (text.trim().isEmpty) {
    return "";
  }
  return "：${text.length > 120 ? "${text.substring(0, 120)}…" : text}";
}

/// WebDAV 备份客户端
///
/// 备份统一保存在 `<配置地址>/simple_live_app/` 下。备份文件按平台区分：
/// 手机、桌面各自的设置项不同，文件名带 `<平台>_` 前缀，恢复时只列出当前平台，
/// 避免把 Windows 的备份恢复到 Android 上。跨设备同步文件全平台共用一份。
class BackupClient {
  BackupClient._();

  static final BackupClient instance = BackupClient._();

  /// 远端备份目录（相对配置地址）
  static const folderPath = "/simple_live_app";

  /// 跨设备同步数据文件名（全平台共用一份，不能加平台前缀，
  /// 否则新设备接入时会读不到已有同步数据而把云端覆盖成空）
  static const syncFileName = "Sync_SimpleLive.json";

  /// 手动备份文件名前缀
  static const backupNamePrefix = "SimpleLive_backup_";

  /// 自动备份文件名（同平台固定名称，每次覆盖），如 `Windows_Autobackup.zip`
  static const autoBackupNameSuffix = "Autobackup.zip";

  /// 当前平台标识（用于文件名前缀与界面提示）
  static String get platformLabel {
    if (Platform.isWindows) {
      return "Windows";
    }
    if (Platform.isAndroid) {
      return "Android";
    }
    if (Platform.isIOS) {
      return "iOS";
    }
    if (Platform.isMacOS) {
      return "macOS";
    }
    if (Platform.isLinux) {
      return "Linux";
    }
    return "Other";
  }

  /// 当前平台的备份文件名前缀，用于隔离各平台的备份
  static String get platformPrefix => "${platformLabel}_";

  /// 自动备份的固定文件名（同平台每次覆盖）
  static String get autoBackupFileName =>
      "$platformPrefix$autoBackupNameSuffix";

  /// 旧版自动备份文件名，仅用于兼容与上传后清理：
  /// * 第一版：`SimpleLive_AutoBackup_<平台>.zip`
  /// * 中间版：`<平台>_SimpleLive_AutoBackup.zip`
  static String get legacyAutoBackupFileName =>
      "SimpleLive_AutoBackup_$platformLabel.zip";

  static String get _interimAutoBackupFileName =>
      "$platformPrefix$_interimAutoBackupPrefix.zip";

  static const _interimAutoBackupPrefix = "SimpleLive_AutoBackup";

  static String _filePath(String name) => "$folderPath/$name";

  webdav.Client? _client;
  ({String uri, String user, String password})? _clientConfig;
  Future<void> _uploadChain = Future<void>.value();
  bool _uploading = false;

  bool get uploading => _uploading;

  String get _uri =>
      LocalStorageService.instance.getValue(LocalStorageService.kWebDAVUri, "");

  String get _user => LocalStorageService.instance
      .getValue(LocalStorageService.kWebDAVUser, "");

  String get _password => LocalStorageService.instance
      .getValue(LocalStorageService.kWebDAVPassword, "");

  /// 当前配置（已解密）
  String get uri => _uri;

  String get user => _user;

  String get password => _password;

  bool get isConfigured {
    var uri = Uri.tryParse(_uri.trim());
    return uri != null &&
        (uri.scheme == "http" || uri.scheme == "https") &&
        uri.host.isNotEmpty;
  }

  /// 保存配置：只在内容变化时写入，避免每次保存都触发自动备份
  ///
  /// 返回是否发生了变化（用于配置好之后立即安排一次同步）。
  Future<bool> saveConfig({
    required String uri,
    required String user,
    required String password,
  }) async {
    var normalizedUri = uri.trim();
    var normalizedUser = user.trim();
    var storage = LocalStorageService.instance;
    var changed = false;
    if (_uri != normalizedUri) {
      await storage.setValue(LocalStorageService.kWebDAVUri, normalizedUri);
      changed = true;
    }
    if (_user != normalizedUser) {
      await storage.setValue(LocalStorageService.kWebDAVUser, normalizedUser);
      changed = true;
    }
    if (_password != password) {
      await storage.setValue(LocalStorageService.kWebDAVPassword, password);
      changed = true;
    }
    if (changed) {
      // 配置变更后旧连接不再可用；正在上传时保留到本次请求结束
      if (!_uploading) {
        _closeClient();
      } else {
        _clientConfig = null;
        _client = null;
      }
    }
    return changed;
  }

  /// 释放缓存的 WebDAV 连接
  void dispose() => _closeClient();

  void _closeClient() {
    var client = _client;
    _client = null;
    _clientConfig = null;
    if (client == null) {
      return;
    }
    try {
      client.c.close(force: true);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<webdav.Client> _connect({bool force = false}) async {
    if (!isConfigured) {
      throw const BackupException("请填写包含 http(s):// 的 WebDAV 地址");
    }
    var config = (uri: _uri.trim(), user: _user, password: _password);
    var cached = _client;
    if (!force && cached != null && _clientConfig == config) {
      return cached;
    }
    var client = webdav.newClient(
      config.uri,
      user: config.user,
      password: config.password,
    )
      ..setHeaders({"accept-charset": "utf-8"})
      ..setConnectTimeout(15000)
      ..setReceiveTimeout(30000)
      ..setSendTimeout(30000);
    _client = client;
    _clientConfig = config;
    return client;
  }

  /// 测试连接并创建备份目录；返回 null 表示成功，否则是失败原因
  Future<String?> testConnection() async {
    try {
      var client = await _connect(force: true);
      await client.mkdirAll(folderPath);
      return null;
    } catch (e) {
      Log.logPrint(e);
      return describeBackupError(e);
    }
  }

  /// 串行上传：自动备份与手动备份同时触发时排队，避免相互打断
  Future<void> upload(Uint8List bytes, String fileName) {
    var completer = Completer<void>();
    _uploadChain = _uploadChain.then((_) async {
      _uploading = true;
      try {
        var client = await _connect();
        await client.mkdirAll(folderPath);
        await client.write(_filePath(fileName), bytes);
        completer.complete();
      } catch (e, stack) {
        completer.completeError(e, stack);
      } finally {
        _uploading = false;
      }
    });
    return completer.future;
  }

  /// 远端备份列表（按修改时间倒序）
  Future<List<BackupFile>> listBackups() async {
    var client = await _connect();
    // 先确保目录存在，避免首次读取时 PROPFIND 返回 404
    await client.mkdirAll(folderPath);
    List<webdav.File> items;
    try {
      items = await client.readDir(folderPath);
    } on dio.DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return const [];
      }
      rethrow;
    }
    var list = <BackupFile>[];
    for (var item in items) {
      if (item.isDir == true) {
        continue;
      }
      var name = item.name ?? "";
      if (name.isEmpty || name == "." || name == "..") {
        continue;
      }
      if (!name.toLowerCase().endsWith(".zip")) {
        continue;
      }
      // 只显示当前平台的备份；旧版 backup.zip 结构不同，无法恢复，不显示
      if (!_isCurrentPlatformFile(name)) {
        continue;
      }
      list.add(
        BackupFile(
          name: name,
          size: item.size ?? 0,
          modified: item.mTime,
        ),
      );
    }
    list.sort(
      (a, b) =>
          (b.modified ?? DateTime(0)).compareTo(a.modified ?? DateTime(0)),
    );
    return list;
  }

  /// 判断备份文件是否属于当前平台
  ///
  /// 当前命名：`<平台>_SimpleLive_backup_*.zip` / `<平台>_Autobackup.zip`；
  /// 历史自动备份命名也一并兼容（同平台才算）。
  static bool _isCurrentPlatformFile(String name) {
    if (name == autoBackupFileName ||
        name == legacyAutoBackupFileName ||
        name == _interimAutoBackupFileName) {
      return true;
    }
    if (!name.startsWith(platformPrefix)) {
      return false;
    }
    return name.startsWith("$platformPrefix$backupNamePrefix");
  }

  /// 上传新版自动备份后清理历史命名的自动备份文件，
  /// 避免恢复列表出现多个同平台自动备份
  Future<void> removeLegacyAutoBackup() async {
    for (var name in [
      legacyAutoBackupFileName,
      _interimAutoBackupFileName,
    ]) {
      try {
        var client = await _connect();
        await client.remove(_filePath(name));
      } catch (e) {
        // 不存在或服务器不支持删除都忽略，不影响备份结果
      }
    }
  }

  /// 直接 GET 下载，绕过部分服务器对 OPTIONS 预检的 301
  Future<Uint8List> download(String name) async {
    var client = await _connect();
    var response = await client.c.req<dynamic>(
      client,
      "GET",
      _filePath(name),
      optionsHandler: (options) {
        options.responseType = dio.ResponseType.bytes;
        options.followRedirects = true;
        options.validateStatus = (status) => status != null;
        options.receiveTimeout = const Duration(minutes: 2);
      },
    );
    var status = response.statusCode ?? 0;
    if (status != 200) {
      if (status == 404) {
        throw const BackupException("远端文件不存在（HTTP 404）", statusCode: 404);
      }
      throw BackupException("下载失败：HTTP $status", statusCode: status);
    }
    var data = response.data;
    if (data is Uint8List) {
      return data;
    }
    if (data is List<int>) {
      return Uint8List.fromList(data);
    }
    throw const BackupException("下载失败：服务器没有返回数据");
  }

  /// 读取同步文件；不存在时返回 null
  Future<Uint8List?> downloadIfExists(String name) async {
    try {
      return await download(name);
    } on BackupException catch (e) {
      if (e.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> delete(String name) async {
    var client = await _connect();
    await client.remove(_filePath(name));
  }

  /// 手动备份文件名：`Windows_SimpleLive_backup_2026.11.27-08.00.00.zip`
  static String buildBackupFileName([DateTime? now]) {
    var t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, "0");
    return "$platformPrefix$backupNamePrefix"
        "${t.year}.${two(t.month)}.${two(t.day)}-"
        "${two(t.hour)}.${two(t.minute)}.${two(t.second)}.zip";
  }
}
