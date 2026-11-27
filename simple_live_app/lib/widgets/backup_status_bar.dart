import 'package:flutter/material.dart';
import 'package:simple_live_app/services/webdav/backup_task.dart';

/// 备份 / 同步任务进行中的底部提示条
///
/// 由 [BackupTaskCenter] 驱动：任务开始真正执行时展开并显示进度动画，
/// 任务结束后收起。
class BackupStatusBar extends StatelessWidget {
  const BackupStatusBar({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<BackupTask>>(
      valueListenable: BackupTaskCenter.active,
      builder: (context, _, __) {
        var task = BackupTaskCenter.executing;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => SizeTransition(
            sizeFactor: animation,
            axisAlignment: 1,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: task == null
              ? const SizedBox.shrink(key: ValueKey("backupStatusEmpty"))
              : _TaskBar(task: task, key: ValueKey(task)),
        );
      },
    );
  }
}

class _TaskBar extends StatelessWidget {
  const _TaskBar({super.key, required this.task});

  final BackupTask task;

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var colorScheme = theme.colorScheme;
    return Material(
      color: colorScheme.secondaryContainer,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  task.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
