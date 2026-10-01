import '../core/ids.dart';
import '../core/json/document.dart';
import '../core/json/store_file.dart';
import '../core/models/entity.dart';
import '../core/models/enums.dart';
import '../core/store/app_storage.dart';
import '../core/store/ui_prefs.dart';

/// 业务规则被违反（"用户不能这么做"），不是程序错误。
///
/// 形状与原来一字不差，只是**从 `workspace.dart` 搬到这里**：清单那一块业务
/// 搬去 `workspace_checklist.dart` 之后要用它，而它原先定义在门面文件里 ——
/// 把整个门面 import 进去只为拿一个异常类，会把刚切开的耦合又接回去。
///
/// 放在状态文件里是**有意的将就**：它是业务层的公共词汇，不是状态。没有为它
/// 单开一个文件，是因为 `lib/features/` 下目前只有"门面 / 状态 / 各业务块"三种文件，
/// 再为十几行开第四种不划算。真到了要给它单开文件的时候（比如它开始带字段），
/// 那时再搬，**并且必须同步改 `workspace.dart` 的 export** —— 否则
/// 89 处 `RuleViolation` 会一起编不过。
class RuleViolation implements Exception {
  const RuleViolation(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `Workspace` 的**共享状态与最底层读写**：只装状态，不装业务规则。
///
/// ## 它为什么存在
///
/// `Workspace` 曾是一个 2257 行、89 个公开方法的门面（《workspace-拆分-结论》把它
/// 定性为 God Object）。想把它按业务域拆开，撞上的不是"方法太多"，而是
/// **一个共享的私有改动通道**：几乎每个写方法都要读文档集合、过 `upsert`、
/// 有时改偏好，而这三样都是 `Workspace` 的**私有**成员 —— Dart 里
/// 一个类只能待在一个文件中（`part` 与 `extension` 两条路都试过、都被
/// `analyze` 否决，见该文档 §2），所以私有状态不搬出来，任何一段业务逻辑
/// 都搬不走。
///
/// 于是顺序是：**先把状态与最底层读写搬到一个库内可见的容器里，再搬业务逻辑。**
///
/// ## 边界（判据是"这一段有没有业务含义"）
///
/// | 在这里 | 不在这里 |
/// |---|---|
/// | 文档集合、偏好、存储句柄 | 完成判定、级联、归档区口径 |
/// | [upsert]：按 id 覆盖或追加 | 合并灵感、建成任务、重置 |
/// | [persist] / [snapshotNow] / [buildStoreFile] / [snapshotInMemory] / [rollbackTo] | 事件、任务、灵感各自的规则 |
///
/// `persist` 一族能进来，是因为它们只做"把这一份状态整份写下去"。
/// 它们**必须**进来：各业务块（第一个是 `WorkspaceChecklist`）都要在改完之后落盘，
/// 而落盘要现算整份数据 —— 让每块各自拼一遍 `StoreFile` 就是把这个容器
/// 存在要消灭的那种重复。**所以这里是全层唯一的落盘出口。**
///
/// ## 现在到了哪一步（别把计划当现状）
///
/// 已搬出来的是**共享状态 + 落盘 + 实现清单那一块**（`workspace_checklist.dart`）。
/// `Workspace` 仍是大部分业务方法的所在（2240 行上下），只是现在通过本类读写状态、
/// 并把清单方法转给 `WorkspaceChecklist`。
class WorkspaceState {
  WorkspaceState({
    required this.storage,
    required this.documents,
    required this.prefs,
  });

  /// 落盘与备份的入口。
  final AppStorage storage;

  /// 四类集合的内存副本 —— 业务层的唯一真源。
  ///
  /// 给的是**同一个 Map 引用**（不是副本）：`Workspace` 里仍有几处按
  /// `documents[name] = ...` 直接写，语义与迁移前完全一致。要改内容一律走 [upsert]，
  /// 别在别处 `put` —— 那会绕开"按 id 覆盖或追加"这条约定。
  final Map<DocName, Document> documents;

  /// 界面偏好。**可写**：`setExpanded` / `setLastTab` / `markExported` /
  /// `updatePrefs` 都会整份替换掉它，所以这里是普通字段而不是只读 getter。
  UiPrefs prefs;

  // ---------------------------------------------------------------- 读与改

  /// 某个集合的文档；缺失时给一份空文档（与迁移前的 `documentOf` 一字不差）。
  Document documentOf(DocName name) => documents[name] ?? Document.empty(name);

  /// 按 id 覆盖或追加一条记录。
  ///
  /// 这是"写"的**唯一底层通道**：先看 `items` 里有没有同 id 的，有就替换、没有就追加，
  /// 然后整份写回文档。原来叫 `Workspace._upsert`，因为要跨文件共享而公开 ——
  /// 名字与签名都没改语义，只去掉了下划线。
  ///
  /// **它不落盘**：调用方决定什么时候 [persist]（有些改动要跟同一次操作里的
  /// 另一处改动**一起**落盘，单文件让这两处天然全有或全无）。
  void upsert(DocName name, Entity entity) {
    final items = List<Entity>.from(documentOf(name).items);
    final index = items.indexWhere((e) => e.id == entity.id);
    if (index >= 0) {
      items[index] = entity;
    } else {
      items.add(entity);
    }
    documents[name] = documentOf(name).copyWith(items: items);
  }

  // ---------------------------------------------------------------- 落盘

  /// 当前的完整数据快照（导出用）。
  StoreFile buildStoreFile() => StoreFile(documents: documents, savedAt: Ids.nowMillis());

  /// 内存快照 + 回滚。
  ///
  /// 业务动作的写法是「先改内存，再整份落盘」。写盘失败时内存已经改了，
  /// 如果就这么放过，界面会显示一个**磁盘上并不存在**的状态 —— 用户以为存住了，
  /// 下次启动才发现没了。所以写失败必须把内存退回动作前的样子，让两边保持一致。
  ///
  /// `Document` 是不可变的，文档集合是「整份替换」而不是就地改，
  /// 因此浅拷贝一份 map 就是完整快照。
  Map<DocName, Document> snapshotInMemory() => Map<DocName, Document>.from(documents);

  void rollbackTo(Map<DocName, Document> snapshot) {
    documents
      ..clear()
      ..addAll(snapshot);
  }

  /// 原子落盘：**整份数据一次写入**（单文件让跨实体变更天然原子），偏好另存一份。
  void persist() {
    storage.save(buildStoreFile());
    storage.savePrefs(prefs);
  }

  /// 手动触发一次备份轮转（导入、批量操作前可调用）。
  ///
  /// ⚠️ 走的是**强制**路径（`forceRotate: true`），不是普通 `save`：
  /// 普通保存的轮转按"编辑会话 / 最小间隔"节流（Q3），而这里正是**用户显式
  /// 要求"现在留一份"**的场景 —— 被节流拦下就等于这句承诺落空。
  void snapshotNow() {
    storage.save(buildStoreFile(), forceRotate: true);
  }
}
