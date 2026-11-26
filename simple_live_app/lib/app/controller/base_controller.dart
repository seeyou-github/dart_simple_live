import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:simple_live_app/app/log.dart';

import 'package:flutter_easyrefresh/easy_refresh.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class BaseController extends GetxController {
  /// 加载中，更新页面
  var pageLoadding = false.obs;

  /// 加载中,不会更新页面
  var loadding = false;

  /// 空白页面
  var pageEmpty = false.obs;

  /// 页面错误
  var pageError = false.obs;

  /// 未登录
  var notLogin = false.obs;

  /// 错误信息
  var errorMsg = "".obs;

  /// 显示错误
  /// * [msg] 错误信息
  /// * [showPageError] 显示页面错误
  /// * 只在第一页加载错误时showPageError=true，后续页加载错误时使用Toast弹出通知
  void handleError(
    Object exception, {
    bool showPageError = false,
    StackTrace? stackTrace,
  }) {
    final trace = stackTrace ?? StackTrace.current;
    Log.e(exception.toString(), trace);
    var msg = exceptionToString(exception, trace);

    if (showPageError) {
      pageError.value = true;
      errorMsg.value = msg;
    } else {
      SmartDialog.showToast(exceptionToString(msg));
    }
  }

  String exceptionToString(Object exception, [StackTrace? stackTrace]) {
    final text = exception.toString().replaceAll("Exception:", "").trim();
    if (_hasDiagnosticFields(text)) {
      return text;
    }
    final lines = <String>[
      _summaryForException(exception),
      '',
      'Exception Type: ${exception.runtimeType}',
      'Exception: $text',
    ];
    if (stackTrace != null) {
      lines
        ..add('')
        ..add('Stack Trace:')
        ..add(stackTrace.toString());
    }
    return lines.join('\n');
  }

  bool _hasDiagnosticFields(String text) {
    return text.contains('\nURL: ') ||
        text.contains('\nResponse Body: ') ||
        text.contains('\nStack Trace:');
  }

  String _summaryForException(Object exception) {
    final text = exception.toString();
    if (text.contains('SocketException') ||
        text.contains('Connection') ||
        text.contains('connection')) {
      return '网络连接失败';
    }
    if (text.contains('Timeout') || text.contains('timed out')) {
      return '请求超时';
    }
    if (text.contains('FormatException')) {
      return '数据格式解析失败';
    }
    if (text.contains('NoSuchMethodError') || text.contains('null')) {
      return '接口返回数据结构异常';
    }
    return '发生异常';
  }

  void onLogin() {}
  void onLogout() {}
}

class BasePageController<T> extends BaseController {
  static const Duration refreshCooldown = Duration(seconds: 2);
  final ScrollController scrollController = ScrollController();
  final EasyRefreshController easyRefreshController = EasyRefreshController();
  int currentPage = 1;
  int count = 0;
  int maxPage = 0;
  int pageSize = 24;
  var canLoadMore = false.obs;
  var list = <T>[].obs;
  DateTime? _lastRefreshAt;

  Future refreshData() async {
    final now = DateTime.now();
    final lastRefreshAt = _lastRefreshAt;
    if (lastRefreshAt != null &&
        now.difference(lastRefreshAt) < refreshCooldown) {
      SmartDialog.showToast("刷新太频繁，请稍后再试");
      return;
    }
    _lastRefreshAt = now;
    currentPage = 1;
    list.value = [];
    await loadData();
  }

  Future loadData() async {
    try {
      if (loadding) return;
      loadding = true;
      pageError.value = false;
      pageEmpty.value = false;
      notLogin.value = false;
      // 锁定本次页码，避免 await 期间刷新操作改动 currentPage 导致重复加载。
      final page = currentPage;
      pageLoadding.value = page == 1;

      var result = await getData(page, pageSize);
      // 先赋值：首页始终替换列表，避免残留旧数据造成重复。
      if (page == 1) {
        list.value = result;
      } else {
        list.addAll(result);
      }
      // 是否可以加载更多
      if (result.isNotEmpty) {
        currentPage = page + 1;
        canLoadMore.value = true;
        pageEmpty.value = false;
      } else {
        canLoadMore.value = false;
        if (page == 1 && result.isEmpty) {
          pageEmpty.value = true;
        }
      }
    } catch (e, stackTrace) {
      handleError(e, showPageError: currentPage == 1, stackTrace: stackTrace);
    } finally {
      loadding = false;
      pageLoadding.value = false;
    }
  }

  Future<List<T>> getData(int page, int pageSize) async {
    return [];
  }

  void scrollToTopOrRefresh() {
    if (scrollController.offset > 0) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.linear,
      );
    } else {
      easyRefreshController.callRefresh();
    }
  }
}
