import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:simple_live_app/app/app_style.dart';

class AppErrorWidget extends StatelessWidget {
  final Function()? onRefresh;
  final String errorMsg;
  const AppErrorWidget({this.errorMsg = "", this.onRefresh, Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final detail = _detail;
    return Center(
      child: Padding(
        padding: AppStyle.edgeInsetsA12,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LottieBuilder.asset(
                'assets/lotties/error.json',
                width: 180,
                repeat: false,
              ),
              Text(
                summary,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 360),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    detail,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _summary {
    final text = errorMsg.trim();
    if (text.isEmpty) {
      return '发生异常';
    }
    return text.split(RegExp(r'\r?\n')).first.trim();
  }

  String get _detail {
    final text = errorMsg.trim();
    if (text.isEmpty) {
      return '没有错误详情。';
    }
    return text;
  }
}
