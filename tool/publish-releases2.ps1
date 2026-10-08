# 建 / 更新 Release（经典令牌 / 细粒度令牌都能跑；幂等：已存在就 PATCH 标题与正文）
#
# 发布规则见 `AGENTS.md` §8.1：**一篇 Release 对应一个次位号**，
# 它之后的修订版并进它后面那一篇（`2.3.1`~`2.3.9` 与 `2.4.1` 都并进 `v2.4.0`）。
# 正文唯一来源是 `tool/release-notes.md`。
#
# 需要令牌：`$env:GH_TOKEN`。只调 REST API，不依赖 gh CLI。
#
# 用法：
#   $env:GH_TOKEN = '…'; pwsh -File tool/publish-releases2.ps1            # 真发
#   $env:GH_TOKEN = '…'; pwsh -File tool/publish-releases2.ps1 -WhatIfOnly # 干跑，只看取到多少字

param(
  [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$token = $env:GH_TOKEN
if (-not $token) { throw '需要 GH_TOKEN' }

# 认证头：经典令牌用 `token`，细粒度用 `Bearer`
$scheme = if ($token.StartsWith('ghp_')) { 'token' } else { 'Bearer' }
$headers = @{
  Authorization          = "$scheme $token"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'dsh-agent'
}
$api = 'https://api.github.com/repos/maker114/Guide-Line'
$notes = 'tool/release-notes.md'

# 从发行说明里按**精确版本号**切一段（标题行本身不放进正文）。
#
# ⚠️ 匹配必须锚定行首、且版本号后面跟分隔符：否则 `v2.7.0` 会命中 `## v2.7.11 …`
# （两个版本号互为前缀），取出来的是别人的正文。
function Get-Section([string]$file, [string]$version) {
  $lines = (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -split "`r?`n"
  $pattern = '^##\s+v' + [regex]::Escape($version) + '(?:\s|—|$)'
  $start = -1
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match $pattern) { $start = $i; break }
  }
  if ($start -lt 0) { throw "找不到小节：v$version" }
  $end = $lines.Length
  for ($i = $start + 1; $i -lt $lines.Length; $i++) {
    if ($lines[$i].StartsWith('## ')) { $end = $i; break }
  }
  ($lines[($start + 1)..($end - 1)] -join "`n").Trim()
}

# 发请求：失败时把状态码与正文打出来，别吞掉
function Send([string]$method, [string]$url, $body, [string]$contentType) {
  try {
    if ($null -eq $body) {
      return Invoke-RestMethod -Uri $url -Headers $headers -Method $method
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    return Invoke-RestMethod -Uri $url -Headers $headers -Method $method -ContentType $contentType -Body $bytes
  } catch {
    $resp = $_.Exception.Response
    if ($resp) {
      $code = [int]$resp.StatusCode
      $text = ''
      try { $text = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { }
      throw "HTTP $code :: $text"
    }
    throw
  }
}

# 要发的版本：**只有次位号**。修订版不在这个清单里。
# `Asset` 留空表示这一版没有可发的安装包（只有最近两版本机有包）。
$releases = @(
  @{ Tag = 'v2.7.0';  Name = 'v2.7.0 — 到点提醒与 Windows 版发布';        Asset = @('dist/guideline-2.7.0.apk', 'dist/guideline-windows-2.7.0.zip') },
  @{ Tag = 'v2.6.0';  Name = 'v2.6.0 — 在指定位置插入主线任务';           Asset = @() },
  @{ Tag = 'v2.5.0';  Name = 'v2.5.0 — 截止时间精确到分钟';               Asset = @() },
  @{ Tag = 'v2.4.0';  Name = 'v2.4.0 — 同步页自动读取云端';               Asset = @() },
  @{ Tag = 'v2.3.0';  Name = 'v2.3.0 — 同步状态改为两行对照';             Asset = @() },
  @{ Tag = 'v2.2.0';  Name = 'v2.2.0 — 数据安全修复';                     Asset = @() },
  @{ Tag = 'v2.1.0';  Name = 'v2.1.0 — 内部修正';                         Asset = @() },
  @{ Tag = 'v2.0.0';  Name = 'v2.0.0 — 内部修正';                         Asset = @() },
  @{ Tag = 'v1.12.0'; Name = 'v1.12.0 — Windows 桌面版发布';              Asset = @() },
  @{ Tag = 'v1.11.0'; Name = 'v1.11.0 — 同步状态指示器与启动比对';        Asset = @() },
  @{ Tag = 'v1.10.0'; Name = 'v1.10.0 — GitHub 备份同步';                 Asset = @() },
  @{ Tag = 'v1.9.0';  Name = 'v1.9.0 — 提交码与键盘收起规则';             Asset = @() },
  @{ Tag = 'v1.8.0';  Name = 'v1.8.0 — 分类递归展开与多点修复';           Asset = @() },
  @{ Tag = 'v1.7.0';  Name = 'v1.7.0 — AI 拆分条目与重置入口';            Asset = @() },
  @{ Tag = 'v1.6.0';  Name = 'v1.6.0 — 主题手选、分类导出与文案精简';     Asset = @() },
  @{ Tag = 'v1.5.0';  Name = 'v1.5.0 — 事件重命名与速记按钮修复';         Asset = @() },
  @{ Tag = 'v1.4.0';  Name = 'v1.4.0 — 项目与事件的口径重定';             Asset = @() },
  @{ Tag = 'v1.3.0';  Name = 'v1.3.0 — 实现清单与 AI 整理';               Asset = @() },
  @{ Tag = 'v1.2.0';  Name = 'v1.2.0 — 灵感多选、项目标识色与紧迫度色阶'; Asset = @() },
  @{ Tag = 'v1.1.0';  Name = 'v1.1.0 — 页内输入与任务后续关系';           Asset = @() },
  @{ Tag = 'v1.0.0';  Name = 'v1.0.0 — 首个手机单机版';                   Asset = @() }
)

foreach ($rel in $releases) {
  $version = $rel.Tag.TrimStart('v')
  $section = Get-Section $notes $version
  # 下限只用来拦"取错节"（例如取到标题、或取到空段），不拦"本来就短"的版本：
  # `v2.1.0` 那类内部修正版正文只有一句话。
  if ($section.Length -lt 10) { throw "$($rel.Tag) 取到的正文过短（$($section.Length) 字），八成取错了节" }

  if ($WhatIfOnly) {
    Write-Output "$($rel.Tag)  正文 $($section.Length) 字  附件 $(@($rel.Asset | Where-Object { $_ }).Count) 个（干跑，未发送）"
    continue
  }

  $release = $null
  try {
    $release = Send 'Get' "$api/releases/tags/$($rel.Tag)" $null ''
    # 已存在：把标题与正文同步成上面那份（幂等 —— 重跑脚本 = 让线上与本文件一致）。
    # **注意用 id 而不是 `/releases/tags/<tag>` 来 PATCH**：那个路由在 PowerShell 5.1 的
    # `Invoke-RestMethod -Method Patch` 下会 404（GET 同路由却正常），用 id 才通。
    $json = @{ name = $rel.Name; body = $section } | ConvertTo-Json -Depth 3 -Compress
    $release = Send 'Patch' "$api/releases/$($release.id)" $json 'application/json; charset=utf-8'
    Write-Output "Release $($rel.Tag) 已存在（id=$($release.id)），标题与正文已同步"
  } catch {
    if ("$_" -match 'HTTP 404') {
      $payload = @{ tag_name = $rel.Tag; name = $rel.Name; body = $section; draft = $false; prerelease = $false } | ConvertTo-Json -Depth 3 -Compress
      $release = Send 'Post' "$api/releases" $payload 'application/json; charset=utf-8'
      Write-Output "Release $($rel.Tag) 创建成功（id=$($release.id)）：$($release.html_url)"
    } else {
      throw
    }
  }

  foreach ($assetPath in @($rel.Asset | Where-Object { $_ })) {
    $assetName = [System.IO.Path]::GetFileName($assetPath)
    $already = $release.assets | Where-Object { $_.name -eq $assetName }
    if ($already) {
      Write-Output "  附件 $assetName 已存在（$($already.size) 字节），跳过"
      continue
    }
    if (-not (Test-Path -LiteralPath $assetPath)) {
      Write-Output "  附件 $assetPath 不在本机，跳过"
      continue
    }
    # 内容类型按扩展名给：zip 传成 apk 的 MIME，下载器会照着当安装包处理。
    $contentType = if ($assetName.EndsWith('.apk')) {
      'application/vnd.android.package-archive'
    } else {
      'application/zip'
    }
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $assetPath))
    $uploadUrl = "https://uploads.github.com/repos/maker114/Guide-Line/releases/$($release.id)/assets?name=$assetName"
    $asset = Invoke-RestMethod -Uri $uploadUrl -Headers $headers -Method Post -ContentType $contentType -Body $bytes
    Write-Output "  附件上传成功：$($asset.name)（$($asset.size) 字节）→ $($asset.browser_download_url)"
  }
}
Write-Output '全部完成'
