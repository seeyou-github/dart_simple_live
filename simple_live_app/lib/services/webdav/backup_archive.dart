import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/webdav/backup_client.dart';

/// 备份数据包
///
/// 包含：本地关注、设置（含主页分类栏固定分类）、账号、弹幕屏蔽词。
/// **不包含播放历史，也不包含关注标签**（标签功能已移除）。
///
/// 恢复时关注、固定分类、屏蔽词采用合并方式（不删除本地已有条目），
/// 设置与账号按备份覆盖；同步基线不会被覆盖。
class BackupArchive {
  BackupArchive._();

  static const metaFileName = "meta.json";
  static const followsFileName = "follows.json";
  static const settingsFileName = "settings.json";
  static const accountFileName = "account.json";
  static const blockWordsFileName = "blockwords.json";

  static const _type = "simple_live_backup";

  /// 解压后总大小上限
  static const _maxTotalBytes = 64 * 1024 * 1024;

  /// 压缩包体积上限：先卡住压缩包本身，避免几十 MB 的压缩包直接读进内存
  static const _maxArchiveBytes = 32 * 1024 * 1024;

  /// 恢复设置时需要保留本机值的键：同步基线（本机状态，不应被旧备份覆盖）
  static const _keepLocalKeys = {LocalStorageService.kWebDavSyncState};

  /// WebDAV 配置：备份里有非空值时才覆盖，避免用空值把本机配置清掉
  static const _webDavKeys = {
    LocalStorageService.kWebDAVUri,
    LocalStorageService.kWebDAVUser,
    LocalStorageService.kWebDAVPassword,
  };

  /// 备份内容（不含生成时间等易变字段）
  ///
  /// 单独抽出来是为了能算「内容摘要」：包内 meta 带生成时间，
  /// 直接对打包结果做摘要是永远不相等的。
  static Map<String, Object?> collectContent() {
    var follows = DBService.instance
        .getFollowList()
        .map((e) => e.toJson())
        .toList();
    // 两个纯本机状态不参与备份：
    // * 同步基线（每次同步都会变，而且恢复时本就应该保留本机值）
    // * 上次备份摘要（写摘要本身就会改变内容，导致摘要永远对不上）
    var settings = LocalStorageService.instance.settingsBox.toMap()
      ..remove(LocalStorageService.kWebDavSyncState)
      ..remove(LocalStorageService.kWebDavLastBackupDigest);
    var account = {
      "bilibili": BiliBiliAccountService.instance.cookie,
      "douyin": DouyinAccountService.instance.cookie,
    };
    var blockWords = LocalStorageService.instance.shieldBox.values
        .map((e) => "$e")
        .where((e) => e.trim().isNotEmpty)
        .toList();
    return {
      "follows": follows,
      "settings": settings,
      "account": account,
      "blockWords": blockWords,
    };
  }

  /// 备份内容摘要：内容没变化时值不变，用于跳过重复上传
  static String contentDigest() {
    var text = jsonEncode(collectContent());
    return crypto.sha1.convert(utf8.encode(text)).toString();
  }

  /// 组装备份包
  static Uint8List exportBytes() {
    var content = collectContent();
    var archive = Archive();
    void addJson(String name, Object? value) {
      var bytes = utf8.encode(jsonEncode(value));
      archive.add(ArchiveFile(name, bytes.length, bytes));
    }

    addJson(metaFileName, {
      "type": _type,
      "platform": Platform.operatingSystem,
      "time": DateTime.now().millisecondsSinceEpoch,
      "version": 1,
    });
    addJson(followsFileName, content["follows"]);
    addJson(settingsFileName, content["settings"]);
    addJson(accountFileName, content["account"]);
    addJson(blockWordsFileName, content["blockWords"]);

    var encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded);
  }

  /// 恢复备份包（合并导入）
  ///
  /// 返回结果中的 [BackupImportResult.note] 是附加提示（部分数据未能还原时
  /// 的说明），完全成功时为 null；[BackupImportResult.basisMillis] 是备份
  /// 生成时间，供同步时判断「哪边更新」使用。
  static Future<BackupImportResult> importBytes(Uint8List bytes) async {
    if (bytes.length > _maxArchiveBytes) {
      throw const FormatException("数据包过大");
    }
    var archive = ZipDecoder().decodeBytes(bytes);
    // 先按头部记录的未压缩大小做总闸：压缩率异常的包（zip 炸弹）
    // 在读取内容之前就会被拒绝，不会等到解压完才发现
    var declaredBytes = 0;
    for (var file in archive) {
      declaredBytes += file.size;
      if (declaredBytes > _maxTotalBytes) {
        throw const FormatException("数据包过大");
      }
    }
    var meta = _decode(archive, metaFileName);
    if (meta is! Map || meta["type"] != _type) {
      throw const FormatException("不是有效的备份文件");
    }

    var notes = <String>[];
    var totalBytes = 0;

    // 备份生成时间：恢复出的数据以它为准，避免旧备份覆盖云端较新的记录。
    // 文件拷贝会改掉修改时间，所以用包内时间，并丢弃明显异常的未来时间。
    var metaTime = (meta["time"] as num?)?.toInt() ?? 0;
    var basis =
        metaTime > 0 && metaTime <= DateTime.now().millisecondsSinceEpoch
            ? metaTime
            : null;

    // 跨平台导入（例如把电脑上的备份拷到手机）时提示来源平台：
    // 平台专属设置项在其它平台上未必适用
    var sourcePlatform = "${meta["platform"] ?? ""}";
    if (sourcePlatform.isNotEmpty &&
        sourcePlatform != Platform.operatingSystem) {
      notes.add("备份来自 $sourcePlatform 平台");
    }

    Object? read(String name) {
      var file = _find(archive, name);
      if (file == null) {
        return null;
      }
      totalBytes += file.size;
      if (totalBytes > _maxTotalBytes) {
        throw const FormatException("数据包过大");
      }
      try {
        return jsonDecode(utf8.decode(file.content));
      } catch (e) {
        notes.add("$name 解析失败");
        return null;
      }
    }

    // 设置：固定分类合并，其余设置项覆盖
    var settings = read(settingsFileName);
    if (settings is Map) {
      await _importSettings(Map<String, dynamic>.from(settings));
    }

    // 账号
    var account = read(accountFileName);
    if (account is Map) {
      var bili = account["bilibili"]?.toString() ?? "";
      var douyin = account["douyin"]?.toString() ?? "";
      if (bili.isNotEmpty) {
        BiliBiliAccountService.instance.setCookie(bili);
      }
      if (douyin.isNotEmpty) {
        DouyinAccountService.instance.setCookie(douyin);
      }
    }

    // 本地关注（合并：同 id 以备份为准，不删除本地其它关注）
    var follows = read(followsFileName);
    if (follows is List) {
      for (var item in follows) {
        if (item is! Map) {
          continue;
        }
        try {
          var follow = FollowUser.fromJson(Map<String, dynamic>.from(item));
          if (follow.id.isEmpty) {
            continue;
          }
          await DBService.instance.addFollow(follow);
        } catch (e) {
          notes.add("关注导入部分失败");
        }
      }
    }

    // 屏蔽词（并集，不删除本地已有）
    var blockWords = read(blockWordsFileName);
    if (blockWords is List) {
      for (var word in blockWords) {
        var text = "$word".trim();
        if (text.isEmpty) {
          continue;
        }
        await LocalStorageService.instance.shieldBox.put(text, text);
      }
    }

    _refreshShieldList();
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
    EventBus.instance.emit(Constant.kUpdatePinnedCategories, 0);

    return BackupImportResult.done(
      notes.isEmpty ? null : notes.toSet().join("，"),
      basisMillis: basis,
    );
  }

  static ArchiveFile? _find(Archive archive, String name) {
    for (var file in archive) {
      if (file.name == name) {
        return file;
      }
    }
    return null;
  }

  static Object? _decode(Archive archive, String name) {
    var file = _find(archive, name);
    if (file == null) {
      return null;
    }
    try {
      return jsonDecode(utf8.decode(file.content));
    } catch (e) {
      return null;
    }
  }

  static Future<void> _importSettings(Map<String, dynamic> incoming) async {
    var storage = LocalStorageService.instance;

    // 固定分类合并，不覆盖本地已有项
    var localPinned = storage.getValue<String>(
      LocalStorageService.kPinnedCategories,
      "",
    );
    var remotePinned = incoming[LocalStorageService.kPinnedCategories];
    var mergedPinned = _mergePinnedCategories(
      localPinned,
      remotePinned is String ? remotePinned : jsonEncode(remotePinned ?? {}),
    );

    for (var entry in incoming.entries) {
      if (_keepLocalKeys.contains(entry.key) ||
          entry.key == LocalStorageService.kPinnedCategories) {
        continue;
      }
      if (_webDavKeys.contains(entry.key)) {
        var value = entry.value;
        if (value is! String || value.trim().isEmpty) {
          continue;
        }
      }
      await storage.settingsBox.put(entry.key, entry.value);
    }
    await storage.setValue(
      LocalStorageService.kPinnedCategories,
      mergedPinned,
    );
    // 备份里可能是旧版本的明文配置，统一转成密文
    await storage.sealSensitiveFields();
  }

  /// 按站点合并固定分类：两边都保留，按 parentId + categoryId 去重
  static String _mergePinnedCategories(String localRaw, String remoteRaw) {
    var local = _decodePinned(localRaw);
    var remote = _decodePinned(remoteRaw);
    var result = <String, dynamic>{};
    var sites = <String>{...local.keys, ...remote.keys};
    for (var site in sites) {
      var merged = <Map<String, dynamic>>[];
      var seen = <String>{};
      for (var item in [...?local[site], ...?remote[site]]) {
        var key = "${item["parentId"]}|${item["categoryId"]}";
        if (seen.add(key)) {
          merged.add(item);
        }
      }
      result[site] = merged;
    }
    return jsonEncode(result);
  }

  static Map<String, List<Map<String, dynamic>>> _decodePinned(String raw) {
    var result = <String, List<Map<String, dynamic>>>{};
    if (raw.trim().isEmpty) {
      return result;
    }
    try {
      var decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return result;
      }
      for (var entry in decoded.entries) {
        if (entry.value is! List) {
          continue;
        }
        result["${entry.key}"] = (entry.value as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return result;
  }

  static void _refreshShieldList() {
    try {
      if (Get.isRegistered<AppSettingsController>()) {
        Get.find<AppSettingsController>().shieldList.assignAll(
          LocalStorageService.instance.shieldBox.values
              .map((e) => "$e")
              .where((e) => e.trim().isNotEmpty),
        );
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 一键导出到本机文件；返回保存路径，取消时返回 null
  ///
  /// 全平台统一走系统「另存为」对话框，由用户决定保存位置；
  /// Android / iOS 走 SAF，保存时需要直接带上文件内容。
  static Future<String?> exportToFile() async {
    var bytes = exportBytes();
    var inlineSave = Platform.isAndroid || Platform.isIOS;
    var path = await FilePicker.platform.saveFile(
      dialogTitle: "保存备份",
      allowedExtensions: ["zip"],
      type: FileType.custom,
      fileName: "${BackupClient.platformPrefix}SimpleLive_backup.zip",
      bytes: inlineSave ? bytes : null,
    );
    if (path == null) {
      return null;
    }
    if (!inlineSave) {
      await File(path).writeAsBytes(bytes);
    }
    return path;
  }

  /// 一键从本机文件导入（合并）
  static Future<BackupImportResult> importFromFile() async {
    var result = await FilePicker.platform.pickFiles(
      allowedExtensions: ["zip"],
      type: FileType.custom,
    );
    if (result == null) {
      return const BackupImportResult.cancelled();
    }
    var path = result.files.single.path;
    if (path == null) {
      return const BackupImportResult.cancelled();
    }
    var file = File(path);
    // 先按文件长度拦一次，避免超大文件一次性读进内存
    if (await file.length() > _maxArchiveBytes) {
      throw const FormatException("数据包过大");
    }
    return importBytes(await file.readAsBytes());
  }
}

/// 本机文件导入结果：区分「用户取消」和「成功但存在附加提示」
class BackupImportResult {
  const BackupImportResult.cancelled()
      : applied = false,
        note = null,
        basisMillis = null;

  const BackupImportResult.done(this.note, {this.basisMillis}) : applied = true;

  final bool applied;

  /// 部分数据未能还原时的说明
  final String? note;

  /// 备份生成时间（包内 meta 记录），作为同步时间基准：
  /// 避免导入的旧数据被当成最新修改而覆盖云端较新的记录
  final int? basisMillis;
}
