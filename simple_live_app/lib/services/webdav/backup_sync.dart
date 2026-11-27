import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/webdav/backup_archive.dart';
import 'package:simple_live_app/services/webdav/backup_client.dart';
import 'package:simple_live_app/services/webdav/backup_task.dart';

const _syncFileVersion = 1;

/// 墓碑保留时长：超过后不再参与合并，避免文件无限增长
const _tombstoneTtlMs = 180 * 24 * 60 * 60 * 1000;

/// 一次同步的结果
enum BackupSyncOutcome { success, skipped, failure }

class BackupSyncResult {
  const BackupSyncResult.success()
      : outcome = BackupSyncOutcome.success,
        message = null;

  const BackupSyncResult.skipped([this.message])
      : outcome = BackupSyncOutcome.skipped;

  const BackupSyncResult.failure(String message)
      : outcome = BackupSyncOutcome.failure,
        message = message;

  final BackupSyncOutcome outcome;

  /// 失败 / 跳过原因（成功时为 null）
  final String? message;
}

class _Record {
  const _Record({required this.updatedAt, this.deleted = false, this.data});

  /// 修改时间（毫秒时间戳）
  final int updatedAt;

  /// 墓碑：表示该条目已被删除
  final bool deleted;

  final Map<String, dynamic>? data;

  bool sameAs(_Record other) =>
      updatedAt == other.updatedAt &&
      deleted == other.deleted &&
      mapEquals(data, other.data);

  Map<String, dynamic> toJson() => {
        "u": updatedAt,
        if (deleted)
          "d": true
        else if (data != null)
          "m": data,
      };

  static _Record? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    var updatedAt = (json["u"] as num?)?.toInt() ?? 0;
    var deleted = json["d"] == true;
    var data = json["m"];
    if (data != null && data is! Map) {
      return null;
    }
    return _Record(
      updatedAt: updatedAt,
      deleted: deleted,
      data: data is Map ? Map<String, dynamic>.from(data) : null,
    );
  }
}

/// 同步快照：关注 / 标签 / 固定分类 / 屏蔽词
class _SyncState {
  _SyncState({
    Map<String, _Record>? follows,
    Map<String, _Record>? tags,
    Map<String, _Record>? categories,
    Map<String, _Record>? blockWords,
  })  : follows = follows ?? {},
        tags = tags ?? {},
        categories = categories ?? {},
        blockWords = blockWords ?? {};

  final Map<String, _Record> follows;
  final Map<String, _Record> tags;
  final Map<String, _Record> categories;
  final Map<String, _Record> blockWords;

  static _SyncState? load() {
    var raw = LocalStorageService.instance.getValue<String>(
      LocalStorageService.kWebDavSyncState,
      "",
    );
    if (raw.trim().isEmpty) {
      return null;
    }
    try {
      return decode(utf8.encode(raw));
    } catch (e) {
      return null;
    }
  }

  static _SyncState decode(List<int> bytes) {
    var json = jsonDecode(utf8.decode(bytes));
    if (json is! Map) {
      throw const FormatException("同步文件格式不正确");
    }
    var version = (json["version"] as num?)?.toInt() ?? 0;
    if (version != _syncFileVersion) {
      throw FormatException("同步文件版本不支持：$version");
    }
    return _SyncState(
      follows: _decodeMap(json["follows"]),
      tags: _decodeMap(json["tags"]),
      categories: _decodeMap(json["categories"]),
      blockWords: _decodeMap(json["blockWords"]),
    );
  }

  static Map<String, _Record> _decodeMap(Object? value) {
    var result = <String, _Record>{};
    if (value == null) {
      return result;
    }
    if (value is! Map) {
      throw const FormatException("同步文件记录格式不正确");
    }
    for (var entry in value.entries) {
      var record = _Record.fromJson(entry.value);
      if (record == null) {
        throw const FormatException("同步文件记录损坏");
      }
      result["${entry.key}"] = record;
    }
    return result;
  }

  /// 以「本地数据 + 上次同步基线」生成当前记录，识别新增、修改与删除
  ///
  /// [restoreBasis] 是刚恢复的备份文件的修改时间：恢复出的数据以它为准，
  /// 避免把旧备份内容当成「刚刚修改」而覆盖云端较新的记录。
  static _SyncState fromLocal(
    _SyncState? baseline, {
    required int now,
    int? restoreBasis,
  }) {
    var state = _SyncState();

    // 本地关注
    var follows = {
      for (var item in DBService.instance.followBox.values) item.id: item,
    };
    for (var entry in follows.entries) {
      var map = entry.value.toJson();
      var base = baseline?.follows[entry.key];
      if (base != null && !base.deleted && mapEquals(base.data, map)) {
        state.follows[entry.key] = base;
      } else if (base != null) {
        state.follows[entry.key] = _Record(
          updatedAt: restoreBasis ?? now,
          data: map,
        );
      } else {
        state.follows[entry.key] = _Record(
          updatedAt: restoreBasis ??
              entry.value.addTime.millisecondsSinceEpoch,
          data: map,
        );
      }
    }
    _carryTombstones(state.follows, baseline?.follows, follows.keys, now);

    // 本地关注标签
    var tags = {
      for (var item in DBService.instance.tagBox.values) item.id: item,
    };
    for (var entry in tags.entries) {
      var map = entry.value.toJson();
      var base = baseline?.tags[entry.key];
      if (base != null && !base.deleted && mapEquals(base.data, map)) {
        state.tags[entry.key] = base;
      } else {
        state.tags[entry.key] = _Record(
          updatedAt: restoreBasis ?? now,
          data: map,
        );
      }
    }
    _carryTombstones(state.tags, baseline?.tags, tags.keys, now);

    // 主页分类栏固定分类（按 站点|父分类|分类 逐项记录）
    var categories = _readPinned();
    for (var entry in categories.entries) {
      var base = baseline?.categories[entry.key];
      if (base != null && !base.deleted && mapEquals(base.data, entry.value)) {
        state.categories[entry.key] = base;
      } else {
        state.categories[entry.key] = _Record(
          updatedAt: restoreBasis ?? now,
          data: entry.value,
        );
      }
    }
    _carryTombstones(
      state.categories,
      baseline?.categories,
      categories.keys,
      now,
    );

    // 弹幕关键词屏蔽
    var words = {
      for (var word in LocalStorageService.instance.shieldBox.values)
        if ("$word".trim().isNotEmpty) "$word".trim(): true,
    };
    for (var word in words.keys) {
      var base = baseline?.blockWords[word];
      state.blockWords[word] = base != null && !base.deleted
          ? base
          : _Record(updatedAt: restoreBasis ?? now);
    }
    _carryTombstones(state.blockWords, baseline?.blockWords, words.keys, now);

    return state;
  }

  static void _carryTombstones(
    Map<String, _Record> target,
    Map<String, _Record>? baseline,
    Iterable<String> liveKeys,
    int now,
  ) {
    if (baseline == null) {
      return;
    }
    var live = liveKeys.toSet();
    for (var entry in baseline.entries) {
      if (live.contains(entry.key)) {
        continue;
      }
      target[entry.key] = entry.value.deleted
          ? entry.value
          : _Record(updatedAt: now, deleted: true);
    }
  }

  static _SyncState merge(_SyncState local, _SyncState? remote) {
    if (remote == null) {
      return local;
    }
    return _SyncState(
      follows: _mergeMap(local.follows, remote.follows),
      tags: _mergeMap(local.tags, remote.tags),
      categories: _mergeMap(local.categories, remote.categories),
      blockWords: _mergeMap(local.blockWords, remote.blockWords),
    );
  }

  static Map<String, _Record> _mergeMap(
    Map<String, _Record> local,
    Map<String, _Record> remote,
  ) {
    var result = Map<String, _Record>.from(remote);
    for (var entry in local.entries) {
      var other = result[entry.key];
      if (other == null || entry.value.updatedAt > other.updatedAt) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  void prune(int cutoff) {
    _pruneMap(follows, cutoff);
    _pruneMap(tags, cutoff);
    _pruneMap(categories, cutoff);
    _pruneMap(blockWords, cutoff);
  }

  static void _pruneMap(Map<String, _Record> map, int cutoff) {
    map.removeWhere((_, record) => record.deleted && record.updatedAt < cutoff);
  }

  bool sameAs(_SyncState other) =>
      _sameMap(follows, other.follows) &&
      _sameMap(tags, other.tags) &&
      _sameMap(categories, other.categories) &&
      _sameMap(blockWords, other.blockWords);

  static bool _sameMap(Map<String, _Record> a, Map<String, _Record> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var entry in a.entries) {
      var other = b[entry.key];
      if (other == null || !entry.value.sameAs(other)) {
        return false;
      }
    }
    return true;
  }

  /// 把合并结果写回本地
  Future<void> applyToLocal() async {
    var db = DBService.instance;
    var storage = LocalStorageService.instance;

    for (var entry in follows.entries) {
      var record = entry.value;
      var current = db.followBox.get(entry.key);
      if (record.deleted) {
        if (current != null) {
          await db.followBox.delete(entry.key);
        }
        continue;
      }
      var data = record.data;
      if (data == null) {
        continue;
      }
      if (current != null && mapEquals(current.toJson(), data)) {
        continue;
      }
      try {
        await db.followBox.put(entry.key, FollowUser.fromJson(data));
      } catch (e) {
        Log.logPrint(e);
      }
    }

    for (var entry in tags.entries) {
      var record = entry.value;
      var current = db.tagBox.get(entry.key);
      if (record.deleted) {
        if (current != null) {
          await db.tagBox.delete(entry.key);
        }
        continue;
      }
      var data = record.data;
      if (data == null) {
        continue;
      }
      if (current != null && mapEquals(current.toJson(), data)) {
        continue;
      }
      try {
        await db.tagBox.put(entry.key, FollowUserTag.fromJson(data));
      } catch (e) {
        Log.logPrint(e);
      }
    }

    for (var entry in blockWords.entries) {
      if (entry.value.deleted) {
        if (storage.shieldBox.containsKey(entry.key)) {
          await storage.shieldBox.delete(entry.key);
        }
      } else {
        await storage.shieldBox.put(entry.key, entry.key);
      }
    }

    await _writePinned(categories);
    _refreshMemoryState();
    EventBus.instance.emit(Constant.kUpdateFollow, 0);
    EventBus.instance.emit(Constant.kUpdatePinnedCategories, 0);
  }

  /// 从 settingsBox 读取固定分类（站点 -> 分类列表）
  static Map<String, Map<String, dynamic>> _readPinned() {
    var result = <String, Map<String, dynamic>>{};
    var raw = LocalStorageService.instance.getValue<String>(
      LocalStorageService.kPinnedCategories,
      "",
    );
    if (raw.trim().isEmpty) {
      return result;
    }
    try {
      var decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return result;
      }
      for (var site in decoded.entries) {
        if (site.value is! List) {
          continue;
        }
        for (var item in site.value as List) {
          if (item is! Map) {
            continue;
          }
          var map = Map<String, dynamic>.from(item);
          var key =
              "${site.key}|${map["parentId"] ?? ""}|${map["categoryId"] ?? ""}";
          result[key] = map;
        }
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return result;
  }

  /// 把逐项记录还原成「站点 -> 分类列表」并写回设置
  static Future<void> _writePinned(Map<String, _Record> records) async {
    var grouped = <String, List<Map<String, dynamic>>>{};
    for (var entry in records.entries) {
      if (entry.value.deleted) {
        continue;
      }
      var data = entry.value.data;
      if (data == null) {
        continue;
      }
      var siteId = entry.key.split("|").first;
      grouped.putIfAbsent(siteId, () => []).add(data);
    }
    var json = <String, dynamic>{};
    for (var entry in grouped.entries) {
      if (entry.value.isEmpty) {
        continue;
      }
      json[entry.key] = entry.value;
    }
    var storage = LocalStorageService.instance;
    var text = jsonEncode(json);
    // 内容没变化时不写盘，避免无意义地触发设置变更
    if (storage.getValue<String>(
          LocalStorageService.kPinnedCategories,
          "",
        ) ==
        text) {
      return;
    }
    await storage.setValue(
      LocalStorageService.kPinnedCategories,
      text,
    );
  }

  void _refreshMemoryState() {
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

  String _encodeString() => jsonEncode({
        "version": _syncFileVersion,
        "savedAt": DateTime.now().millisecondsSinceEpoch,
        "follows": _encodeMap(follows),
        "tags": _encodeMap(tags),
        "categories": _encodeMap(categories),
        "blockWords": _encodeMap(blockWords),
      });

  static Map<String, dynamic> _encodeMap(Map<String, _Record> map) => {
        for (var entry in map.entries) entry.key: entry.value.toJson(),
      };

  Uint8List encode() => utf8.encoder.convert(_encodeString());

  Future<void> save() async {
    await LocalStorageService.instance.setValue(
      LocalStorageService.kWebDavSyncState,
      _encodeString(),
    );
  }
}

/// 跨设备数据同步
///
/// 同步本地关注 / 关注标签 / 主页固定分类 / 弹幕屏蔽词到
/// `<WebDAV 地址>/simple_live_app/Sync_SimpleLive.json`，全平台共用一份。
/// 按条目合并：修改时间较新者生效，删除以墓碑记录传播。
class BackupSync {
  BackupSync._();

  static bool _running = false;

  /// 刚恢复的备份文件的修改时间：恢复出的数据以它为准，不覆盖云端较新记录
  static int? _restoreBasis;

  /// 恢复备份期间暂停（与调度器共用同一标记）
  static bool get paused => BackupScheduler.paused;

  static bool get running => _running;

  /// 记录恢复时间基准（在恢复完成、下一次同步前调用）
  static void markRestored(int basisMillis) {
    _restoreBasis = basisMillis;
  }

  /// 手动「立即同步」：不受自动同步开关、防抖与最小间隔限制
  static Future<BackupSyncResult> syncNow() async {
    if (paused) {
      return const BackupSyncResult.skipped("正在恢复备份，请稍后再试");
    }
    if (!BackupClient.instance.isConfigured) {
      return const BackupSyncResult.failure("请先在「备份同步」中配置 WebDAV 地址");
    }
    if (_running) {
      return const BackupSyncResult.skipped("同步进行中，请稍候");
    }
    return _sync(automatic: false);
  }

  /// 自动同步（受开关控制）
  static Future<BackupSyncResult> autoSync() async {
    if (!BackupScheduler.autoSyncEnabled) {
      return const BackupSyncResult.skipped();
    }
    if (_running) {
      return const BackupSyncResult.skipped("同步进行中，请稍候");
    }
    return _sync(automatic: true);
  }

  static Future<BackupSyncResult> _sync({required bool automatic}) async {
    var task = BackupTask(BackupTaskKind.sync, automatic: automatic);
    BackupTaskCenter.start(task);
    _running = true;
    try {
      return await BackupTaskLock.run(() async {
        BackupTaskCenter.begin(task);
        return await _perform(automatic: automatic);
      });
    } finally {
      _running = false;
      BackupTaskCenter.finish(task);
    }
  }

  static Future<BackupSyncResult> _perform({required bool automatic}) async {
    try {
      if (paused || (automatic && !BackupScheduler.autoSyncEnabled)) {
        return const BackupSyncResult.skipped();
      }
      var baseline = _SyncState.load();

      // 先拉取远端，再读取本机数据，避免下载期间的本机修改被旧快照覆盖
      var bytes = await BackupClient.instance.downloadIfExists(
        BackupClient.syncFileName,
      );
      if (paused || (automatic && !BackupScheduler.autoSyncEnabled)) {
        return const BackupSyncResult.skipped();
      }
      var remote = bytes == null ? null : _SyncState.decode(bytes);

      var now = DateTime.now().millisecondsSinceEpoch;
      var local = _SyncState.fromLocal(
        baseline,
        now: now,
        restoreBasis: _restoreBasis,
      );
      var merged = _SyncState.merge(local, remote);
      merged.prune(now - _tombstoneTtlMs);

      if (paused) {
        return const BackupSyncResult.skipped();
      }
      BackupScheduler.beginApplying();
      try {
        await merged.applyToLocal();
      } finally {
        BackupScheduler.endApplying();
      }

      await merged.save();

      if (remote == null || !merged.sameAs(remote)) {
        await BackupClient.instance.upload(
          merged.encode(),
          BackupClient.syncFileName,
        );
      }
      _restoreBasis = null;
      BackupScheduler.markSynced();
      return const BackupSyncResult.success();
    } catch (e) {
      Log.logPrint(e);
      return BackupSyncResult.failure(describeBackupError(e));
    }
  }
}

/// 自动备份 / 自动同步调度
///
/// - 冷启动后延迟一分钟各触发一次；
/// - 本地数据或设置变化后防抖 30 秒再执行，同步另有 5 分钟最小间隔；
/// - 与手动备份 / 同步共用串行锁，同一时间只有一个任务访问远端。
class BackupScheduler {
  BackupScheduler._();

  /// 冷启动后延迟
  static const appStartDelay = Duration(minutes: 1);

  /// 连续修改合并为一次任务
  static const debounce = Duration(seconds: 30);

  /// 两次同步之间的最小间隔
  static const minInterval = Duration(minutes: 5);

  /// 同步写回本地后忽略自身引发的变更事件
  static const ignoreWindow = Duration(seconds: 2);

  static bool _initialized = false;
  static bool _applying = false;
  static bool paused = false;
  static Timer? _backupTimer;
  static Timer? _syncTimer;
  static Timer? _startTimer;
  static DateTime? _lastSyncAt;
  static DateTime? _ignoreBefore;
  static final List<StreamSubscription<dynamic>> _subs = [];

  static bool get autoBackupEnabled => LocalStorageService.instance.getValue(
        LocalStorageService.kWebDavAutoBackup,
        true,
      );

  static bool get autoSyncEnabled => LocalStorageService.instance.getValue(
        LocalStorageService.kWebDavAutoSync,
        true,
      );

  static Future<void> setAutoBackup(bool value) async {
    await LocalStorageService.instance.setValue(
      LocalStorageService.kWebDavAutoBackup,
      value,
    );
    if (value) {
      scheduleBackup();
    }
  }

  static Future<void> setAutoSync(bool value) async {
    await LocalStorageService.instance.setValue(
      LocalStorageService.kWebDavAutoSync,
      value,
    );
    if (value) {
      scheduleSync(force: true);
    }
  }

  static void markSynced() {
    _lastSyncAt = DateTime.now();
  }

  static void beginApplying() {
    _applying = true;
  }

  static void endApplying() {
    _applying = false;
    _ignoreBefore = DateTime.now().add(ignoreWindow);
  }

  /// 启动调度：监听本地变化并安排冷启动后的首次任务
  static void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    try {
      var storage = LocalStorageService.instance;
      _subs.add(
        storage.settingsBox.watch().listen((event) {
          var key = "${event.key}";
          // 同步基线、WebDAV 配置与开关自身的变化不触发任务
          if (key == LocalStorageService.kWebDavSyncState ||
              key == LocalStorageService.kWebDAVUri ||
              key == LocalStorageService.kWebDAVUser ||
              key == LocalStorageService.kWebDAVPassword ||
              key == LocalStorageService.kWebDavAutoBackup ||
              key == LocalStorageService.kWebDavAutoSync) {
            return;
          }
          _onLocalChanged();
        }),
      );
      _subs.add(
        DBService.instance.followBox.watch().listen((_) => _onLocalChanged()),
      );
      _subs.add(
        DBService.instance.tagBox.watch().listen((_) => _onLocalChanged()),
      );
      _subs.add(
        storage.shieldBox.watch().listen((_) => _onLocalChanged()),
      );
    } catch (e) {
      Log.logPrint(e);
    }

    // 冷启动后串行执行一次自动备份、自动同步
    _startTimer?.cancel();
    _startTimer = Timer(appStartDelay, () async {
      await runAutoBackup();
      await runAutoSync();
    });
  }

  static void _onLocalChanged() {
    if (_applying) {
      return;
    }
    var ignoreBefore = _ignoreBefore;
    if (ignoreBefore != null && DateTime.now().isBefore(ignoreBefore)) {
      return;
    }
    scheduleBackup();
    scheduleSync();
  }

  /// 安排一次自动备份（防抖 30 秒）
  static void scheduleBackup() {
    if (paused || !autoBackupEnabled) {
      return;
    }
    _backupTimer?.cancel();
    _backupTimer = Timer(debounce, runAutoBackup);
  }

  /// 安排一次自动同步（防抖 30 秒 + 最小间隔 5 分钟）
  static void scheduleSync({bool force = false}) {
    if (paused || !autoSyncEnabled) {
      return;
    }
    var delay = debounce;
    var last = _lastSyncAt;
    if (!force && last != null) {
      var earliest = last.add(minInterval);
      var target = DateTime.now().add(delay);
      if (earliest.isAfter(target)) {
        delay = earliest.difference(DateTime.now());
      }
    }
    _syncTimer?.cancel();
    _syncTimer = Timer(delay, runAutoSync);
  }

  /// 执行一次自动备份（受开关与串行锁控制）
  static Future<void> runAutoBackup() async {
    _backupTimer = null;
    if (paused || !autoBackupEnabled) {
      return;
    }
    if (!BackupClient.instance.isConfigured) {
      return;
    }
    var task = const BackupTask(BackupTaskKind.backup, automatic: true);
    BackupTaskCenter.start(task);
    try {
      await BackupTaskLock.run(() async {
        BackupTaskCenter.begin(task);
        if (paused || !autoBackupEnabled) {
          return;
        }
        var bytes = BackupArchive.exportBytes();
        await BackupClient.instance.upload(
          bytes,
          BackupClient.autoBackupFileName,
        );
        SmartDialog.showToast("自动备份成功");
      });
    } catch (e) {
      Log.logPrint(e);
      showBackupFailure("自动备份失败", describeBackupError(e));
    } finally {
      BackupTaskCenter.finish(task);
    }
  }

  /// 执行一次自动同步
  static Future<void> runAutoSync() async {
    _syncTimer = null;
    if (paused || !autoSyncEnabled) {
      return;
    }
    if (!BackupClient.instance.isConfigured) {
      return;
    }
    var result = await BackupSync.autoSync();
    if (result.outcome == BackupSyncOutcome.success) {
      SmartDialog.showToast("自动同步成功");
    } else if (result.outcome == BackupSyncOutcome.failure) {
      showBackupFailure("自动同步失败", result.message ?? "未知错误");
    }
  }
}

/// 显示失败提示：有可用上下文时弹框（可重试），否则降级为 toast
void showBackupFailure(
  String title,
  String message, {
  Future<void> Function()? retry,
}) {
  var context = Get.context;
  if (context == null) {
    SmartDialog.showToast("$title：$message");
    return;
  }
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("知道了"),
        ),
        if (retry != null)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              retry();
            },
            child: const Text("重试"),
          ),
      ],
    ),
  );
}
