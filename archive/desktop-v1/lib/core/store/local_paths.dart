import 'dart:io';

import '../models/enums.dart';

/// 本地文件布局（《同步与云函数契约》§1）。
///
/// 平台层只负责给出**数据目录**（`path_provider` 之类），
/// core 层只认目录 + 文件名，因此可以纯 Dart 测试。
class LocalPaths {
  const LocalPaths(this.directory);

  final Directory directory;

  static const String syncStateFile = 'sync_state.json';

  static const String pendingTxFile = 'pending_tx.json';

  static const String uiPrefsFile = 'ui_prefs.json';

  static const String captureInboxFile = 'capture_inbox.json';

  static const String conflictsDir = 'conflicts';

  File docFile(DocName name) => File(_join(name.fileName));

  File get syncState => File(_join(syncStateFile));

  File get pendingTx => File(_join(pendingTxFile));

  File get uiPrefs => File(_join(uiPrefsFile));

  File get captureInbox => File(_join(captureInboxFile));

  Directory get conflicts => Directory(_join(conflictsDir));

  List<File> get syncedDocFiles =>
      DocName.values.map(docFile).toList(growable: false);

  List<File> get allManagedFiles => <File>[
        ...syncedDocFiles,
        syncState,
        pendingTx,
        uiPrefs,
        captureInbox,
      ];

  /// 草稿文件：`conflicts/<kind>_<doc>_<ts>.json`
  /// （`kind` 为 `conflict`（云同步冲突）或 `imported`（导入冲突），都**不参与同步**）
  File conflictDraft(DocName name, int timestamp, {String kind = 'conflict'}) =>
      File(_join('$conflictsDir/${kind}_${name.fileName}_$timestamp.json'));

  void ensureDirectories() {
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final conflictsDirectory = conflicts;
    if (!conflictsDirectory.existsSync()) conflictsDirectory.createSync(recursive: true);
  }

  String _join(String name) => '${directory.path}${Platform.pathSeparator}$name';
}
