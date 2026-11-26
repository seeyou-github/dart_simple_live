import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/home/home_list_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/widgets/default_category_icon.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 已固定到主页分类栏的分类。
class PinnedCategory {
  final String parentId;
  final String categoryId;
  final String name;
  final String? pic;

  const PinnedCategory({
    required this.parentId,
    required this.categoryId,
    required this.name,
    this.pic,
  });

  Map<String, dynamic> toJson() {
    return {
      "parentId": parentId,
      "categoryId": categoryId,
      "name": name,
      if (pic != null) "pic": pic,
    };
  }

  factory PinnedCategory.fromJson(Map<String, dynamic> json) {
    return PinnedCategory(
      parentId: json["parentId"]?.toString() ?? "",
      categoryId: json["categoryId"]?.toString() ?? "",
      name: json["name"]?.toString() ?? "",
      pic: json["pic"]?.toString(),
    );
  }

  LiveSubCategory toSubCategory() {
    return LiveSubCategory(
      id: categoryId,
      name: name,
      parentId: parentId,
      pic: pic,
    );
  }
}

/// 固定分类的本地存储：按站点存一份 JSON。
class PinnedCategoryStore {
  /// 读取原始存储（站点 id -> 分类列表的 JSON）
  static Map<String, dynamic> _readAll() {
    try {
      var raw = LocalStorageService.instance.getValue<String>(
        LocalStorageService.kPinnedCategories,
        "",
      );
      if (raw.trim().isEmpty) {
        return {};
      }
      var decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return {};
      }
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      return {};
    }
  }

  static List<PinnedCategory> _parse(dynamic list) {
    if (list is! List) {
      return [];
    }
    return list
        .whereType<Map>()
        .map((e) => PinnedCategory.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.categoryId.isNotEmpty)
        .toList();
  }

  static Future<void> _writeAll(Map<String, dynamic> all) async {
    await LocalStorageService.instance.setValue(
      LocalStorageService.kPinnedCategories,
      jsonEncode(all),
    );
  }

  static List<PinnedCategory> load(String siteId) {
    return _parse(_readAll()[siteId]);
  }

  static Future<void> save(String siteId, List<PinnedCategory> list) async {
    var all = _readAll();
    all[siteId] = list.map((e) => e.toJson()).toList();
    await _writeAll(all);
  }

  /// 读取所有站点的固定分类（用于备份 / 同步）
  static Map<String, List<PinnedCategory>> loadAll() {
    var all = _readAll();
    var result = <String, List<PinnedCategory>>{};
    for (var entry in all.entries) {
      var list = _parse(entry.value);
      if (list.isNotEmpty) {
        result[entry.key] = list;
      }
    }
    return result;
  }

  /// 写入所有站点的固定分类。
  /// [overlay] 为 true 时覆盖本地；否则按站点合并去重。
  static Future<void> saveAll(
    Map<String, List<PinnedCategory>> data, {
    bool overlay = false,
  }) async {
    var all = overlay ? <String, dynamic>{} : _readAll();
    for (var entry in data.entries) {
      var list = entry.value;
      if (overlay) {
        all[entry.key] = list.map((e) => e.toJson()).toList();
        continue;
      }
      var merged = <PinnedCategory>[..._parse(all[entry.key])];
      for (var item in list) {
        var exists = merged.any(
          (e) => e.categoryId == item.categoryId && e.parentId == item.parentId,
        );
        if (!exists) {
          merged.add(item);
        }
      }
      all[entry.key] = merged.map((e) => e.toJson()).toList();
    }
    await _writeAll(all);
  }
}

/// 主页分类栏：展示用户固定的分类，右侧固定"更多分类"按钮。
class HomeCategoryBar extends StatefulWidget {
  final String tag;

  const HomeCategoryBar({required this.tag, Key? key}) : super(key: key);

  @override
  State<HomeCategoryBar> createState() => _HomeCategoryBarState();
}

class _HomeCategoryBarState extends State<HomeCategoryBar> {
  HomeListController get controller =>
      Get.find<HomeListController>(tag: widget.tag);
  List<PinnedCategory> pinned = [];
  StreamSubscription? _syncSubscription;

  @override
  void initState() {
    super.initState();
    pinned = PinnedCategoryStore.load(controller.site.id);
    // 备份恢复 / 设备同步后刷新分类栏
    _syncSubscription = EventBus.instance.listen(
      Constant.kUpdatePinnedCategories,
      (_) {
        if (!mounted) {
          return;
        }
        setState(() {
          pinned = PinnedCategoryStore.load(controller.site.id);
        });
      },
    );
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
    super.dispose();
  }

  Future<void> openPicker() async {
    await showCategoryPicker(
      context: context,
      site: controller.site,
      pinned: pinned,
      onPinnedChanged: (list) {
        if (!mounted) {
          return;
        }
        setState(() {
          pinned = list;
        });
      },
      onSelect: (category) {
        controller.selectCategory(category);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    var colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: ScrollConfiguration(
              // 桌面端允许鼠标按住拖动分类栏
              behavior: const _CategoryScrollBehavior(),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 12),
                // 索引 0 固定为"主页"，其后为用户固定的分类
                itemCount: pinned.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _buildHomeChip(context);
                  }
                  return _buildChip(context, pinned[index - 1]);
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 12),
            child: TextButton.icon(
              onPressed: openPicker,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: colorScheme.primary,
              ),
              icon: const Icon(Icons.apps_rounded, size: 16),
              label: const Text(
                "更多分类",
                style: TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分类栏第一个固定项"主页"：显示默认推荐直播列表，不可取消固定
  Widget _buildHomeChip(BuildContext context) {
    var colorScheme = Theme.of(context).colorScheme;
    return Obx(() {
      // 未选中任何分类即为"主页"
      var isSelected = controller.selectedCategory.value == null;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: controller.selectHome,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? colorScheme.primary.withAlpha(38)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.home_rounded,
                  size: 15,
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  "主页",
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: isSelected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildChip(BuildContext context, PinnedCategory item) {
    var colorScheme = Theme.of(context).colorScheme;
    return Obx(() {
      var selected = controller.selectedCategory.value;
      var isSelected = selected != null &&
          selected.id == item.categoryId &&
          selected.parentId == item.parentId;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () => controller.toggleCategory(item.toSubCategory()),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? colorScheme.primary.withAlpha(38)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// 分类栏横向滚动行为：把鼠标、触控板也加入拖动设备。
class _CategoryScrollBehavior extends MaterialScrollBehavior {
  const _CategoryScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.unknown,
      };
}

/// 弹出分类选择弹框（从底部向上）。
Future<void> showCategoryPicker({
  required BuildContext context,
  required Site site,
  required List<PinnedCategory> pinned,
  required ValueChanged<List<PinnedCategory>> onPinnedChanged,
  required ValueChanged<LiveSubCategory> onSelect,
}) async {
  var size = MediaQuery.sizeOf(context);
  // Windows：宽 80%、高 70%；Android：宽 100%、高 70%
  var width = Platform.isAndroid ? size.width : size.width * 0.8;
  var height = size.height * 0.7;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    constraints: BoxConstraints(
      minWidth: width,
      maxWidth: width,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SizedBox(
        width: width,
        height: height,
        child: _CategoryPickerSheet(
          site: site,
          pinned: List<PinnedCategory>.from(pinned),
          onPinnedChanged: onPinnedChanged,
          onSelect: onSelect,
        ),
      );
    },
  );
}

class _CategoryPickerSheet extends StatefulWidget {
  final Site site;
  final List<PinnedCategory> pinned;
  final ValueChanged<List<PinnedCategory>> onPinnedChanged;
  final ValueChanged<LiveSubCategory> onSelect;

  const _CategoryPickerSheet({
    required this.site,
    required this.pinned,
    required this.onPinnedChanged,
    required this.onSelect,
  });

  @override
  State<_CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<_CategoryPickerSheet> {
  late Future<List<LiveCategory>> _future;
  late List<PinnedCategory> _pinned;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _pinned = List<PinnedCategory>.from(widget.pinned);
    _future = widget.site.liveSite.getCategores();
  }

  bool _isPinned(LiveSubCategory item) {
    return _pinned.any(
      (e) => e.categoryId == item.id && e.parentId == item.parentId,
    );
  }

  Future<void> _togglePin(LiveSubCategory item) async {
    var exists = _isPinned(item);
    setState(() {
      if (exists) {
        _pinned.removeWhere(
          (e) => e.categoryId == item.id && e.parentId == item.parentId,
        );
      } else {
        _pinned.add(
          PinnedCategory(
            parentId: item.parentId,
            categoryId: item.id,
            name: item.name,
            pic: item.pic,
          ),
        );
      }
    });
    await PinnedCategoryStore.save(widget.site.id, _pinned);
    widget.onPinnedChanged(_pinned);
  }

  @override
  Widget build(BuildContext context) {
    var colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              const Text(
                "更多分类",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "长按图标固定到分类栏",
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<List<LiveCategory>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text("分类加载失败"),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _future = widget.site.liveSite.getCategores();
                          });
                        },
                        child: const Text("重试"),
                      ),
                    ],
                  ),
                );
              }
              return _buildContent(context, snapshot.data!);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, List<LiveCategory> categories) {
    // 只有唯一卡片的分类合并成"单个分类"，避免一个图标占一行
    var singles = <LiveCategory>[];
    var normals = <LiveCategory>[];
    for (var category in categories) {
      if (category.children.length <= 1) {
        singles.add(category);
      } else {
        normals.add(category);
      }
    }

    var children = <Widget>[];
    if (singles.isNotEmpty) {
      var items = singles
          .map(
            (e) => e.children.isNotEmpty
                ? e.children.first
                : LiveSubCategory(
                    id: e.id,
                    name: e.name,
                    parentId: e.id,
                  ),
          )
          .toList();
      children.add(_buildGroup(context, "单个分类", items));
    }
    for (var category in normals) {
      children.add(_buildGroup(context, category.name, category.children));
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: children,
    );
  }

  Widget _buildGroup(
    BuildContext context,
    String title,
    List<LiveSubCategory> items,
  ) {
    const itemWidth = 76.0;
    const spacing = 8.0;
    var isExpanded = _expanded.contains(title);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              var columns = max(1, (constraints.maxWidth / itemWidth).floor());
              var hasMore = items.length > columns;
              var display = (!hasMore || isExpanded)
                  ? items
                  : items.take(columns - 1).toList();
              return Wrap(
                spacing: spacing,
                runSpacing: 12,
                children: [
                  for (var item in display) _buildItem(context, item),
                  if (hasMore && !isExpanded)
                    _buildShowAll(context, () {
                      setState(() {
                        _expanded.add(title);
                      });
                    }),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, LiveSubCategory item) {
    var colorScheme = Theme.of(context).colorScheme;
    var isPinned = _isPinned(item);
    var pic = (item.pic ?? "").trim();
    var fallback = DefaultCategoryIcon(categoryName: item.name, size: 40);

    return GestureDetector(
      onTap: () {
        widget.onSelect(item);
        Navigator.of(context).pop();
      },
      onLongPress: () => _togglePin(item),
      child: SizedBox(
        width: 76,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                pic.isNotEmpty
                    ? NetImage(
                        pic,
                        width: 40,
                        height: 40,
                        borderRadius: 8,
                        fallbackWidget: fallback,
                      )
                    : fallback,
                if (isPinned)
                  Positioned(
                    right: -6,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        "固定",
                        style: TextStyle(
                          fontSize: 9,
                          height: 1.2,
                          color: colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShowAll(BuildContext context, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 76,
        height: 60,
        child: Center(
          child: Text(
            "显示全部",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}
