import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/json/store_file.dart';
import '../../core/models/enums.dart';
import '../../core/models/github_backup_config.dart';
import '../../core/store/github_sync.dart';
import '../../core/store/store_diff.dart';
import '../common/commit_lcd.dart';
import '../common/dialogs.dart';
import '../common/keyboard_dismiss_guard.dart';
import '../common/store_diff_panel.dart';
import '../theme/shape_tokens.dart';

/// 「GitHub 备份同步」页。
///
/// 这一页只做一件事：把手机上这份数据推到用户自己的私有仓库，或反过来拉回来。
/// 三条口径是写死的，别在别处再实现一遍：
///   · **这一页上是纯手动**：不做启动检查、也不在这一页里自动推送 ——
///     页面上的两下永远是你亲手点的（自动上传走的是另一条路：
///     `AppController.autoSyncAfterHome`，回到主页时比对并上传，见 handoff #87c57e）；
///   · **不做自动合并**：两边都改过时只把情况摆出来，让用户自己选；
///   · **推送前确认、拉取前先预览条数与时间再确认**：两端都是覆盖性操作。
///     自动那条路**只上传、不自动拉**，一样要看着差异点确认才覆盖云端。
///
/// 为什么要在页面上摆出**提交码**（ADR-089）：它是"这是哪一次上传"的凭证 ——
/// 两台手机上读到同一个提交码，就是同一份；内容码相同并不说明这一点。
/// 最顶上那格点阵屏（[CommitLcd]）就是这枚凭证的"读数窗"。
class GitHubBackupPage extends StatefulWidget {
  const GitHubBackupPage({super.key, required this.app});

  final AppController app;

  @override
  State<GitHubBackupPage> createState() => _GitHubBackupPageState();
}

class _GitHubBackupPageState extends State<GitHubBackupPage> {
  late final AppController app = widget.app;

  final _owner = TextEditingController();
  final _repo = TextEditingController();
  final _branch = TextEditingController();
  final _path = TextEditingController();
  final _token = TextEditingController();

  bool _enabled = false;
  bool _loading = true;
  bool _busy = false;
  bool _tokenStored = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _owner.dispose();
    _repo.dispose();
    _branch.dispose();
    _path.dispose();
    _token.dispose();
    super.dispose();
  }

  /// 读回已存配置。**已存的 Token 不回显**（与 AI 设置页同一条口径）。
  Future<void> _load() async {
    final saved = await app.readGitHubBackupConfig();
    if (!mounted) return;
    setState(() {
      _enabled = saved.config.enabled;
      _owner.text = saved.config.owner;
      _repo.text = saved.config.repo;
      _branch.text = saved.config.branch;
      _path.text = saved.config.path;
      _tokenStored = saved.token.isNotEmpty;
      _loading = false;
    });
  }

  /// 把"输入框里现拼的那一份"拿出来（**不落盘**）。
  ///
  /// 输入框为空时沿用已存的值：用户只想点一下「测试连接」或「推送」时，
  /// 不该被要求把已经存过的 Token 再打一遍。
  Future<({GitHubBackupConfig config, String token})> _draft() async {
    final saved = await app.readGitHubBackupConfig();
    final token = _token.text.trim().isEmpty ? saved.token : _token.text.trim();
    return (
      config: GitHubBackupConfig(
        enabled: _enabled,
        owner: _owner.text.trim().isEmpty ? saved.config.owner : _owner.text.trim(),
        repo: _repo.text.trim().isEmpty ? saved.config.repo : _repo.text.trim(),
        branch: _branch.text.trim().isEmpty ? saved.config.branch : _branch.text.trim(),
        path: _path.text.trim().isEmpty ? saved.config.path : _path.text.trim(),
      ),
      token: token,
    );
  }

  void _setResult(String? text) {
    if (!mounted) return;
    setState(() => _result = text);
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final draft = await _draft();
    final error = await app.saveGitHubBackupConfig(draft.config, draft.token);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    _token.clear();
    await _load();
    if (!mounted) return;
    showToast(context, '已保存');
  }

  Future<void> _test() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    final draft = await _draft();
    final result = await app.testGitHubConnection(draft.config, draft.token);
    if (!mounted) return;
    setState(() => _busy = false);
    _setResult(
      result.ok ? '${result.message}\n\n还没保存：按右上角「保存」才会写入' : result.message,
    );
  }

  /// 推送：先把远程情况摆出来，再按判定结果决定要不要多问一句。
  Future<void> _push() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    final draft = await _draft();

    final check = await app.checkGitHubBackup(draft.config, draft.token);
    if (!mounted) return;
    if (check.error != null) {
      setState(() => _busy = false);
      _setResult(check.error);
      return;
    }

    final plan = check.plan!;
    final local = app.ws.buildStoreFile();
    final localText = _countsText(liveCountsOf(local));
    // 远程那份的原文（能读到才有）—— 有它就能把"推上去会盖掉哪几条"逐条摆出来
    final remoteStore = check.remote?.payload?.store;

    var override = false;

    switch (plan.action) {
      case SyncAction.noChange:
        setState(() => _busy = false);
        _setResult(plan.message);
        return;
      case SyncAction.localEmpty:
        setState(() => _busy = false);
        _setResult(
          '${plan.message}\n\n'
          '为了不误擦远程，这里不往下走 —— 先在这台手机上恢复数据，或者去远程把那份存下来。',
        );
        return;
      case SyncAction.bothChanged:
      case SyncAction.pull:
        if (!mounted) return;
        final ok = await _confirmPushOverwrite(
          local: local,
          remoteStore: remoteStore,
          title: '覆盖远程那份备份',
          message: '${plan.message}\n\n'
              '当前这台手机：$localText\n'
              '${_remoteCommitText(check.remoteCommit)}\n\n'
              '覆盖之后，远程上一次的内容仍然可以从 GitHub 的提交历史里找回。',
          confirmLabel: '用本地覆盖远程',
          danger: true,
        );
        if (!ok) {
          setState(() => _busy = false);
          return;
        }
        override = true;
      case SyncAction.push:
        if (!mounted) return;
        final ok = await _confirmPushOverwrite(
          local: local,
          remoteStore: remoteStore,
          title: '推送到 GitHub',
          message: '会把当前 $localText 推上去，覆盖远程那一份路径上的文件。\n\n'
              '远程：${plan.remoteSavedAt == null ? '还没有这份文件' : formatStamp(plan.remoteSavedAt)}\n'
              '${_remoteCommitText(check.remoteCommit)}',
          confirmLabel: '推送',
        );
        if (!ok) {
          setState(() => _busy = false);
          return;
        }
    }

    final result = await app.pushGitHubBackup(
      draft.config,
      draft.token,
      overrideRemoteChanges: override,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _setResult(result.message);
  }

  /// 拉取：**先预览条数与时间，再确认一次**，然后才覆盖本地。
  Future<void> _pull() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    final draft = await _draft();

    final preview = await app.previewGitHubPull(draft.config, draft.token);
    if (!mounted) return;
    if (preview.remote == null) {
      setState(() => _busy = false);
      _setResult(preview.error);
      return;
    }

    final remote = preview.remote!;
    final incoming = _countsText(liveCountsOf(remote.payload!.store));
    final local = app.ws.buildStoreFile();
    final current = _countsText(liveCountsOf(local));

    // 拉回也是整份覆盖：把"会被换掉的哪些、换回来的哪些"逐条摆出来（第 3 条反馈）
    final diff = diffStores(base: local, target: remote.payload!.store);
    final ok = diff.hasChanges
        ? (await showStoreDiffSheet(
            context,
            diff: diff,
            title: '用远程那份覆盖这台手机',
            baseLabel: '这台手机（会被覆盖）· $current',
            targetLabel: '云端（会拉下来）· ${formatStamp(remote.savedAt)} · $incoming',
            confirmLabel: '拉取并覆盖',
            cancelLabel: '取消',
            danger: true,
            note: '${_remoteCommitText(preview.commit)}\n\n'
                '覆盖之前，当前数据会先整体轮转进备份（滚动只留 10 份，想退回要尽快）。',
          )) ==
              DiffSheetResult.confirm
        : await confirmAction(
            context,
            title: '用远程那份覆盖这台手机',
            message: '远程：${formatStamp(remote.savedAt)} · $incoming\n'
                '${_remoteCommitText(preview.commit)}\n'
                '现在这台上：$current\n\n'
                '覆盖之前，当前数据会先整体轮转进备份（滚动只留 10 份，想退回要尽快）。',
            confirmLabel: '拉取并覆盖',
            danger: true,
          );
    if (!ok) {
      setState(() => _busy = false);
      return;
    }

    final result = await app.pullGitHubBackup(draft.config, draft.token);
    if (!mounted) return;
    setState(() => _busy = false);
    _setResult(result.message);
  }

  /// 推送前的确认：**能和云端比对就把差异逐条摆出来**，比不了才退回一句话的收据式确认。
  ///
  /// 方向是固定的：基准＝云端、对方＝这台手机 —— 这一屏回答的是
  /// "推上去之后云端会变成什么样、会丢掉哪几条"（用户口径：与云端比对后上传，
  /// **出现偏差才**弹差异面板）。远程还没有这份文件时没有可比的旧版本，就不弹。
  Future<bool> _confirmPushOverwrite({
    required StoreFile local,
    required StoreFile? remoteStore,
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final remote = remoteStore;
    final diff = remote == null ? null : diffStores(base: remote, target: local);
    // 比不了（第一次同步、云端还没有那份文件）或两边一样：退回原来那句话的确认框。
    if (diff == null || remote == null || !diff.hasChanges) {
      return confirmAction(
        context,
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        danger: danger,
      );
    }
    final choice = await showStoreDiffSheet(
      context,
      diff: diff,
      title: title,
      baseLabel: '云端（会被覆盖）· ${_countsText(liveCountsOf(remote))}',
      targetLabel: '这台手机（会推上去）· ${_countsText(liveCountsOf(local))}',
      confirmLabel: confirmLabel,
      cancelLabel: '取消',
      danger: danger,
      note: message,
    );
    // 「取消」与"划掉面板走人"在这里是同一件事：都没推。这一层不负责摆胶囊
    // （那是自动同步那条路的事）。
    return choice == DiffSheetResult.confirm;
  }

  static String _countsText(Map<DocName, int> counts) => DocName.values
      .map((name) => '${_label(name)} ${counts[name] ?? 0}')
      .join(' · ');

  static String _label(DocName name) {
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

  String _lastSyncText() {
    final record = app.readGitHubSyncRecord();
    if (record == null) return '这台手机还没和这个仓库同步过。';
    // 两个码并列摆出来，但不混为一谈：**提交码在前** —— 它才是"是不是
    // 同一次上传"的凭证；内容码在后，它只答"内容一不一样"。
    // 老记账（1.8.5 及以前）没有提交码，写「未知」而不是装作有。
    return '上次同步：${formatStamp(record.syncedAt)} · ${record.recordCount} 条记录\n'
        '提交 ${shortSha(record.commitSha)} · 内容码 ${shortSha(record.remoteSha)}';
  }

  /// 这台手机此刻站着的提交码（记账里的那一次上传）。没同步过就是空串，
  /// 点阵屏收到空串会**整屏变暗** —— 不写"未知"之类的字。
  String _currentCommitSha() => app.readGitHubSyncRecord()?.commitSha ?? '';

  /// 远程此刻那一次提交（读不到时如实写"读不到"，不装作有）。
  static String _remoteCommitText(RemoteCommit? commit) =>
      commit == null || !commit.known
          ? '远程提交：读不到'
          : '远程提交：${shortSha(commit.sha)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('GitHub 备份同步'),
        actions: <Widget>[
          TextButton(
            onPressed: (_loading || _busy) ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: <Widget>[
                // 最顶上单开的这一格：**这台手机当前站在哪次提交上**。
                // 不配标题文字 —— 没有提交号时它就是一块熄着的屏，写"未知"
                // 反而是往界面上摆一句假话（点阵屏自己会说明问题）。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: CommitLcd(commitSha: _currentCommitSha()),
                ),
                SwitchListTile(
                  value: _enabled,
                  title: const Text('启用 GitHub 备份同步'),
                  subtitle: const Text('关掉不会丢配置，也不会删掉远程那份\n开着时：每次回到主页会自动上传这次改动（只上传，不会自动拉回）'),
                  onChanged: (value) => setState(() => _enabled = value),
                ),
                const Divider(height: 1),
                _SectionLabel('仓库'),
                _Field(
                  label: '所有者',
                  hint: 'GitHub 用户名或组织名，例如 maker114',
                  controller: _owner,
                ),
                _Field(
                  label: '仓库名',
                  hint: '例如 guideline-backup（建议用私有仓库）',
                  controller: _repo,
                ),
                _Field(
                  label: '分支',
                  hint: GitHubBackupConfig.defaultBranch,
                  controller: _branch,
                ),
                _Field(
                  label: '远程文件路径',
                  hint: GitHubBackupConfig.defaultPath,
                  controller: _path,
                  helper: '每次覆盖都是这个路径上的一次提交，仓库历史就是你的退路',
                ),
                _SectionLabel('凭据'),
                _Field(
                  label: 'Token',
                  hint: _tokenStored ? '已保存（留空表示不改）' : '至少要能读写这个仓库',
                  controller: _token,
                  obscure: true,
                  helper: '只存系统安全存储（Android Keystore）；不进偏好文件、不进备份、不进整库导出',
                ),
                const Divider(height: 1),
                _SectionLabel('同步'),
                if (!_enabled)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      '开关关着：推送与拉取都点不动（测试连接是只读的，随时可用）。'
                      '这一页不会在你没点的时候自己连网。',
                    ),
                  ),
                _ActionTile(
                  icon: Icons.wifi_tethering,
                  title: '测试连接',
                  subtitle: '只读一次远程文件，不写任何东西',
                  onTap: _busy ? null : _test,
                ),
                _ActionTile(
                  icon: Icons.cloud_upload_outlined,
                  title: '推送到 GitHub',
                  subtitle: '用这台手机的数据覆盖远程那一份（推送前会确认）',
                  onTap: (_busy || !_enabled) ? null : _push,
                ),
                _ActionTile(
                  icon: Icons.cloud_download_outlined,
                  title: '从 GitHub 拉取',
                  subtitle: '先看条数与时间，再确认覆盖这台手机',
                  onTap: (_busy || !_enabled) ? null : _pull,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    _lastSyncText(),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: LinearProgressIndicator(),
                  ),
                if (_result != null) _ResultBox(text: _result!, error: _isErrorText(_result!)),
                _SectionLabel('会发出去什么'),
                const _Bullet('整份数据文件（压缩后），也就是「导出」会生成的那一份：'
                    '项目、灵感、事件、任务，含墓碑与偏好文件之外的记录'),
                const _Bullet('推上去之后，它就在你的 GitHub 仓库里以「明文」（gzip）存在着 —— '
                    '所以这个仓库必须是私有的'),
                const _Bullet('每次推送都是仓库里的一次提交，所以旧版本可以从提交历史里找回'),
                _SectionLabel('不会发出去什么'),
                const _Bullet('Token 本身：它只存在系统安全存储里，连偏好文件的键都不出现'),
                const _Bullet('不会自动推送、不会在启动时检查远程 —— 这一版只有你亲手点的两下'),
                const _Bullet('不会把远程那份自动和本地合并：两边都改过时，只由你选一个方向'),
              ],
            ),
    );
  }

  /// 结果框是"失败"还是"成功"，只用来决定底色：推送失败 / 连接失败都算失败。
  bool _isErrorText(String text) =>
      text.contains('失败') || text.contains('连不上') || text.contains('不对');
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('· '),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}

class _ResultBox extends StatelessWidget {
  const _ResultBox({required this.text, required this.error});

  final String text;
  final bool error;

  /// 结果框只**显示**结论：推送 / 拉取的取舍按 ADR-088 全在
  /// `_push` / `_pull` 的确认框里问过用户，这里不再补一次交互。
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: (error ? scheme.error : scheme.primary).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
        ),
        child: SelectableText(text),
      ),
    );
  }
}

/// 一个输入框：自带焦点节点，并接上键盘护栏（ADR-087：页面级输入收键盘只放焦点）。
class _Field extends StatefulWidget {
  const _Field({
    required this.label,
    required this.hint,
    required this.controller,
    this.helper,
    this.obscure = false,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final String? helper;
  final bool obscure;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: KeyboardDismissGuard(
          isFocused: () => _focus.hasFocus,
          onKeyboardDismissed: _focus.unfocus,
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            obscureText: widget.obscure,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              helperText: widget.helper,
              helperMaxLines: 3,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      );
}
