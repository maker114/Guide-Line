import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/ai_config.dart';
import '../common/dialogs.dart';

/// AI 设置（设计文档 §2.2）。
///
/// 这是全应用**唯一会联网**的功能，所以这一页要把边界讲清楚：
///   · 请求只发到你自己填的地址，没有硬编码的第三方服务器；
///   · **只发项目名称、目的、清单条目** —— 灵感原文、事件任务、其它项目都不发；
///   · `apiKey` 存在系统安全存储里，**不进偏好文件、不进备份、不进导出**；
///   · 提示词与模型返回的原文都不落盘，只有你确认过的结果写进「实现正文」。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, required this.app});

  final AppController app;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _model = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  bool _loading = true;
  bool _keyStored = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await widget.app.readAiConfig();
    if (!mounted) return;
    setState(() {
      _baseUrl.text = config.baseUrl;
      _model.text = config.model;
      // 安全存储里已经有 Key 时**不把它显示出来**：只给一个"已保存"的标记，
      // 想换就重新输入（读出来回显没有好处，只有被旁人看到的风险）
      _keyStored = config.apiKey.isNotEmpty;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 整理'),
        actions: <Widget>[
          TextButton(
            onPressed: _loading ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    '用于把项目清单整理成一段通顺的实现说明。没配置时这个功能是关着的。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                _Field(
                  label: 'API 地址',
                  hint: AiConfig.defaultBaseUrl,
                  controller: _baseUrl,
                  helper: '填根地址即可，会自动补 /chat/completions；'
                      '若已带路径也认得（含 /v1 这类版本前缀）',
                ),
                _Field(
                  label: '模型',
                  hint: AiConfig.defaultModel,
                  controller: _model,
                  helper: '默认 deepseek-flash；换别的兼容端点时按那边的模型名填',
                ),
                _Field(
                  label: 'API Key',
                  hint: _keyStored ? '已保存（重新输入可替换）' : '粘贴你的 Key',
                  controller: _apiKey,
                  obscure: true,
                  helper: '存在系统安全存储（Android Keystore）里，不进备份、不进导出',
                ),
                if (_keyStored)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _clearKey,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('清除已保存的 Key'),
                      ),
                    ),
                  ),
                const Divider(height: 32),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('会发出去什么', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      _Bullet('项目名称、项目目的、清单里的条目文本与勾选状态'),
                      _Bullet('还有一段固定的提示词（要求它只整理、不新增内容）'),
                      const SizedBox(height: 12),
                      Text('不会发出去什么', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      _Bullet('灵感原文、事件与任务、其它项目、设备信息 —— 一律不发'),
                      _Bullet('提示词与模型返回的原文都不会落盘'),
                      const SizedBox(height: 12),
                      Text('请求只会发到你上面填的地址。', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _save() async {
    final config = AiConfig(
      baseUrl: _baseUrl.text,
      apiKey: _apiKey.text,
      model: _model.text,
    );
    final error = await widget.app.saveAiConfig(config);
    if (!mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    final saved = await widget.app.readAiConfig();
    if (!mounted) return;
    setState(() {
      _apiKey.clear();
      _keyStored = saved.apiKey.isNotEmpty;
    });
    showToast(context, '已保存');
  }

  Future<void> _clearKey() async {
    final error = await widget.app.saveAiConfig(
      AiConfig(baseUrl: _baseUrl.text, apiKey: '', model: _model.text),
    );
    if (!mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    setState(() => _keyStored = false);
    showToast(context, '已清除');
  }
}

class _Field extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              helperText: helper,
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
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
