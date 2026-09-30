import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ids.dart';
import '../../core/json/store_file.dart';
import '../../core/models/entity.dart';
import '../../core/models/enums.dart';
import '../../core/store/export_codec.dart';
import '../../core/store/merge.dart';
import '../../core/store/store_diff.dart';
import '../../platform/data_transfer_platform.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/store_diff_panel.dart';

/// 导出 / 导入。
///
/// 没有云端之后，**导出是数据离开这台手机的唯一通道**（卸载 App、换机、手机丢失），
/// 所以这一页既要做通道，也要把"该导出了"这件事说清楚。
class ExportPage extends StatefulWidget {
  const ExportPage({super.key, required this.app, this.pickImportFile});

  final AppController app;

  /// 选文件的钩子（默认走系统文件选择器）。
  ///
  /// 留这个口子的理由很具体：`file_picker` 在纯 Dart 测试里没有插件实现，
  /// 而"导入前的确认框里到底摆了什么数"**只有走到这一步才验得出来** ——
  /// 而那几句文案恰恰是用户唯一的决策依据。
  final Future<PickedTransferFile?> Function()? pickImportFile;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final app = widget.app;
        final theme = Theme.of(context);
        final last = app.lastExportedAt;

        return Scaffold(
          appBar: AppBar(title: const Text('导出 / 导入')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: <Widget>[
              Card(
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            app.exportOverdue ? Icons.warning_amber_outlined : Icons.verified_outlined,
                            size: 18,
                            color: app.exportOverdue
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              last == null
                                  ? '还没有导出过'
                                  : '上次导出：${formatTimestamp(last)}，${relativeTime(last)}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: app.exportOverdue ? theme.colorScheme.error : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        app.exportOverdue
                            ? '建议每 ${AppController.exportReminderDays} 天导出一次。'
                                '没有云端，手机丢失或卸载后，数据只剩这份导出。'
                            : '导出的备份还不算旧。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('导出并分享'),
                subtitle: const Text('导出为 .json.gz，再交给系统分享'),
                enabled: !_busy,
                onTap: _busy ? null : () => _export(context),
              ),
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('从文件导入'),
                subtitle: const Text('整体替换当前数据；替换前会自动留一份备份'),
                enabled: !_busy,
                onTap: _busy ? null : () => _import(context),
              ),
              ListTile(
                leading: const Icon(Icons.merge_type),
                title: const Text('合并导入'),
                subtitle: const Text('两份并成一份，同一条以较新的为准；合并前会先留备份'),
                enabled: !_busy,
                onTap: _busy ? null : () => _mergeImport(context),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(child: CircularProgressIndicator()),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('说明', style: theme.textTheme.labelLarge),
              ),
              // 只留与"会不会丢数据"有关的两条
              const _Bullet('「从文件导入」是整体替换：这台手机会变成文件里的内容。'
                  '替换前会先留一份备份，导入有误可以在「备份与恢复」里恢复。'),
              const _Bullet('「合并导入」同一条记录以较新的一方为准，合并前同样先留一份备份。'),
            ],
          ),
        );
      },
    );
  }

  Future<void> _export(BuildContext context) async {
    // 只靠 `onTap: _busy ? null : ...` 挡不住重入（Q-7）：那只是把按钮关掉，
    // 无障碍焦点 / 热键仍可能再次进来。函数自己也要认 `_busy`。
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.app.exportAndShare();
      if (!mounted) return;
      if (!context.mounted) return;
      showToast(context, result.message, error: !result.ok);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 选文件 → 解码（「从文件导入」与「合并导入」共用这一条路）。
  ///
  /// 返回 `null` 表示没走到"有一份能用的数据"这一步（没选文件、选择器失败、
  /// 或者文件读不出 Guide Line 数据）；失败原因已经用吐司说过了，调用方直接收工。
  Future<({PickedTransferFile file, ExportPayload payload})?> _pickAndDecode(
    BuildContext context, {
    required String dialogTitle,
  }) async {
    if (_busy) return null;
    setState(() => _busy = true);
    // `_busy` 必须**覆盖到解码结束**（Q-7）：早先在文件选择器一返回就把它清掉了，
    // 于是"解码中"这段窗口里界面已经解禁，两个流程可以交错、各写一次盘。
    try {
      PickedTransferFile? picked;
      try {
        final pick = widget.pickImportFile ??
            () => DataTransferPlatform.pickFile(dialogTitle: dialogTitle);
        picked = await pick();
      } catch (error) {
        if (mounted && context.mounted) {
          showToast(context, '打开文件选择器失败：$error', error: true);
        }
        return null;
      }
      if (!mounted || picked == null || !context.mounted) return null;

      final issues = DecodeIssues();
      final payload = ExportCodec.decode(picked.bytes, issues);
      if (!payload.readable) {
        final reason = issues.errors.isEmpty ? '结构不完整' : issues.errors.first;
        showToast(context, '这个文件里读不出 Guide Line 数据：$reason', error: true);
        return null;
      }
      return (file: picked, payload: payload);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(BuildContext context) async {
    final picked = await _pickAndDecode(context, dialogTitle: '选择要导入的导出文件');
    if (picked == null || !context.mounted) return;
    final payload = picked.payload;

    // 两侧都数**活记录**（墓碑不算）：用户要判断的是"看得见的数据会少掉多少"，
    // 而 `payload.counts` 是**含墓碑**的（导入本来就是整体替换、墓碑也要一起搬）。
    // 所以这一页自己数，不去改 core 层的口径 —— 这里的算法与
    // `Workspace.liveProjects` 那几个视图完全一样，两个数才可能对得上。
    final current = _currentCounts;
    final incoming = _liveCountsOf(payload);
    final local = widget.app.ws.buildStoreFile();
    final diff = diffStores(base: local, target: payload.store);

    final message = '文件名：${picked.file.name}\n'
        '导出时间：${payload.exportedAt == null ? '未知' : formatTimestamp(payload.exportedAt!)}\n'
        '\n'
        '当前：${_countsText(current)}\n'
        '文件：${_countsText(incoming)}\n'
        '${_netChangeText(_totalOf(current), _totalOf(incoming))}\n'
        '\n'
        '导入是整体替换，不会把两份数据合起来；想让两边各有的记录都留下，用「合并导入」。\n'
        '想保留当前数据，请先「导出并分享」留一份存档，再执行导入。\n'
        '替换前当前数据会先整体轮转进备份，可在「备份与恢复」里退回。';

    // 整体替换会把现有数据整份换掉：只给条数不够 —— 条数一样也可能换掉了一条、
    // 条数变多也可能顺手删了三条。所以能比就**逐条摆出来**（第 3 条反馈）。
    final ok = diff.hasChanges
        ? (await showStoreDiffSheet(
            context,
            diff: diff,
            title: '导入并替换全部数据',
            baseLabel: '当前 · 会被替换 · ${_countsText(current)}',
            targetLabel: '文件 · 导入后即为该状态 · ${_countsText(incoming)}',
            confirmLabel: '整体替换',
            cancelLabel: '取消',
            danger: true,
            note: message,
          )) ==
              DiffSheetResult.confirm
        : await confirmAction(
            context,
            title: '导入并替换全部数据',
            message: message,
            confirmLabel: '整体替换',
            danger: true,
          );
    if (!ok || !context.mounted) return;

    final error = widget.app.applyImport(payload.store);
    if (!context.mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已导入：${_countsText(incoming)}');
  }

  /// 「合并导入」：**先算、先给预览，确认之后才落盘**（与 AI 整理"先预览后写入"同一个习惯）。
  ///
  /// 合并判定一行都不在这里写：全部走 `mergeStoresWithReport`（纯函数，见
  /// `core/store/merge.dart`），这一层只负责把报告摆给用户看、并在确认后交给
  /// [AppController.applyMergedStore] 落盘。
  Future<void> _mergeImport(BuildContext context) async {
    final picked = await _pickAndDecode(context, dialogTitle: '选择要合并的导出文件');
    if (picked == null || !context.mounted) return;

    final local = widget.app.ws.buildStoreFile();
    final outcome = mergeStoresWithReport(
      local,
      picked.payload.store,
      nowMillis: Ids.nowMillis(),
    );
    final report = outcome.report;

    // 一份什么都没变的结果不该让用户白点一次确认（多进来 0 条、覆盖 0 条、
    // 也没有墓碑），更不该为此写一次盘。这里只说明情况就收工。
    //
    // 措辞带上"这份文件里没有本机缺少的记录"：`hasChanges` 为假也可能是
    // "本机比文件多"（文件里是旧的一份），只写"两份一致"会让人以为一模一样。
    if (!report.hasChanges) {
      showToast(context, '这份文件里没有本机缺少的记录：两份数据已经一致，没有要合并的');
      return;
    }

    final preview = _mergePreviewText(picked.file.name, picked.payload.exportedAt, report);
    // 合并的结果也**逐条摆出来**：报告说的是"每一类新增/更新多少"，
    // 面板说的是"具体多了哪几条、哪几条被顶掉"——后者才是"我敢不敢按下去"的依据。
    final diff = diffStores(base: local, target: outcome.store);
    final ok = diff.hasChanges
        ? (await showStoreDiffSheet(
            context,
            diff: diff,
            title: '合并导入：两份并成一份',
            baseLabel: '现在这台手机 · ${_countsText(_currentCounts)}',
            targetLabel: '合并后 · ${_countsText(_liveCountsOfStore(outcome.store))}',
            confirmLabel: '合并',
            cancelLabel: '取消',
            danger: true,
            note: preview,
          )) ==
              DiffSheetResult.confirm
        : await confirmAction(
            context,
            title: '合并导入：两份并成一份',
            message: preview,
            confirmLabel: '合并',
            danger: true,
          );
    if (!ok || !context.mounted) return;

    final error = widget.app.applyMergedStore(outcome.store);
    if (!context.mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(
      context,
      '已合并：${report.changeSummary}。合并前的数据已留成备份，可在「备份与恢复」里退回。',
    );
  }

  /// 当前库的活记录数：直接问 `Workspace.live*`（"活记录"口径的唯一出处）。
  _LiveCounts get _currentCounts => (
        projects: widget.app.ws.liveProjects.length,
        inspirations: widget.app.ws.liveInspirations.length,
        events: widget.app.ws.liveEvents.length,
        tasks: widget.app.ws.liveTasks.length,
      );
}

/// 四类记录的**活记录**条数（已删除的墓碑一律不算）。
typedef _LiveCounts = ({int projects, int inspirations, int events, int tasks});

/// 文件那一侧的活记录数。
///
/// `ExportPayload.counts` 是含墓碑的，这里**刻意不用它**：同一个确认框里
/// "当前"按活记录算、"文件"按含墓碑算的话，两个数根本对不上，
/// 比不给数字更糟（用户会以为自己看错了）。
_LiveCounts _liveCountsOf(ExportPayload payload) => _liveCountsOfStore(payload.store);

/// 任意一份 store 的活记录数（差异面板里"这一版是多少"用它）。
_LiveCounts _liveCountsOfStore(StoreFile store) => (
      projects: _liveItemCountIn(store, DocName.projects),
      inspirations: _liveItemCountIn(store, DocName.inspirations),
      events: _liveItemCountIn(store, DocName.events),
      tasks: _liveItemCountIn(store, DocName.tasks),
    );

int _liveItemCountIn(StoreFile store, DocName name) =>
    store.documentOf(name).items.where((item) => !item.deleted).length;

int _totalOf(_LiveCounts counts) =>
    counts.projects + counts.inspirations + counts.events + counts.tasks;

String _countsText(_LiveCounts counts) =>
    '项目 ${counts.projects} · 灵感 ${counts.inspirations} · '
    '事件 ${counts.events} · 任务 ${counts.tasks}';

/// 净变化那一句 —— 用户最需要的其实是"会不会少东西"。
String _netChangeText(int currentTotal, int incomingTotal) {
  final delta = incomingTotal - currentTotal;
  if (delta == 0) return '条数相当，前后都是 $currentTotal 条';
  if (delta < 0) {
    return '总条数将减少 ${-delta} 条：$currentTotal → $incomingTotal';
  }
  return '总条数将增加 $delta 条：$currentTotal → $incomingTotal';
}

/// 「合并导入」预览正文 —— 用户点确认之前能看到的**全部**信息就是它。
///
/// 风格与 Q13「整体替换」的确认框一致（并排数字 + 红色确认），差别在数字的含义：
/// 那边是"当前 / 文件各有多少条"，这边是"每一类各新增 / 更新 / 保留 / 墓碑多少条"，
/// 因为合并要回答的是"多进来什么、覆盖了什么、删掉了什么"。
///
/// 三条**必须说清**的口径，缺一条用户就没法判断这次合并安不安全：
///   · 两边各自独有的记录都会留下（这是"合并不是替换"）；
///   · 同一条记录以较新的一方为准，**同一秒以本机为准**（对方同秒的修改不会
///     覆盖你手上正在看的记录 —— 这条写死在 `mergeStores` 里）；
///   · 引用不会当场改写（悬挂交给加载层），而且合并前会先留一份备份。
String _mergePreviewText(String fileName, int? exportedAt, MergeReport report) {
  final lines = <String>[
    '文件名：$fileName',
    '导出时间：${exportedAt == null ? '未知' : formatTimestamp(exportedAt)}',
    '',
    for (final name in DocName.values)
      '${_docLabel(name)}：${_mergeCountsText(report.of(name))}',
    '合计：${report.changeSummary}',
    '',
    // 只留"谁的改动会赢"这一句（数据风险）；"合并是两份并成一份"那类解释删掉
    '同一秒里的改动以本机为准；对方在同一秒修改的那条不会覆盖本机正在使用的记录。',
  ];
  if (report.tombstones > 0) {
    // 墓碑是"对方删过"的唯一证据，混在"新增"里会被当成多出来的数据，
    // 所以单独解释一句：它并进来是为了不让删掉的记录在下次导入时复活。
    lines.add('${report.tombstones} 条墓碑是对方删除过的记录：保留它们是为了避免这些记录在下次导入时重新出现。');
  }
  if (report.danglingReferences > 0) {
    lines.add('合并后有 ${report.danglingReferences} 处引用指向不存在的记录：'
        '引用不会当场改写，交给加载时的悬挂规则处理。');
  }
  if (report.duplicatesCollapsed > 0) {
    lines.add('文件里有 ${report.duplicatesCollapsed} 条同 id 的重复记录，已折叠，只认第一条。');
  }
  lines.add('合并前当前数据会先整体轮转进备份；滚动备份只留 10 份，如需退回请尽快。');
  return lines.join('\n');
}

/// 单个集合的四个数，写法与 `MergeReport.changeSummary` 一致（顺序也一致）。
String _mergeCountsText(CollectionMergeReport report) =>
    '新增 ${report.added.length} · 更新 ${report.updated.length} · '
    '保留 ${report.kept.length} · 墓碑 ${report.tombstones.length}';

/// 集合的中文名（这一页的四个数都按它排列，四行顺序 = `DocName.values`）。
String _docLabel(DocName name) {
  switch (name) {
    case DocName.projects:
      return '项目';
    case DocName.inspirations:
      return '灵感';
    case DocName.events:
      return '事件';
    case DocName.tasks:
      return '任务';
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('· ', style: theme.textTheme.bodySmall),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
