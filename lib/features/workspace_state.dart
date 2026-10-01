import '../core/json/document.dart';
import '../core/models/entity.dart';
import '../core/models/enums.dart';
import '../core/store/app_storage.dart';
import '../core/store/ui_prefs.dart';

/// `Workspace` 的**共享状态**：只装状态，不装规则。
///
/// ## 它为什么存在
///
/// `Workspace` 是一个 2257 行、89 个公开方法的门面（《workspace-拆分-结论》把它
/// 定性为 God Object）。想把它按业务域拆开，撞上的不是"方法太多"，而是
/// **一个共享的私有改动通道**：几乎每个写方法都要读文档集合、过 `upsert`、
/// 有时改偏好，而这三样都是 `Workspace` 的**私有**成员 —— Dart 里
/// 一个类只能待在一个文件中（`part` 与 `extension` 两条路都试过、都被
/// `analyze` 否决，见该文档 §2），所以私有状态不搬出来，任何一段业务逻辑
/// 都搬不走。
///
/// 于是顺序是：**先把状态搬到一个库内可见的容器里，再搬业务逻辑。**
/// 本文件是那第一步。搬完之后，后续每一块（实现清单、重置与反悔、纯规则下沉、
/// 回收站与批量任务）都可以各自成一个文件，构造时收下同一个 `WorkspaceState`。
///
/// ## 现在到了哪一步（别把计划当现状）
///
/// **只有状态搬过来了，业务方法一个都还没搬。** `Workspace` 仍然是 89 个方法全在
/// 一个文件里，只是现在通过 [_documents] / [prefs] / [upsert] 读写状态，
/// 而不是直接碰自己的私有字段。所以本文件**不带来任何可读性收益**，
/// 它唯一的产出是"下一步成为可能"。**它是一次性地基，不是重构本身。**
///
/// ## 与 `Workspace` 的边界（刻意保持保守）
///
/// 这里**只放状态与最底层的读改**，不放任何业务规则：
///
/// | 在这里 | 不在这里 |
/// |---|---|
/// | 文档集合、偏好、存储句柄 | 完成判定、级联、归档区口径 |
/// | [documents] / [upsert]（按 id 覆盖或追加） | 合并灵感、建成任务、重置 |
///
/// 判据是"这一段有没有业务含义"：`upsert` 只是"按 id 换掉或塞进去"，
/// 不含任何规则，所以它属于状态层；而它被引用 61 次的那些**调用方**
/// 各自带着规则，仍然留在 `Workspace` 里。
///
/// 注：`persist()` / `snapshotNow()` **暂时也留在 `Workspace`** ——
/// 它们要现算 `buildStoreFile()`，而那是门面自己的事。等真的搬到
/// "落盘调度"那一块时再一起走，不在这第一步里顺手动。
class WorkspaceState {
  WorkspaceState({
    required this.storage,
    required this.documents,
    required this.prefs,
  });

  /// 落盘与备份的入口。放在这里只是**转发**给业务层用，本类不调它。
  final AppStorage storage;

  /// 四类集合的内存副本 —— 业务层的唯一真源。
  ///
  /// 给的是**同一个 Map 引用**（不是副本）：`Workspace` 里仍有几处按
  /// `_docs[name] = ...` 直接写，语义与迁移前完全一致。要改内容一律走 [upsert]，
  /// 别在别处 `put` —— 那会绕开"按 id 覆盖或追加"这条约定。
  final Map<DocName, Document> documents;

  /// 界面偏好。**可写**：`setExpanded` / `setLastTab` / `markExported` /
  /// `updatePrefs` 都会整份替换掉它，所以这里是普通字段而不是只读 getter。
  UiPrefs prefs;

  /// 某个集合的文档；缺失时给一份空文档（与迁移前的 `documentOf` 一字不差）。
  Document documentOf(DocName name) => documents[name] ?? Document.empty(name);

  /// 按 id 覆盖或追加一条记录。
  ///
  /// 这是"写"的**唯一底层通道**：先看 `items` 里有没有同 id 的，有就替换、没有就追加，
  /// 然后整份写回文档。原来叫 `Workspace._upsert`，因为要跨文件共享而公开 ——
  /// 名字与签名都没改语义，只去掉了下划线。
  ///
  /// **它不落盘**：调用方决定什么时候 `persist()`（有些改动要跟同一次操作里的
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
}
