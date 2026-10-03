# 建 Release + 传 APK（经典令牌 / 细粒度令牌都能跑；幂等：已存在就跳过）
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

# 从发行说明里按二级标题切一段（标题行本身不放进正文）
function Get-Section([string]$file, [string]$headingPrefix) {
  $lines = (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -split "`n"
  $start = -1
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i].StartsWith('## ') -and $lines[$i].Contains($headingPrefix)) { $start = $i; break }
  }
  if ($start -lt 0) { throw "找不到小节：$headingPrefix" }
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

$notes = 'tool/release-notes.md'
$releases = @(
  # v2.7.0 起一个 Release 带**两个附件**（手机 APK + 电脑 zip）—— 用户 2026-10-03 的要求
  # 是"同步更新 win 版本"，下面那段附件循环因此改成能收数组（见 `$rel.Asset -is [array]`）。
  @{ Tag = 'v2.7.0'; Name = 'v2.7.0 — 到点提醒（本地通知），Windows 版首次随版本发出'; Section = 'v2.7.0'; Asset = @('dist/guideline-2.7.0.apk', 'dist/guideline-windows-2.7.0.zip') },
  @{ Tag = 'v1.9.3'; Name = 'v1.9.3 — 两条用例不再依赖 Windows 专用命令，CI 首次变绿'; Section = 'v1.9.3'; Asset = 'dist/guideline-1.9.3.apk' },
  @{ Tag = 'v1.5.1'; Name = 'v1.5.1 — 文案去括号，版本号不再漂移'; Section = 'v1.5.1'; Asset = 'dist/guideline-1.5.1.apk' },
  @{ Tag = 'v1.5.0'; Name = 'v1.5.0 — 事件详情页改名 + 速记按钮两处修复'; Section = 'v1.5.0'; Asset = 'dist/guideline-1.5.0.apk' },
  @{ Tag = 'v1.4.0'; Name = 'v1.4.0 — 项目与事件的口径重定，42 项改动落地'; Section = 'v1.4.0'; Asset = 'dist/guideline-1.4.0.apk' },
  @{ Tag = 'v1.3.0'; Name = 'v1.3.0 — 项目「实现」变成待办清单，并接上 AI'; Section = 'v1.3.0'; Asset = 'dist/guideline-1.3.0.apk' }
)

foreach ($rel in $releases) {
  $release = $null
  try {
    $release = Send 'Get' "$api/releases/tags/$($rel.Tag)" $null ''
    # 已存在：把正文同步成上面那份（幂等 —— 重跑脚本 = 让线上正文与本文件一致）。
    # **注意用 id 而不是 `/releases/tags/<tag>` 来 PATCH**：那个路由在 PowerShell 5.1 的
    # `Invoke-RestMethod -Method Patch` 下会 404（GET 同路由却正常），用 id 才通。
    $json = @{ body = (Get-Section $notes $rel.Section) } | ConvertTo-Json -Depth 3 -Compress
    $release = Send 'Patch' "$api/releases/$($release.id)" $json 'application/json; charset=utf-8'
    Write-Output "Release $($rel.Tag) 已存在（id=$($release.id)），正文已同步：$($release.html_url)"
  } catch {
    if ("$_" -match 'HTTP 404') {
      $payload = @{ tag_name = $rel.Tag; name = $rel.Name; body = (Get-Section $notes $rel.Section); draft = $false; prerelease = $false } | ConvertTo-Json -Depth 3 -Compress
      $release = Send 'Post' "$api/releases" $payload 'application/json; charset=utf-8'
      Write-Output "Release $($rel.Tag) 创建成功（id=$($release.id)）：$($release.html_url)"
    } else {
      throw
    }
  }

  # 附件可以是**一个路径，也可以是一串**（v2.7.0 起一个 Release 同时带 APK 与 Windows zip）。
  $assets = if ($rel.Asset -is [array]) { $rel.Asset } else { @($rel.Asset) }
  foreach ($assetPath in $assets) {
    $assetName = [System.IO.Path]::GetFileName($assetPath)
    $already = $release.assets | Where-Object { $_.name -eq $assetName }
    if ($already) {
      Write-Output "  附件 $assetName 已存在（$($already.size) 字节），跳过"
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
