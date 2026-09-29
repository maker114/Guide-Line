/// GitHub 备份同步的**非敏感**配置（纯数据 + 纯校验）。
///
/// 放在 `lib/core` 是刻意的（与 [AiConfig] 同一套路数）：这一层不联网、不碰插件，
/// 于是"什么算配置好了"能被纯 Dart 测出来，不必起一台假服务器。
///
/// **`token` 不在这个类里**，与 AI 的 `apiKey` 同理：它只该存在系统安全存储里，
/// 连 `ui_prefs.json` 的键都不出现（那个文件会进滚动备份与整库导出）。
///
/// 这个类存在本身就是 ADR-088 记的那条边界：远程落点是**用户自建的私有仓库**、
/// 内容**不加密** —— 安全边界是仓库的可见性，不是加密。
class GitHubBackupConfig {
  const GitHubBackupConfig({
    this.enabled = false,
    this.owner = '',
    this.repo = '',
    this.branch = defaultBranch,
    this.path = defaultPath,
  });

  /// 远程文件默认落在哪。
  ///
  /// 带目录是刻意的：用户如果误把它塞进一个公开仓库，至少不会直接铺在首页上。
  static const String defaultPath = 'backups/guideline-latest.json.gz';

  static const String defaultBranch = 'main';

  /// 总开关。**只决定显不显示**，与 `aiEnabled` 同一条口径：
  /// 关掉不会丢配置，也不会把远程那份删掉。
  final bool enabled;

  /// 仓库所有者（用户名或组织名）。
  final String owner;

  /// 仓库名。
  final String repo;

  /// 分支名。
  final String branch;

  /// 仓库里的文件路径。
  final String path;

  /// 去掉首尾空格与结尾斜杠。
  ///
  /// `owner` / `repo` 去尾斜杠很好理解；`path` 也去是因为它会被拼进
  /// `contents/{path}`，多一个斜杠就是 404——而用户从浏览器地址栏复制时
  /// 几乎总会带上。
  GitHubBackupConfig normalized() => GitHubBackupConfig(
        enabled: enabled,
        owner: _trimEdge(owner),
        repo: _trimEdge(repo),
        branch: branch.trim(),
        path: _trimEdge(path),
      );

  /// 返回**可以直接显示**的中文原因，`null` 表示配置齐全。
  ///
  /// 与 AI 配置那一边同一条口径：先把话说给用户听，同时它也是
  /// "能不能发请求"的唯一判据（界面与控制器都只看这一个方法）。
  String? validate() {
    final cleaned = normalized();

    if (cleaned.owner.isEmpty) return '还没填仓库所有者';
    if (cleaned.owner.contains('/')) {
      return '仓库所有者里不该有斜杠，只填用户名或组织名';
    }
    if (cleaned.owner.contains(' ')) return '仓库所有者里不该有空格';

    if (cleaned.repo.isEmpty) return '还没填仓库名';
    if (cleaned.repo.contains('/')) return '仓库名里不该有斜杠，只填仓库本身的名字';
    if (cleaned.repo.contains(' ')) return '仓库名里不该有空格';

    if (cleaned.branch.isEmpty) return '还没填分支名';
    if (cleaned.branch.contains(' ')) return '分支名里不该有空格';

    if (cleaned.path.isEmpty) return '还没填远程文件路径';
    if (cleaned.path.startsWith('/')) return '远程文件路径要以文件夹名开头，不要以斜杠开头';
    if (cleaned.path.endsWith('/')) return '远程文件路径要写到文件名，不能只写一个文件夹';

    // 仓库会被公开访问：私有仓库 + 明文上传时，这一条是唯一挡在
    // "人生记录躺在任何人都读得到的地址上"前面的东西。
    if (cleaned.isLikelyPublicRepo) {
      return '这里要填仓库的所有者与仓库名，别把仓库地址整个粘进来';
    }

    return null;
  }

  /// 配置是否齐全（能发请求）。
  bool get isConfigured => validate() == null;

  /// 用户把仓库名填成了 `owner/repo`（GitHub 网页地址与 clone 地址的形状）。
  bool get isLikelyPublicRepo =>
      owner.contains('github.com') || repo.contains('github.com');

  /// Contents API 的地址（不含主机名，主机名固定 `api.github.com`）。
  ///
  /// 单独拎出来是为了让报错文案与"测试连接"能把**实际请求的地址**打出来 ——
  /// 排查 404 时这是最关键的一条信息（与 AI 那一侧同一个教训）。
  String get contentsApiPath =>
      '/repos/$owner/$repo/contents/${path.split('/').map(Uri.encodeComponent).join('/')}';

  GitHubBackupConfig copyWith({
    bool? enabled,
    String? owner,
    String? repo,
    String? branch,
    String? path,
  }) =>
      GitHubBackupConfig(
        enabled: enabled ?? this.enabled,
        owner: owner ?? this.owner,
        repo: repo ?? this.repo,
        branch: branch ?? this.branch,
        path: path ?? this.path,
      );

  /// 写进 `ui_prefs.json` 的形态（**只有非敏感项**；token 绝不在这里）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'owner': owner,
        'repo': repo,
        'branch': branch,
        'path': path,
      };

  static String _trimEdge(String value) {
    var out = value.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
