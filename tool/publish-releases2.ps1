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

  $assetName = [System.IO.Path]::GetFileName($rel.Asset)
  $already = $release.assets | Where-Object { $_.name -eq $assetName }
  if ($already) {
    Write-Output "  附件 $assetName 已存在（$($already.size) 字节），跳过"
    continue
  }
  $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $rel.Asset))
  $uploadUrl = "https://uploads.github.com/repos/maker114/Guide-Line/releases/$($release.id)/assets?name=$assetName"
  $asset = Invoke-RestMethod -Uri $uploadUrl -Headers $headers -Method Post -ContentType 'application/vnd.android.package-archive' -Body $bytes
  Write-Output "  附件上传成功：$($asset.name)（$($asset.size) 字节）→ $($asset.browser_download_url)"
}
Write-Output '全部完成'
