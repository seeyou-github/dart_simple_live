import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/services/webdav/backup_archive.dart';
import 'package:simple_live_app/services/webdav/backup_client.dart';
import 'package:simple_live_app/services/webdav/backup_sync.dart';
import 'package:simple_live_app/services/webdav/backup_task.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

/// 备份同步（WebDAV）
///
/// 布局：WebDAV 配置 / 自动备份 / 导入导出。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final TextEditingController _uriCtr;
  late final TextEditingController _userCtr;
  late final TextEditingController _passwordCtr;
  bool _obscure = true;
  bool _autoBackup = true;
  bool _autoSync = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _uriCtr = TextEditingController(text: BackupClient.instance.uri);
    _userCtr = TextEditingController(text: BackupClient.instance.user);
    _passwordCtr = TextEditingController(text: BackupClient.instance.password);
    _autoBackup = BackupScheduler.autoBackupEnabled;
    _autoSync = BackupScheduler.autoSyncEnabled;
  }

  @override
  void dispose() {
    _uriCtr.dispose();
    _userCtr.dispose();
    _passwordCtr.dispose();
    super.dispose();
  }

  /// 保存配置。
  ///
  /// 配置发生变化（首次填写 / 换设备）时安排一次同步：新设备接入时
  /// 先把云端已有的关注、标签、固定分类、屏蔽词合并进来，再向下推进。
  Future<void> _saveConfig({bool scheduleSync = true}) async {
    var changed = await BackupClient.instance.saveConfig(
      uri: _uriCtr.text,
      user: _userCtr.text,
      password: _passwordCtr.text,
    );
    if (!scheduleSync || !changed) {
      return;
    }
    if (BackupClient.instance.isConfigured) {
      BackupScheduler.scheduleSync(force: true);
    }
  }

  /// 手动备份到云端
  Future<void> _backup() async {
    if (_busy) {
      return;
    }
    await _saveConfig();
    if (!BackupClient.instance.isConfigured) {
      SmartDialog.showToast("请先填写并保存 WebDAV 地址");
      return;
    }
    _busy = true;
    var task = const BackupTask(BackupTaskKind.backup);
    BackupTaskCenter.start(task);
    try {
      await BackupTaskLock.run(() async {
        BackupTaskCenter.begin(task);
        var bytes = BackupArchive.exportBytes();
        await BackupClient.instance.upload(
          bytes,
          BackupClient.buildBackupFileName(),
        );
      });
      SmartDialog.showToast("备份成功");
    } catch (e) {
      showBackupFailure("备份失败", describeBackupError(e), retry: _backup);
    } finally {
      BackupTaskCenter.finish(task);
      _busy = false;
    }
  }

  /// 从云端备份恢复
  Future<void> _restore() async {
    if (_busy) {
      return;
    }
    await _saveConfig();
    if (!BackupClient.instance.isConfigured) {
      SmartDialog.showToast("请先填写并保存 WebDAV 地址");
      return;
    }
    _busy = true;
    List<BackupFile> files;
    try {
      files = await BackupClient.instance.listBackups();
    } catch (e) {
      _busy = false;
      showBackupFailure(
        "读取备份列表失败",
        describeBackupError(e),
        retry: _restore,
      );
      return;
    }
    _busy = false;
    if (!mounted) {
      return;
    }
    if (files.isEmpty) {
      SmartDialog.showToast(
        "云端暂无 ${BackupClient.platformLabel} 平台的备份文件",
      );
      return;
    }
    var picked = await _pickBackup(files);
    if (picked == null) {
      return;
    }
    if (!await _confirmRestore(picked.name)) {
      return;
    }

    _busy = true;
    // 恢复期间暂停自动备份 / 同步，避免把刚恢复的数据又覆盖回去
    BackupScheduler.paused = true;
    var task = const BackupTask(BackupTaskKind.restore);
    BackupTaskCenter.start(task);
    try {
      await BackupTaskLock.run(() async {
        BackupTaskCenter.begin(task);
        var bytes = await BackupClient.instance.download(picked.name);
        var result = await BackupArchive.importBytes(bytes);
        // 恢复出的数据以备份生成时间为基准，避免覆盖云端较新的记录
        var basis =
            result.basisMillis ?? picked.modified?.millisecondsSinceEpoch ?? 0;
        if (basis > 0) {
          BackupSync.markRestored(basis);
        }
        var note = result.note;
        SmartDialog.showToast(
          note == null ? "恢复成功" : "恢复成功，但$note",
        );
      });
    } catch (e) {
      showBackupFailure("恢复失败", describeBackupError(e));
    } finally {
      BackupTaskCenter.finish(task);
      BackupScheduler.paused = false;
      _busy = false;
      // 恢复后本地数据已变化，安排一次同步与备份把结果推到云端
      BackupScheduler.scheduleSync(force: true);
      BackupScheduler.scheduleBackup();
      if (mounted) {
        setState(() {});
      }
    }
  }

  /// 立即同步
  Future<void> _syncNow() async {
    // 这里马上就会同步，不再另外排队
    await _saveConfig(scheduleSync: false);
    var result = await BackupSync.syncNow();
    switch (result.outcome) {
      case BackupSyncOutcome.success:
        SmartDialog.showToast("同步成功");
        break;
      case BackupSyncOutcome.failure:
        showBackupFailure(
          "同步失败",
          result.message ?? "未知错误",
          retry: _syncNow,
        );
        break;
      case BackupSyncOutcome.skipped:
        SmartDialog.showToast(result.message ?? "同步进行中，请稍候");
        break;
    }
  }

  /// 一键导出到本机文件
  Future<void> _export() async {
    try {
      var path = await BackupArchive.exportToFile();
      if (path == null) {
        SmartDialog.showToast("已取消");
        return;
      }
      SmartDialog.showToast("已导出到 $path");
    } catch (e) {
      showBackupFailure("导出失败", "$e");
    }
  }

  /// 一键从本机文件导入（合并）
  Future<void> _import() async {
    if (!await Get.dialog<bool>(
          AlertDialog(
            title: const Text("导入备份"),
            content: const Text(
              "将合并导入备份中的关注、关注标签、固定分类与屏蔽词"
              "（不会删除本地已有条目），设置与账号按备份覆盖。"
              "播放历史不会被导入。",
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(result: false),
                child: const Text("取消"),
              ),
              TextButton(
                onPressed: () => Get.back(result: true),
                child: const Text("导入"),
              ),
            ],
          ),
        ) ??
        false) {
      return;
    }
    try {
      var result = await BackupArchive.importFromFile();
      if (!result.applied) {
        return;
      }
      // 导入的数据以备份生成时间为基准：紧接着接入同步时，
      // 云端更新的记录仍然生效，不会被刚导入的旧数据覆盖
      var basis = result.basisMillis;
      if (basis != null && basis > 0) {
        BackupSync.markRestored(basis);
      }
      BackupScheduler.scheduleSync(force: true);
      BackupScheduler.scheduleBackup();
      SmartDialog.showToast(
        result.note == null ? "导入成功" : "导入成功，但${result.note}",
      );
    } catch (e) {
      showBackupFailure("导入失败", "$e");
    }
  }

  Future<BackupFile?> _pickBackup(List<BackupFile> files) async {
    return Get.dialog<BackupFile>(
      AlertDialog(
        title: Text("选择备份（${BackupClient.platformLabel}）"),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  "仅显示当前平台（${BackupClient.platformLabel}）的备份文件；"
                  "其它平台的备份需先导出，再用「一键导入」",
                  style: Get.textTheme.bodySmall?.copyWith(
                    color: Get.theme.colorScheme.outline,
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    var file = files[index];
                    return ListTile(
                      leading: const Icon(Icons.archive_outlined),
                      title: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        "${_formatTime(file.modified)} · "
                        "${_formatSize(file.size)}",
                      ),
                      onTap: () => Get.back(result: file),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text("取消"),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmRestore(String name) async {
    return await Get.dialog<bool>(
          AlertDialog(
            title: const Text("恢复备份"),
            content: Text(
              "将用「$name」中的设置、账号更新当前数据；"
              "其中本地关注、关注标签、主页固定分类、弹幕屏蔽词为合并导入"
              "（不会删除现有条目）。此操作不可撤销。",
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(result: false),
                child: const Text("取消"),
              ),
              TextButton(
                onPressed: () => Get.back(result: true),
                child: const Text("恢复"),
              ),
            ],
          ),
        ) ??
        false;
  }

  String _formatTime(DateTime? time) {
    if (time == null) {
      return "--";
    }
    String two(int v) => v.toString().padLeft(2, "0");
    return "${time.year}-${two(time.month)}-${two(time.day)} "
        "${two(time.hour)}:${two(time.minute)}";
  }

  String _formatSize(int size) {
    if (size <= 0) {
      return "0 B";
    }
    if (size < 1024) {
      return "$size B";
    }
    if (size < 1024 * 1024) {
      return "${(size / 1024).toStringAsFixed(1)} KB";
    }
    return "${(size / 1024 / 1024).toStringAsFixed(1)} MB";
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 6),
            child: Text(
              title,
              style: Get.textTheme.titleSmall?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Get.theme.colorScheme.primary,
              ),
            ),
          ),
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("备份还原"),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _section("WebDAV 配置", [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                children: [
                  TextField(
                    controller: _uriCtr,
                    decoration: const InputDecoration(
                      labelText: "地址",
                      hintText: "https://dav.example.com/dav/App_Sync",
                      helperText: "备份将保存在该地址下的 simple_live_app 目录",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _userCtr,
                    decoration: const InputDecoration(
                      labelText: "用户",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordCtr,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: "密码",
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            _obscure = !_obscure;
                          });
                        },
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ValueListenableBuilder<List<BackupTask>>(
                    valueListenable: BackupTaskCenter.active,
                    builder: (context, _, __) {
                      var busy =
                          BackupTaskCenter.isRunning(BackupTaskKind.backup);
                      var restoring =
                          BackupTaskCenter.isRunning(BackupTaskKind.restore);
                      return Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: AppStyle.radius8,
                                ),
                              ),
                              onPressed: busy ? null : _backup,
                              child: Text(busy ? "正在备份" : "备份设置"),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: AppStyle.radius8,
                                ),
                              ),
                              onPressed: restoring ? null : _restore,
                              child: Text(restoring ? "正在恢复" : "恢复设置"),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "备份按平台区分：当前为 ${BackupClient.platformLabel}，"
                    "文件名带 ${BackupClient.platformPrefix} 前缀；"
                    "恢复时只显示当前平台的备份",
                    style: Get.textTheme.bodySmall?.copyWith(
                      color: Get.theme.colorScheme.outline,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ]),
          _section("自动备份", [
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: const Text("自动备份"),
              subtitle: const Text(
                "设置变更或本地关注 / 关注标签 / 弹幕屏蔽词 / 固定的分类 变化后自动备份",
              ),
              value: _autoBackup,
              onChanged: (value) async {
                setState(() {
                  _autoBackup = value;
                });
                await BackupScheduler.setAutoBackup(value);
                if (value && !BackupClient.instance.isConfigured) {
                  SmartDialog.showToast("请先填写并保存 WebDAV 地址");
                }
              },
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: const Text("自动同步"),
              subtitle: const Text(
                "在设备间同步本地关注 / 关注标签 / 固定的分类 / 弹幕屏蔽词",
              ),
              value: _autoSync,
              onChanged: (value) async {
                setState(() {
                  _autoSync = value;
                });
                await BackupScheduler.setAutoSync(value);
                if (value && !BackupClient.instance.isConfigured) {
                  SmartDialog.showToast("请先填写并保存 WebDAV 地址");
                }
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: ValueListenableBuilder<List<BackupTask>>(
                  valueListenable: BackupTaskCenter.active,
                  builder: (context, _, __) {
                    var syncing =
                        BackupTaskCenter.isRunning(BackupTaskKind.sync);
                    return FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: AppStyle.radius8,
                        ),
                      ),
                      onPressed: syncing ? null : _syncNow,
                      icon: const Icon(Icons.sync, size: 18),
                      label: Text(syncing ? "正在同步" : "立即同步"),
                    );
                  },
                ),
              ),
            ),
          ]),
          _section("导入导出", [
            ListTile(
              leading: const Icon(Remix.upload_2_line),
              title: const Text("一键导出"),
              subtitle: const Text("导出为本地 zip 文件，可用于手动迁移"),
              onTap: _export,
            ),
            AppStyle.divider,
            ListTile(
              leading: const Icon(Remix.download_2_line),
              title: const Text("一键导入"),
              subtitle: const Text("从本地 zip 文件合并导入"),
              onTap: _import,
            ),
          ]),
        ],
      ),
    );
  }
}
