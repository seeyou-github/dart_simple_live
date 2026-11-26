import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_core/simple_live_core.dart';

class HomeListController extends BasePageController<LiveRoomItem> {
  final Site site;
  HomeListController(this.site);

  /// 当前选中的分类，null 表示显示推荐流
  var selectedCategory = Rxn<LiveSubCategory>();

  /// 回到"主页"：显示默认的推荐直播列表
  Future<void> selectHome() async {
    if (selectedCategory.value == null) {
      return;
    }
    selectedCategory.value = null;
    await reloadFirstPage();
  }

  /// 选中某个分类（弹框选择时使用，不做"再点一次取消"的切换）
  Future<void> selectCategory(LiveSubCategory category) async {
    var current = selectedCategory.value;
    if (current != null &&
        current.id == category.id &&
        current.parentId == category.parentId) {
      return;
    }
    selectedCategory.value = category;
    await reloadFirstPage();
  }

  /// 点击分类栏：选中该分类；再次点击已选中的分类则回到推荐流
  Future<void> toggleCategory(LiveSubCategory category) async {
    var current = selectedCategory.value;
    if (current != null &&
        current.id == category.id &&
        current.parentId == category.parentId) {
      selectedCategory.value = null;
    } else {
      selectedCategory.value = category;
    }
    await reloadFirstPage();
  }

  @override
  Future<List<LiveRoomItem>> getData(int page, int pageSize) async {
    var category = selectedCategory.value;
    if (category != null) {
      var result = await site.liveSite.getCategoryRooms(category, page: page);
      return result.items;
    }
    var result = await site.liveSite.getRecommendRooms(page: page);
    return result.items;
  }
}
