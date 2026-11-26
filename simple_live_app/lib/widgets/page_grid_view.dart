import 'dart:io';

import 'package:flutter/material.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';
import 'package:simple_live_app/widgets/status/app_error_widget.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_easyrefresh/easy_refresh.dart';
import 'package:get/get.dart';

class PageGridView extends StatelessWidget {
  final BasePageController pageController;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets? padding;
  final bool firstRefresh;
  final Function()? onLoginSuccess;
  final bool showPageLoadding;
  final double crossAxisSpacing, mainAxisSpacing;
  final int crossAxisCount;
  final bool showPCRefreshButton;

  /// 是否在列表末尾显示"加载更多"按钮（无分页的列表传 false）
  final bool showLoadMore;
  const PageGridView({
    required this.itemBuilder,
    required this.pageController,
    this.padding,
    this.firstRefresh = false,
    this.showPageLoadding = false,
    this.onLoginSuccess,
    this.crossAxisSpacing = 0.0,
    this.mainAxisSpacing = 0.0,
    this.showPCRefreshButton = true,
    this.showLoadMore = true,
    required this.crossAxisCount,
    Key? key,
  }) : super(key: key);

  bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 列表末尾的"加载更多"：作为滚动内容的一部分，只有滑动到底部才会出现
  Widget buildLoadMore(BuildContext context) {
    var visible = showLoadMore &&
        _desktop &&
        pageController.canLoadMore.value &&
        !pageController.pageLoadding.value &&
        !pageController.pageEmpty.value;
    if (!visible) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Center(
        child: TextButton(
          onPressed: pageController.loadData,
          child: const Text("加载更多"),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Stack(
        children: [
          EasyRefresh(
            header: MaterialHeader(
              completeDuration: const Duration(milliseconds: 400),
            ),
            footer: MaterialFooter(
              completeDuration: const Duration(milliseconds: 400),
            ),
            scrollController: pageController.scrollController,
            controller: pageController.easyRefreshController,
            firstRefresh: firstRefresh,
            onLoad: pageController.loadData,
            onRefresh: pageController.refreshData,
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: padding ?? EdgeInsets.zero,
                  sliver: SliverMasonryGrid.count(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: crossAxisSpacing,
                    mainAxisSpacing: mainAxisSpacing,
                    childCount: pageController.list.length,
                    itemBuilder: itemBuilder,
                  ),
                ),
                SliverToBoxAdapter(
                  child: buildLoadMore(context),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 12,
            right: 12,
            child: // 刷新按钮
                Visibility(
              visible: _desktop &&
                  pageController.canLoadMore.value &&
                  !pageController.pageLoadding.value &&
                  !pageController.pageEmpty.value &&
                  showPCRefreshButton,
              child: Center(
                child: IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: Get.theme.cardColor.withAlpha(200),
                    elevation: 4,
                  ),
                  onPressed: () {
                    pageController.refreshData();
                  },
                  icon: const Icon(Icons.refresh),
                ),
              ),
            ),
          ),
          Offstage(
            offstage: !pageController.pageEmpty.value,
            child: AppEmptyWidget(
              onRefresh: () => pageController.refreshData(),
            ),
          ),
          Offstage(
            offstage: !(showPageLoadding && pageController.pageLoadding.value),
            child: const AppLoaddingWidget(),
          ),
          Offstage(
            offstage: !pageController.pageError.value,
            child: AppErrorWidget(
              errorMsg: pageController.errorMsg.value,
              onRefresh: () => pageController.refreshData(),
            ),
          ),
        ],
      ),
    );
  }
}
