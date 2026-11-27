import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/app_dirs.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 备份数据包
///
/// 包含：本地关注、本地关注标签、设置（含主页分类栏固定分类）、
/// 账号、弹幕屏蔽词。**不包含播放历史**。
///
/// 恢复时关注、标签、固定分类、屏蔽词采用合并方式（不删除本地已有条目），
/// 设置与账号按备份覆盖；同步基线不会被覆盖。
class BackupArchive {
  BackupArchive._();

  static const metaFileName = "meta.json";
  static const followsFileName = "follows.json";
  static const tagsFileName = "tags.json";
  static const settingsFileName = "settings.json";
  static const accountFileName = "account.json";
  static const blockWordsFileName = "blockwords.json";

  static const _type = "simple_live_backup";

  /// 解压后总大小上限
  static const _maxTotalBytes = 64 * 1024 * 1024;

  /// 恢复设置时需要保留本机值的键：同步基线（本机状态，不应被旧备份覆盖）
  static const _keepLocalKeys = {LocalStorageService.kWebDavSyncState};

  /// WebDAV 配置：备份里有非空值时才覆盖，避免用空值把本机配置清掉
  static const _webDavKeys = {
    LocalStorageService.kWebDAVUri,
    LocalStorageService.kWebDAVUser,
    LocalStorageService.kWebDAVPassword,
  };

  /// 组装备份包
  static Uint8List exportBytes() {
    var follows = DBService.instance
        .getFollowList()
        .map((e) => e.toJson())
        .toList();
    var tags =
        DBService.instance.getFollowTagList().map((e) => e.toJson()).toList();
    var settings = LocalStorageService.instance.settingsBox.toMap();
    var account = {
      "bilibili": BiliBiliAccountService.instance.cookie,
      "douyin": DouyinAccountService.instance.cookie,
    };
    var blockWords = LocalStorageService.instance.shieldBox.values
        .map((e) => "$e")
        .where((e) => e.trim().isNotEmpty)
        .toList();

    var archive = Archive();
    void addJson(String name, Object value) {
      var bytes = utf8.encode(jsonEncode(value));
      archive.add(ArchiveFile(name, bytes.length, bytes));
    }

    addJson(metaFileName, {
      "type": _type,
      "platform": Platform.operatingSystem,
      "time": DateTime.now().millisecondsSinceEpoch,
      "version": 1,
    });
    addJson(followsFileName, follows);
    addJson(tagsFileName, tags);
    addJson(settingsFileName, settings);
    addJson(accountFileName, account);
    addJson(blockWordsFileName, blockWords);

    var encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded);
  }

  /// 恢复备份包（合并导入）
  ///
  /// 返回值是附加提示（部分数据未能还原时的说明），完全成功返回 null。
  static Future<String?> importBytes(Uint8List bytes) async {
    if (bytes.length > _maxTotalBytes) {
      throw const FormatException("数据包过大");
    }
    var archive = ZipDecoder().decodeBytes(bytes);
    var meta = _decode(archive, metaFileName);
    if (meta is! Map || meta["type"] != _type) {
      throw const FormatException("不是有效的备份文件");
    }

    var notes = <String>[];
    var totalBytes = 0;

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

    // 关注标签（先于关注导入）
    var tags = read(tagsFileName);
    if (tags is List) {
      for (var item in tags) {
        if (item is! Map) {
          continue;
        }
        try {
          var tag = FollowUserTag.fromJson(Map<String, dynamic>.from(item));
          if (tag.id.isEmpty) {
            continue;
          }
          var local = DBService.instance.tagBox.get(tag.id);
          if (local == null) {
            await DBService.instance.tagBox.put(tag.id, tag);
          } else {
            // 合并标签下的关注 id，不删除本地已有关联
            local.userId.addAll(
              tag.userId.where((e) => !local.userId.contains(e)),
            );
            await DBService.instance.updateFollowTag(local);
          }
        } catch (e) {
          notes.add("标签导入部分失败");
        }
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

    return notes.isEmpty ? null : notes.toSet().join("，");
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
  static Future<String?> exportToFile() async {
    var bytes = exportBytes();
    var inlineSave = Platform.isAndroid || Platform.isIOS || kIsWeb;
    String? path;
    if (Platform.isWindows) {
      var dir = await AppDirs.appDataSubdirectory("exports");
      path = p.join(
        dir.path,
        "simple_live_backup_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.zip",
      );
    } else {
      path = await FilePicker.platform.saveFile(
        allowedExtensions: ["zip"],
        type: FileType.custom,
        fileName: "simple_live_backup.zip",
        bytes: inlineSave ? bytes : null,
      );
    }
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
    var note = await importBytes(await File(path).readAsBytes());
    return BackupImportResult.done(note);
  }
}

/// 本机文件导入结果：区分「用户取消」和「成功但存在附加提示」
class BackupImportResult {
  const BackupImportResult.cancelled()
      : applied = false,
        note = null;

  const BackupImportResult.done(this.note) : applied = true;

  final bool applied;

  /// 部分数据未能还原时的说明
  final String? note;
}
