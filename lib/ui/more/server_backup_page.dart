import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/server_backup_config.dart';
import '../../core/store/github_sync.dart';
import '../../core/store/store_diff.dart';
import '../common/dialogs.dart';
import '../common/keyboard_dismiss_guard.dart';
import '../common/store_diff_panel.dart';
import '../theme/shape_tokens.dart';

/// 「服务器同步」页：把整份数据推到**自己搭的**服务器，或拉回来。
///
/// 与「GitHub 备份同步」是两条并列的管线，各有各的开关与记账
/// （`server_sync.json` 与 `github_sync.json`）。这一页的口径：
///   · **纯手动**：这一版不做启动比对、也不在回主页时自动上传 ——
///     两条管线同时自动跑，冲突会互相踩；先把手动这条走通；
///   · **不做自动合并**：两边都改过时只摆出情况，由用户选方向；
///   · **拉取是覆盖性动作**：先比内容，有差别才摆逐条差异面板；
///   · **0 条不算可用备份**：服务器上解出 0 条时不许拿它覆盖本地。
///
/// 安全边界：自签证书 + **客户端固定 SHA-256 指纹**（见 `server_backup_client.dart`），
/// Token 只进系统安全存储，与 AI 的 `apiKey` / GitHub 的 `token` 分开存。
class ServerBackupPage extends StatefulWidget {
  const ServerBackupPage({super.key, required this.app});

  final AppController app;

  @override
  State<ServerBackupPage> createState() => _ServerBackupPageState();
}

class _ServerBackupPageState extends State<ServerBackupPage> {
  late final AppController app = widget.app;

  final _baseUrl = TextEditingController();
  final _fingerprint = TextEditingController();
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
    _baseUrl.dispose();
    _fingerprint.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final saved = await app.readServerBackupConfig();
    if (!mounted) return;
    setState(() {
      _enabled = saved.config.enabled;
      _baseUrl.text = saved.config.baseUrl;
      _fingerprint.text = saved.config.fingerprint;
      _tokenStored = saved.token.isNotEmpty;
      _loading = false;
    });
  }

  /// 输入框里现拼的那一份（**不落盘**）。空着的框沿用已存的值，
  /// 这样只想点「测试连接」时不必把 Token 再打一遍。
  Future<({ServerBackupConfig config, String token})> _draft() async {
    final saved = await app.readServerBackupConfig();
    return (
      config: ServerBackupConfig(
        enabled: _enabled,
        baseUrl: _baseUrl.text.trim().isEmpty
            ? saved.config.baseUrl
            : _baseUrl.text.trim(),
        fingerprint: _fingerprint.text.trim().isEmpty
            ? saved.config.fingerprint
            : _fingerprint.text.trim(),
      ),
      token: _token.text.trim().isEmpty ? saved.token : _token.text.trim(),
    );
  }

  void _setResult(String? text) {
    if (!mounted) return;
    setState(() => _result = text);
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_enabled && app.prefs.githubBackupEnabled) {
      final ok = await confirmAction(
        context,
        title: '两条同步只能开一条',
        message: '开启服务器同步会关闭「GitHub 备份同步」；'
            '它的仓库、Token 与记账都保留，想换回来再打开即可。',
        confirmLabel: '继续',
        cancelLabel: '取消',
      );
      if (!mounted) return;
      if (!ok) {
        final saved = await app.readServerBackupConfig();
        if (!mounted) return;
        setState(() => _enabled = saved.config.enabled);
        return;
      }
    }
    setState(() => _busy = true);
    final draft = await _draft();
    final error = await app.saveServerBackupConfig(draft.config, draft.token);
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
    final result = await app.testServerConnection(draft.config, draft.token);
    if (!mounted) return;
    setState(() => _busy = false);
    _setResult(result.message);
  }

  /// 推送：判定说该推就推（与 GitHub 那页同一条用户口径），不再弹二次确认。
  Future<void> _push() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    final draft = await _draft();
    final check = await app.checkServerBackup(draft.config, draft.token);
    if (!mounted) return;
    if (check.error != null) {
      setState(() => _busy = false);
      _setResult(check.error);
      return;
    }

    final plan = check.plan!;
    switch (plan.action) {
      case SyncAction.noChange:
        setState(() => _busy = false);
        _setResult(plan.message);
        return;
      case SyncAction.localEmpty:
        setState(() => _busy = false);
        _setResult(
          '${plan.message}\n\n'
          '为避免覆盖服务器上的备份，此处不再继续。请先在本机恢复数据。',
        );
        return;
      case SyncAction.push:
      case SyncAction.pull:
      case SyncAction.bothChanged:
        break;
    }

    final result = await app.pushServerBackup(
      draft.config,
      draft.token,
      overrideRemoteChanges: true,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _setResult(result.message);
  }

  /// 拉取：先比内容。一样就不拉回（可强制）；有差别才摆差异面板。
  Future<void> _pull() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    final draft = await _draft();

    final preview = await app.previewServerPull(draft.config, draft.token);
    if (!mounted) return;
    if (preview.remote == null) {
      setState(() => _busy = false);
      _setResult(preview.error);
      return;
    }

    final remote = preview.remote!;
    final store = remote.payload!.store;
    final local = app.ws.buildStoreFile();
    final diff = diffStores(base: local, target: store);
    final remoteCommit = shortSha(remote.commitSha);
    final localCommit = shortSha(app.readServerSyncRecord()?.commitSha ?? '');
    final remoteLine = recordCountLine(
      sideLabel: '服务器',
      store: store,
      shortCommit: remoteCommit,
    );
    final localLine = recordCountLine(
      sideLabel: '本地',
      store: local,
      shortCommit: localCommit,
    );

    if (!diff.hasChanges) {
      final force = await confirmAction(
        context,
        title: '服务器和这台手机是同一份',
        message: '对比下来两边的内容一条不差，已经把拉回的动作省掉了。\n\n'
            '$remoteLine\n$localLine\n'
            '服务器上的最后修改时间：${formatStamp(remote.savedAt)}',
        confirmLabel: '仍然强制拉回',
        cancelLabel: '取消',
      );
      if (!force) {
        setState(() => _busy = false);
        _setResult('两边内容相同，没有拉回。\n$remoteLine\n$localLine');
        return;
      }
    } else {
      final choice = await showStoreDiffSheet(
        context,
        diff: diff,
        title: '用服务器备份覆盖这台手机',
        baseLabel: '这台手机 · 会被覆盖',
        targetLabel: '服务器 · 会拉下来 · ${formatStamp(remote.savedAt)}',
        confirmLabel: '拉取并覆盖',
        cancelLabel: '取消',
        danger: true,
        cloudLine: remoteLine,
        localLine: localLine,
        footnote: '服务器那份的最后修改时间：${formatStamp(remote.savedAt)}',
        note: '覆盖之前，当前数据会先整体轮转进备份；滚动备份只留 10 份，如需退回请尽快。',
      );
      if (choice != DiffSheetResult.confirm) {
        setState(() => _busy = false);
        return;
      }
    }

    final result = await app.pullServerBackup(draft.config, draft.token);
    if (!mounted) return;
    setState(() => _busy = false);
    _setResult(result.message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器同步'),
        actions: <Widget>[
          if (!_loading)
            TextButton(
              onPressed: _busy ? null : _save,
              child: const Text('保存'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: <Widget>[
                SwitchListTile(
                  value: _enabled,
                  title: const Text('启用服务器同步'),
                  subtitle: const Text('关掉不清地址、指纹与 Token，也不删服务器上那份'),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _enabled = value),
                ),
                const _SectionLabel('服务器'),
                _Field(
                  label: '地址',
                  hint: 'https://主机:端口',
                  controller: _baseUrl,
                  helper: '只接受 https://；地址换了要重新核对证书指纹',
                ),
                _Field(
                  label: '证书指纹（SHA-256）',
                  hint: '64 位十六进制，允许冒号分组',
                  controller: _fingerprint,
                  helper: '服务器上用 openssl x509 -fingerprint -sha256 读出',
                ),
                _Field(
                  label: 'Token',
                  hint: _tokenStored ? '已保存；要换就重新填一次' : '服务器上生成的访问令牌',
                  controller: _token,
                  obscure: true,
                  helper: '只存系统安全存储，不进偏好文件、不进导出',
                ),
                const _SectionLabel('动作'),
                _ActionTile(
                  icon: Icons.wifi_tethering,
                  title: '测试连接',
                  subtitle: '只发一句 /healthz 与一次只读请求，不写任何东西',
                  onTap: _busy ? null : _test,
                ),
                _ActionTile(
                  icon: Icons.cloud_upload_outlined,
                  title: '推送到服务器',
                  subtitle: '用这台手机的数据覆盖服务器上那份，不再问第二次',
                  onTap: (_busy || !_enabled) ? null : _push,
                ),
                _ActionTile(
                  icon: Icons.cloud_download_outlined,
                  title: '从服务器拉取',
                  subtitle: '先给你看服务器与这台手机的差别，确认后才覆盖',
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
                if (_result != null)
                  _ResultBox(text: _result!, error: _isErrorText(_result!)),
              ],
            ),
    );
  }

  String _lastSyncText() {
    final record = app.readServerSyncRecord();
    if (record == null) return '还没有与服务器同步过';
    final where = _baseUrl.text.trim().isEmpty
        ? app.prefs.serverSyncBaseUrl
        : _baseUrl.text.trim();
    return '上次同步：${formatStamp(record.syncedAt)} · ${record.recordCount} 条'
        '${where.isEmpty ? '' : ' · $where'}';
  }

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

/// 一个输入框：自带焦点节点，并接上键盘护栏（页面级输入收键盘只放焦点）。
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
