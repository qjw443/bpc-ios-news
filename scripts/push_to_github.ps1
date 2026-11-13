#requires -Version 5.1
<#
.SYNOPSIS
    一键把本工程推到 GitHub，用来触发 macOS 编译出 unsigned IPA。

.EXAMPLE
    gh auth login          # 先登录（浏览器授权）
    .\scripts\push_to_github.ps1 -RepoName bpc-ios-news -Public
#>
param(
    [string]$RepoName = "bpc-ios-news",
    [switch]$Public
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "未安装 gh（GitHub CLI）" }
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "请先运行: gh auth login" }

if (-not (Test-Path ".git")) {
    git init -b main | Out-Null
    Write-Host "[+] git 仓库已初始化"
}

# 别把密钥传上去
$ignore = @(".env", "secrets/", "data/", "server/data/", "*.p8", "*.p12", "*.mobileprovision",
            "*.ipa", "ios/build/", "ios/*.xcodeproj", "ios/Payload/", "__pycache__/", "*.db")
$ignore | Set-Content -Path ".gitignore" -Encoding utf8

git add -A
git -c user.email="you@example.com" -c user.name="bpc-ios" commit -m "bpc-ios-news: server + iOS app + CI" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[=] 没有新改动可提交" }

$vis = if ($Public) { "--public" } else { "--private" }
Write-Host "[*] 创建远端仓库 $RepoName ($vis) 并推送 ..."
gh repo create $RepoName $vis --source . --remote origin --push

Write-Host @"

[+] 推送完成。下一步：
    1) 打开 https://github.com/<你的用户名>/$RepoName/actions
    2) 左侧选 "build-unsigned-ipa" -> Run workflow -> Run
    3) 约 5-8 分钟后，在该次 run 底部下载 artifact: BPCNews-unsigned-ipa
    4) 解压得到 BPCNews-unsigned.ipa -> 用 scripts\sign_ipa_windows.ps1 自签

"@ -ForegroundColor Green
