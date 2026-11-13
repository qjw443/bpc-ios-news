#requires -Version 5.1
<#
.SYNOPSIS
    Windows 上给 BPCNews-unsigned.ipa 自签（需要 .p12 + .mobileprovision）。

.DESCRIPTION
    做的事（顺序很重要）：
      1. 从 .mobileprovision 里读出 application-identifier，判断是否通配符
      2. 解包 IPA，读 app 的 Info.plist 里的 CFBundleIdentifier
      3. Bundle ID 不匹配且描述文件非通配符 -> 用 python plistlib 改写 Info.plist 并重新打包
      4. 删掉 _CodeSignature、替换 embedded.mobileprovision
      5. 调用 zsign 签名（若提供），否则打印 Sideloadly 的手动步骤

.PARAMETER Zsign
    zsign.exe 的完整路径。不填则只做「预检 + 打印 Sideloadly 步骤」。

.EXAMPLE
    .\sign_ipa_windows.ps1 -Ipa .\BPCNews-unsigned.ipa -P12 .\cert.p12 `
        -Provision .\dev.mobileprovision -Password 123456 -Zsign C:\tools\zsign.exe `
        -Out .\BPCNews-signed.ipa
#>
param(
    [Parameter(Mandatory = $true)][string]$Ipa,
    [Parameter(Mandatory = $true)][string]$P12,
    [Parameter(Mandatory = $true)][string]$Provision,
    [Parameter(Mandatory = $true)][string]$Password,
    [string]$Zsign = "",
    [string]$Out = "",
    [string]$BundleId = ""
)

$ErrorActionPreference = "Stop"
function Say($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

foreach ($f in @($Ipa, $P12, $Provision)) {
    if (-not (Test-Path $f)) { throw "文件不存在: $f" }
}
$Ipa = (Resolve-Path $Ipa).Path
$P12 = (Resolve-Path $P12).Path
$Provision = (Resolve-Path $Provision).Path
if (-not $Out) { $Out = Join-Path (Split-Path $Ipa) "BPCNews-signed.ipa" }

# ---------- 1) 解析描述文件 ----------
Say "解析 embedded.mobileprovision ..."
$raw = [System.Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Provision))
$m = [regex]::Match($raw, 'application-identifier</key>\s*<string>([^<]+)</string>')
if (-not $m.Success) { throw "无法从描述文件读出 application-identifier（文件可能不是 mobileprovision）" }
$appId = $m.Groups[1].Value.Trim()
$teamId = ($appId -split '\.')[0]
$profileBundle = ($appId -split '\.', 2)[1]
$isWildcard = $profileBundle.EndsWith("*")
Ok  "App ID      : $appId"
Ok  "Team ID     : $teamId"
Ok  "通配符      : $isWildcard"

$exp = [regex]::Match($raw, '<key>ExpirationDate</key>\s*<date>([^<]+)</date>')
if ($exp.Success) {
    $dt = [datetime]::Parse($exp.Groups[1].Value)
    if ($dt -lt (Get-Date)) { Bad "描述文件已过期：$dt" } else { Ok "有效期至    : $dt" }
}
$devCount = ([regex]::Matches($raw, '<key>ProvisionedDevices</key>')).Count
if ($devCount -gt 0) { Bad "这是「开发描述文件」：只能装到已登记的 UDID（沙盒推送 sandbox）" }

# ---------- 2) 解包 ----------
$tmp = Join-Path $env:TEMP ("bpc-sign-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
Say "解包到 $tmp"
$zipCopy = Join-Path $tmp "in.zip"
Copy-Item $Ipa $zipCopy
Expand-Archive -Path $zipCopy -DestinationPath $tmp -Force

$appDir = Get-ChildItem -Path (Join-Path $tmp "Payload") -Directory -Filter *.app |
          Select-Object -First 1
if (-not $appDir) { throw "IPA 结构不正确：缺少 Payload/*.app" }
$app = $appDir.FullName
Ok "App bundle  : $($appDir.Name)"

# ---------- 3) Bundle ID 检查/改写 ----------
$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) { throw "需要 python（用于读写 Info.plist），请先安装 Python 3" }

$infoPath = Join-Path $app "Info.plist"
$curBundle = (& python -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb'))['CFBundleIdentifier'])" $infoPath).Trim()
Ok "当前 BundleID: $curBundle"

$target = if ($BundleId) { $BundleId } elseif (-not $isWildcard) { $profileBundle } else { $curBundle }
$needPatch = ($curBundle -ne $target)

if ($needPatch) {
    if ($isWildcard) { throw "理论不会到这里" }
    Say "Bundle ID 不一致，改写为描述文件要求的: $target"
    & python -c @"
import plistlib,sys
p=sys.argv[1]; bid=sys.argv[2]
d=plistlib.load(open(p,'rb'))
d['CFBundleIdentifier']=bid
plistlib.dump(d,open(p,'wb'),fmt=plistlib.FMT_BINARY)
print('patched ->',bid)
"@ $infoPath $target
} else {
    Ok "Bundle ID 与描述文件匹配（或通配符），无需改写"
}

# BGTask identifier 跟着 Bundle ID 走，避免后台刷新失效
$bg = & python -c "import plistlib,sys;d=plistlib.load(open(sys.argv[1],'rb'));print((d.get('BGTaskSchedulerPermittedIdentifiers') or [''])[0])" $infoPath
if ($bg -and $bg -ne "$target.refresh") {
    Say "同步 BGTaskSchedulerPermittedIdentifiers -> $target.refresh"
    & python -c @"
import plistlib,sys
p=sys.argv[1]; bid=sys.argv[2]
d=plistlib.load(open(p,'rb'))
d['BGTaskSchedulerPermittedIdentifiers']=[bid+'.refresh']
plistlib.dump(d,open(p,'wb'),fmt=plistlib.FMT_BINARY)
"@ $infoPath $target
}

# ---------- 4) 清理签名残留 + 换描述文件 ----------
Say "清理 _CodeSignature / 替换 embedded.mobileprovision"
Get-ChildItem -Path $app -Recurse -Directory -Filter "_CodeSignature" |
    Remove-Item -Recurse -Force
Copy-Item $Provision (Join-Path $app "embedded.mobileprovision") -Force
Get-ChildItem -Path $app -Filter "*.dSYM" -Recurse -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# 重新打包成待签名 IPA
$patchedIpa = Join-Path $tmp "patched.ipa"
$payloadDir = Join-Path $tmp "Payload"
$outZip = Join-Path $tmp "patched.zip"
if (Test-Path $outZip) { Remove-Item $outZip -Force }
Compress-Archive -Path $payloadDir -DestinationPath $outZip -CompressionLevel Optimal
Move-Item $outZip $patchedIpa -Force
Ok "已生成待签名 IPA: $patchedIpa"

# ---------- 5) 签名 ----------
if ($Zsign -and (Test-Path $Zsign)) {
    Say "调用 zsign 签名 ..."
    $zsArgs = @("-k", $P12, "-p", $Password, "-m", $Provision, "-o", $Out, $patchedIpa)
    & $Zsign @zsArgs
    if ($LASTEXITCODE -ne 0) { throw "zsign 返回码 $LASTEXITCODE，签名失败" }
    if (-not (Test-Path $Out)) { throw "签名产物不存在：$Out" }
    Ok "签名完成: $Out  ($([math]::Round((Get-Item $Out).Length/1MB,2)) MB)"
} else {
    Bad "未提供 -Zsign，只做了预检。手动签名（任选一种）："
    Write-Host @"

  A. Sideloadly（Windows，最省事，会自动对齐 Bundle ID）
     1) 打开 Sideloadly，iPhone 用数据线连电脑
     2) IPA 选： $Ipa
     3) Apple ID 填你的开发者账号，Advanced 里勾选你的 p12/描述文件（或让它自动申请）
     4) Start -> 输入密码 -> 完成

  B. zsign（命令行）
     zsign.exe -k "$P12" -p $Password -m "$Provision" -o "$Out" "$Ipa"

  C. 轻松签 / Esign（iOS 端）
     把 .p12 + .mobileprovision 导入 App，选 IPA 直接签

  注意：签名后 Bundle ID = $target
        APNs 环境     = $(if ($devCount -gt 0) { "sandbox（开发描述文件）" } else { "production（发布描述文件）" })
"@ -ForegroundColor Gray
}

# 清理
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
