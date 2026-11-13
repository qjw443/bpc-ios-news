#requires -Version 5.1
<#
.SYNOPSIS
    一条命令产出 BPCNews-unsigned.ipa（推 GitHub -> macOS runner 编译 -> 自动下载）。

.DESCRIPTION
    Windows 上没有 Xcode/iPhoneOS SDK，arm64 的编译环节放在 GitHub 的 macOS runner 上跑。
    本脚本把「建仓 -> 推代码 -> 触发 workflow -> 等构建 -> 下载 artifact -> 校验 IPA」全自动串起来。
    你只要做过一次 gh auth login。

.PARAMETER RepoName
    GitHub 仓库名（默认 bpc-ios-news）。

.PARAMETER Public
    建公开仓库（macOS runner 免费额度不限；私有仓库按 10 倍系数计费）。

.PARAMETER Rebuild
    不推代码，只重新触发一次构建（改了 Swift 但已经提交过时用）。

.PARAMETER OutDir
    IPA 落地目录，默认 <工程根>\dist。

.EXAMPLE
    .\scripts\make_ipa.ps1
    .\scripts\make_ipa.ps1 -RepoName bpc-news -Public -OutDir E:\ipa
#>
param(
    [string]$RepoName = "bpc-ios-news",
    [switch]$Public,
    [switch]$Rebuild,
    [string]$OutDir = "",
    [string]$Token = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root
if (-not $OutDir) { $OutDir = Join-Path $Root "dist" }

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Info($m) { Write-Host "[*] $m" -ForegroundColor Gray }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 0. 前置

Step "0/6 环境检查"
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Die "未安装 GitHub CLI（gh）" }

# 支持把 PAT 直接喂进来，省掉浏览器授权这一步
if ($Token) {
    Info "使用提供的 Token 登录 gh ..."
    $Token.Trim() | gh auth login --with-token
    if ($LASTEXITCODE -ne 0) { Die "Token 无效（需要 repo + workflow 权限）" }
    Ok "gh 已通过 Token 登录"
}

gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "需要一次 GitHub 授权（三选一）：" -ForegroundColor Yellow
    Write-Host "  1) gh auth login                        # 浏览器点一下" -ForegroundColor White
    Write-Host "  2) .\scripts\make_ipa.ps1 -Token ghp_xx # 直接把 PAT 传进来" -ForegroundColor White
    Write-Host "  3) `$env:GH_TOKEN='ghp_xx'; .\scripts\make_ipa.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "  PAT 需要勾：repo（或 Contents 读写）+ workflow" -ForegroundColor DarkGray
    Write-Host ""
    Die "gh 未登录"
}
$who = (gh api user --jq .login)
Ok "gh 已登录：$who"

if (-not (Test-Path (Join-Path $Root "ios\project.yml"))) { Die "工程不完整：缺 ios\project.yml" }
Info "工程根目录：$Root"

# ---------------------------------------------------------------- 1. 触发方式

Step "1/6 准备仓库"
$hasGit = Test-Path (Join-Path $Root ".git")
if (-not $hasGit) {
    git init -b main | Out-Null
    Ok "已初始化 git 仓库"
}

@(".env", "secrets/", "data/", "server/data/", "*.p8", "*.p12", "*.mobileprovision",
  "*.ipa", "dist/", "ios/build/", "ios/Payload/",
  "__pycache__/", "*.db", "*.pyc") | Set-Content -Path (Join-Path $Root ".gitignore") -Encoding utf8

$since = Get-Date

if (-not $Rebuild) {
    git add -A
    git -c user.email="bpc@local" -c user.name="bpc" commit -m "build: refresh project" 2>$null | Out-Null
    Info "本地已提交"

    $remote = (git remote get-url origin 2>$null)
    if (-not $remote) {
        $vis = if ($Public) { "--public" } else { "--private" }
        Info "创建远端仓库 $RepoName ($vis) ..."
        gh repo create $RepoName $vis --source . --remote origin --push
        if ($LASTEXITCODE -ne 0) { Die "创建仓库失败（可能重名，换 -RepoName）" }
        Ok "已创建并推送"
    } else {
        Info "推送到已有远端：$remote"
        git push -u origin HEAD
        if ($LASTEXITCODE -ne 0) { Die "推送失败" }
        Ok "已推送"
    }
} else {
    Info "跳过推送，直接重新触发 workflow"
}

# ---------------------------------------------------------------- 2. 找构建

Step "2/6 定位刚触发的构建"
$run = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 5
    $raw = gh run list --workflow=ios-unsigned.yml --limit 5 `
             --json databaseId,status,conclusion,createdAt,headBranch 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { continue }
    $cand = ($raw | ConvertFrom-Json) |
            Where-Object { [datetime]$_.createdAt.ToLocalTime() -ge $since } |
            Sort-Object { [datetime]$_.createdAt } -Descending |
            Select-Object -First 1
    if ($cand) { $run = $cand; break }
}

if (-not $run) {
    Info "没等到自动触发的构建，手动 dispatch 一次"
    gh workflow run ios-unsigned.yml --ref main
    if ($LASTEXITCODE -ne 0) { Die "workflow 触发失败：确认 ios-unsigned.yml 已在默认分支上" }
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 5
        $raw = gh run list --workflow=ios-unsigned.yml --limit 1 --json databaseId,status,conclusion,createdAt
        if ($raw) {
            $c = @($raw | ConvertFrom-Json)[0]
            if ($c) { $run = $c; break }
        }
    }
}
if (-not $run) { Die "启动不了构建，去 Actions 页面手动看一眼" }
Ok "run id = $($run.databaseId)  分支 = $($run.headBranch)"
Info "https://github.com/$who/$RepoName/actions/runs/$($run.databaseId)"

# ---------------------------------------------------------------- 3. 等待

Step "3/6 等待 macOS 编译（首次约 5–8 分钟）"
gh run watch $run.databaseId --interval 10 --exit-status
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n--- 失败日志（末尾 60 行）---" -ForegroundColor Yellow
    gh run view $run.databaseId --log-failed 2>$null | Select-Object -Last 60
    Die "构建失败，把上面的日志发我"
}
Ok "构建成功"

# ---------------------------------------------------------------- 4. 下载

Step "4/6 下载 artifact"
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir | Out-Null
gh run download $run.databaseId -n BPCNews-unsigned-ipa -D $OutDir
if ($LASTEXITCODE -ne 0) { Die "artifact 下载失败" }

$ipa = Get-ChildItem $OutDir -Filter *.ipa -Recurse | Select-Object -First 1
if (-not $ipa) { Die "下载包里没有 .ipa：$OutDir" }
Ok "IPA: $($ipa.FullName)  ($([math]::Round($ipa.Length/1MB,2)) MB)"

# ---------------------------------------------------------------- 5. 校验

Step "5/6 校验 IPA 结构"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($ipa.FullName)
try {
    $names = $zip.Entries | ForEach-Object { $_.FullName }
    $app = $names | Where-Object { $_ -match '^Payload/[^/]+\.app/$' } | Select-Object -First 1
    $info = $names | Where-Object { $_ -match '^Payload/[^/]+\.app/Info\.plist$' } | Select-Object -First 1
    $binary = $names | Where-Object { $_ -match '^Payload/[^/]+\.app/BPCNews$' } | Select-Object -First 1
    if (-not $app)  { Die "缺 Payload/*.app" }
    if (-not $info) { Die "缺 Info.plist" }
    if (-not $binary) { Die "缺可执行文件" }
    Ok "Payload 结构正确"
    Ok "可执行文件：$binary"
    Info "条目总数：$($names.Count)"

    $sig = $names | Where-Object { $_ -match '_CodeSignature' } | Select-Object -First 1
    if ($sig) { Write-Host "[!] 内含 _CodeSignature（说明不是纯 unsigned，签名时先删掉）" -ForegroundColor Yellow }
    else { Ok "确认为未签名（无 _CodeSignature），可以自签" }
}
finally { $zip.Dispose() }

# 读出 Bundle ID 供签名时对照
$tmp = Join-Path $env:TEMP ("bpcipa_" + [guid]::NewGuid().ToString("N").Substring(0,8))
Expand-Archive -Path $ipa.FullName -DestinationPath $tmp -Force
try {
    $plist = Get-ChildItem $tmp -Recurse -Filter Info.plist |
             Where-Object { $_.FullName -match '\.app\\Info\.plist$' } | Select-Object -First 1
    $bid = & python -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb'))['CFBundleIdentifier'])" $plist.FullName
    $ver = & python -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb')).get('CFBundleShortVersionString','?'))" $plist.FullName
    Ok "Bundle ID  : $bid"
    Ok "版本        : $ver"
    Info "签名时描述文件的 App ID 必须能对应上这个 Bundle ID"
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- 6. 收尾

Step "6/6 完成"
Write-Host @"

  IPA 已就绪：
      $($ipa.FullName)

  下一步（自签）：
      .\scripts\sign_ipa_windows.ps1 ``
        -Ipa "$($ipa.FullName)" ``
        -P12 .\cert.p12 ``
        -Provision .\dev.mobileprovision ``
        -Password 你的p12密码 ``
        -Zsign C:\tools\zsign.exe

  或者直接把上面这个 .ipa 丢进 Sideloadly / 轻松签。

"@ -ForegroundColor Green
