import 'dart:async';

import 'package:flutter/foundation.dart';

/// 备份 / 同步任务类型
enum BackupTaskKind { backup, sync, restore }

/// 一次备份或同步任务（执行中或排队等待中）
class BackupTask {
  const BackupTask(this.kind, {this.automatic = false});

  final BackupTaskKind kind;

  /// 是否由自动备份 / 自动同步触发
  final bool automatic;

  String get label {
    switch (kind) {
      case BackupTaskKind.backup:
        return automatic ? "正在自动备份…" : "正在备份…";
      case BackupTaskKind.restore:
        return "正在恢复…";
      case BackupTaskKind.sync:
        return automatic ? "正在自动同步…" : "正在同步…";
    }
  }
}

/// 全局备份 / 同步任务状态
///
/// 任务本身在静态服务层执行，与页面生命周期无关；这里只维护界面需要的
/// 运行状态，供按钮禁用与页面底部进度提示使用。
class BackupTaskCenter {
  BackupTaskCenter._();

  /// 所有任务（含排队等待锁的任务），状态变化时通知
  static final ValueNotifier<List<BackupTask>> active = ValueNotifier(
    const <BackupTask>[],
  );

  static final List<BackupTask> _tasks = [];

  static BackupTask? _executing;

  /// 当前真正在执行的任务（排队等待的不算）
  static BackupTask? get executing => _executing;

  /// 是否有该类型的任务在排队或执行
  static bool isRunning(BackupTaskKind kind) =>
      _tasks.any((task) => task.kind == kind);

  static void start(BackupTask task) {
    _tasks.add(task);
    _notify();
  }

  /// 任务获取到串行锁、开始真正执行
  static void begin(BackupTask task) {
    _executing = task;
    _notify();
  }

  static void finish(BackupTask task) {
    _tasks.remove(task);
    if (identical(_executing, task)) {
      _executing = null;
    }
    _notify();
  }

  static void _notify() {
    active.value = List<BackupTask>.unmodifiable(_tasks);
  }
}

/// 备份 / 同步任务串行锁
///
/// 自动备份、自动同步、手动备份、手动同步共用同一把锁：同一时间只允许
/// 一个任务访问远端，后到的任务排队等待。
class BackupTaskLock {
  BackupTaskLock._();

  static Future<void> _tail = Future<void>.value();

  static final Object _zoneKey = Object();

  static Future<T> run<T>(Future<T> Function() action) async {
    if (Zone.current[_zoneKey] == true) {
      throw StateError("BackupTaskLock 不支持重入");
    }
    var gate = Completer<void>();
    var previous = _tail;
    _tail = gate.future;
    try {
      return await runZoned(
        () async {
          await previous;
          return await action();
        },
        zoneValues: {_zoneKey: true},
      );
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }
}
